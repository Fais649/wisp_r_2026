import AppIntents
import SwiftUI
import WidgetKit

private enum WidgetBridge {
    static let appGroup = "group.com.punksys.wispr"
    static let filename = "TodayWidgetSnapshot.json"
    static let actionsFilename = "TodayWidgetActions.json"
    static let kind = "TodayNotesWidget"

    static func sharedFile(_ name: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: name)
    }

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }
}

/// Where the widget leads: the whole face opens today, the plus opens a new note.
private enum WidgetLink {
    static let today = URL(string: "wispr://today")
    static let newNote = URL(string: "wispr://new")
}

// MARK: - Theme

/// The look the app is wearing, read from the settings it shares with the
/// widget. Kept as its own small copy rather than shared code, because the
/// widget draws a different set of things than the app does.
private enum WidgetTheme: String {
    case standard
    case legacy

    static var current: WidgetTheme {
        let stored = WidgetBridge.sharedDefaults?.string(forKey: "theme") ?? ""
        return WidgetTheme(rawValue: stored) ?? .standard
    }

    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .standard:
            .system(size: size, weight: weight)
        case .legacy:
            // One weight, two sizes: a bitmap face has nothing else to give.
            .custom(size < 15 ? "GohuFont11NFM" : "GohuFont14NFM", size: size * 1.02)
        }
    }

    /// The clock is the one place the default theme rounds its digits.
    func clockFont(_ size: CGFloat) -> Font {
        switch self {
        case .standard: .system(size: size, weight: .semibold, design: .rounded)
        case .legacy: font(size, weight: .semibold)
        }
    }

    var separator: Color {
        Color.white.opacity(self == .legacy ? 0.18 : 0.09)
    }

    var border: Color {
        Color.white.opacity(self == .legacy ? 0.22 : 0.16)
    }

    /// Legacy draws its buttons rather than filling them.
    var buttonFill: Color {
        Color.white.opacity(self == .legacy ? 0.0 : 0.12)
    }

    /// Round in the default theme, square-ish in legacy.
    var buttonShape: AnyShape {
        switch self {
        case .standard: AnyShape(Circle())
        case .legacy: AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    /// The colour today's date is written in once it has been marked.
    var markedDay: Color {
        switch self {
        case .standard: Color(red: 0.19, green: 0.185, blue: 0.195)
        case .legacy: .black
        }
    }

    @ViewBuilder
    var background: some View {
        switch self {
        case .standard:
            LinearGradient(
                colors: [
                    Color(red: 0.27, green: 0.27, blue: 0.28),
                    Color(red: 0.19, green: 0.185, blue: 0.195)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .legacy:
            Color.black
        }
    }
}

/// How large each kind of widget text is set in the app's settings.
private struct WidgetTypeScale {
    var header: CGFloat = 1
    var list: CGFloat = 1
    /// A note opened in the widget starts out larger: that is where checklist
    /// items are crossed off with a thumb.
    var detail: CGFloat = 1.12

    static var current: WidgetTypeScale {
        let defaults = WidgetBridge.sharedDefaults
        return WidgetTypeScale(
            header: scale(defaults?.string(forKey: "widgetHeaderTextSize")),
            list: scale(defaults?.string(forKey: "widgetNoteTextSize")),
            detail: scale(defaults?.string(forKey: "widgetFocusTextSize"), unset: 1.12)
        )
    }

    /// The same steps the app offers, by the names it stores them under.
    private static func scale(_ name: String?, unset: CGFloat = 1) -> CGFloat {
        switch name {
        case "smaller": 0.85
        case "small": 0.92
        case "standard": 1
        case "large": 1.12
        case "larger": 1.25
        case "largest": 1.4
        default: unset
        }
    }
}

// MARK: - Snapshot

private struct WidgetSnapshot: Decodable {
    let notesByDay: [String: [WidgetNote]]
}

private struct WidgetNote: Decodable, Identifiable {
    let id: UUID
    var blocks: [WidgetBlock]
    let schedule: String?
    let imageCount: Int
    let voiceMemoCount: Int

    var hasMeta: Bool { schedule != nil || imageCount > 0 || voiceMemoCount > 0 }

    /// The note as one run of text, for the day's list.
    var summary: String {
        guard !blocks.isEmpty else { return "Attachment" }
        return blocks.map(\.listLine).joined(separator: "\n")
    }
}

private struct WidgetBlock: Decodable, Identifiable {
    let id: UUID
    let text: String
    let kind: String
    var isChecked: Bool
    let number: Int?
    let indent: Int

    var isChecklistItem: Bool { kind == "checklist" }

    /// What leads the line when the note is drawn as plain text.
    var listLine: String {
        let marker: String
        switch kind {
        case "checklist": marker = isChecked ? "✓  " : "○  "
        case "bullet": marker = "•  "
        case "numbered": marker = number.map { "\($0).  " } ?? "–  "
        default: marker = ""
        }

        return String(repeating: "  ", count: max(0, indent)) + marker + text
    }

    /// What leads the line when the note is focused and drawn properly. A
    /// checklist item gets a real box instead, so it has none.
    var marker: String? {
        switch kind {
        case "bullet": "•"
        case "numbered": number.map { "\($0)." } ?? "–"
        default: nil
        }
    }
}

// MARK: - Widget state

/// The note the widget is currently showing on its own, kept beside the
/// snapshot rather than in it, because it belongs to the widget and not to the
/// notes.
private enum WidgetFocus {
    private static let noteKey = "focusedNoteID"
    private static let sinceKey = "focusedSince"

    /// The widget finds its way back to the day by itself, so a note left
    /// focused doesn't hide today for good.
    static let lifetime: TimeInterval = 10 * 60

    static func set(_ noteID: UUID?) {
        guard let defaults = WidgetBridge.sharedDefaults else { return }

        guard let noteID else {
            defaults.removeObject(forKey: noteKey)
            defaults.removeObject(forKey: sinceKey)
            return
        }

        defaults.set(noteID.uuidString, forKey: noteKey)
        defaults.set(Date.now.timeIntervalSinceReferenceDate, forKey: sinceKey)
    }

    /// The focused note as of `date`, along with when the widget should let go
    /// of it.
    static func current(at date: Date) -> (id: UUID, expiry: Date)? {
        guard let defaults = WidgetBridge.sharedDefaults,
              let stored = defaults.string(forKey: noteKey),
              let id = UUID(uuidString: stored)
        else { return nil }

        let since = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: sinceKey))
        let expiry = since.addingTimeInterval(lifetime)
        guard expiry > date else { return nil }

        return (id, expiry)
    }
}

/// A checklist item crossed off from the widget. The notes live in the app's
/// own container, so the tap is left in the app group for the app to write in,
/// and the widget draws it in the meantime.
private struct WidgetAction: Codable, Identifiable {
    let id: UUID
    let noteID: UUID
    let blockID: UUID
    let isChecked: Bool
    let date: Date
}

private enum WidgetActionQueue {
    /// Long enough for the app to be opened again; anything older is stale and
    /// would only fight whatever the note says by then.
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    static func pending() -> [WidgetAction] {
        guard let fileURL = WidgetBridge.sharedFile(WidgetBridge.actionsFilename),
              let data = try? Data(contentsOf: fileURL),
              let actions = try? JSONDecoder().decode([WidgetAction].self, from: data)
        else { return [] }

        return actions
    }

    /// Records a tap, replacing any earlier one on the same item: each holds the
    /// state the item should end in, so only the last one matters.
    static func append(_ action: WidgetAction) {
        guard let fileURL = WidgetBridge.sharedFile(WidgetBridge.actionsFilename) else { return }

        let cutoff = action.date.addingTimeInterval(-lifetime)
        var queue = pending().filter {
            $0.date > cutoff && !($0.noteID == action.noteID && $0.blockID == action.blockID)
        }
        queue.append(action)

        do {
            try JSONEncoder().encode(queue).write(to: fileURL, options: .atomic)
        } catch {
            print("Wispr: could not record the widget tap — \(error)")
        }
    }
}

// MARK: - Intents

/// Opens a note inside the widget, without leaving the Home Screen.
struct FocusWidgetNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a Note in the Widget"
    static let isDiscoverable = false

    @Parameter(title: "Note") var noteID: String

    init() {}

    init(noteID: UUID) {
        self.noteID = noteID.uuidString
    }

    func perform() async throws -> some IntentResult {
        WidgetFocus.set(UUID(uuidString: noteID))
        return .result()
    }
}

/// Back out of a focused note to the day's list.
struct ShowWidgetTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Today in the Widget"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WidgetFocus.set(nil)
        return .result()
    }
}

/// Crosses a checklist item off, or back on.
struct ToggleWidgetChecklistItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Cross Off a Checklist Item"
    static let isDiscoverable = false

    @Parameter(title: "Note") var noteID: String
    @Parameter(title: "Item") var blockID: String
    @Parameter(title: "Crossed Off") var isChecked: Bool

    init() {}

    init(noteID: UUID, blockID: UUID, isChecked: Bool) {
        self.noteID = noteID.uuidString
        self.blockID = blockID.uuidString
        self.isChecked = isChecked
    }

    func perform() async throws -> some IntentResult {
        guard let note = UUID(uuidString: noteID), let block = UUID(uuidString: blockID) else {
            return .result()
        }

        WidgetActionQueue.append(
            WidgetAction(id: UUID(), noteID: note, blockID: block, isChecked: isChecked, date: .now)
        )
        return .result()
    }
}

// MARK: - Timeline

private struct TodayNotesEntry: TimelineEntry {
    let date: Date
    let notes: [WidgetNote]
    var focusedNoteID: UUID?
    var theme: WidgetTheme = .standard
    var type = WidgetTypeScale()

    var focusedNote: WidgetNote? {
        guard let focusedNoteID else { return nil }
        return notes.first { $0.id == focusedNoteID }
    }
}

private struct TodayNotesProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayNotesEntry {
        TodayNotesEntry(date: .now, notes: Self.previewNotes, theme: .current, type: .current)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayNotesEntry) -> Void) {
        let now = Date.now
        guard !context.isPreview else {
            completion(TodayNotesEntry(date: now, notes: Self.previewNotes, theme: .current, type: .current))
            return
        }

        completion(
            TodayNotesEntry(
                date: now,
                notes: Self.loadNotes(for: now),
                focusedNoteID: WidgetFocus.current(at: now)?.id,
                theme: .current,
                type: .current
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayNotesEntry>) -> Void) {
        let now = Date.now
        let notes = Self.loadNotes(for: now)
        let focus = WidgetFocus.current(at: now)
        let theme = WidgetTheme.current
        let type = WidgetTypeScale.current
        let midnight = Self.nextMidnight(after: now)

        var entries = [
            TodayNotesEntry(date: now, notes: notes, focusedNoteID: focus?.id, theme: theme, type: type)
        ]
        // A second entry drops the focus again on its own.
        if let focus, focus.expiry < midnight {
            entries.append(TodayNotesEntry(date: focus.expiry, notes: notes, theme: theme, type: type))
        }

        completion(Timeline(entries: entries, policy: .after(midnight)))
    }

    private static func loadNotes(for date: Date) -> [WidgetNote] {
        guard let fileURL = WidgetBridge.sharedFile(WidgetBridge.filename),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return [] }

        let notes = snapshot.notesByDay[dayKey(for: date)] ?? []
        return applying(WidgetActionQueue.pending(), to: notes)
    }

    /// Draws in the taps the app hasn't written into the notes yet.
    private static func applying(_ actions: [WidgetAction], to notes: [WidgetNote]) -> [WidgetNote] {
        guard !actions.isEmpty else { return notes }

        return notes.map { note in
            let mine = actions.filter { $0.noteID == note.id }
            guard !mine.isEmpty else { return note }

            var edited = note
            for action in mine {
                guard let index = edited.blocks.firstIndex(where: { $0.id == action.blockID }) else { continue }
                edited.blocks[index].isChecked = action.isChecked
            }

            // The same stable partition the app makes: crossed-off items sink to
            // the bottom of the note, everything else keeps its order.
            edited.blocks = edited.blocks.filter { !$0.isChecked } + edited.blocks.filter(\.isChecked)
            return edited
        }
    }

    private static func dayKey(for day: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    private static func nextMidnight(after date: Date) -> Date {
        let start = Calendar.current.startOfDay(for: date)
        return (Calendar.current.date(byAdding: .day, value: 1, to: start) ?? date)
            .addingTimeInterval(5)
    }

    static let previewNotes = [
        WidgetNote(
            id: UUID(),
            blocks: [
                WidgetBlock(id: UUID(), text: "Sketch the Today widget", kind: "paragraph", isChecked: false, number: nil, indent: 0),
                WidgetBlock(id: UUID(), text: "Test long notes on a small phone", kind: "checklist", isChecked: false, number: nil, indent: 0),
                WidgetBlock(id: UUID(), text: "Check the empty day", kind: "checklist", isChecked: false, number: nil, indent: 0),
                WidgetBlock(id: UUID(), text: "Read the widget guidelines", kind: "checklist", isChecked: true, number: nil, indent: 0)
            ],
            schedule: "Due by 11:30 AM",
            imageCount: 2,
            voiceMemoCount: 0
        ),
        WidgetNote(
            id: UUID(),
            blocks: [
                WidgetBlock(id: UUID(), text: "Dinner ideas for the weekend", kind: "paragraph", isChecked: false, number: nil, indent: 0)
            ],
            schedule: nil,
            imageCount: 0,
            voiceMemoCount: 1
        ),
        WidgetNote(
            id: UUID(),
            blocks: [
                WidgetBlock(id: UUID(), text: "Send the updated build", kind: "checklist", isChecked: true, number: nil, indent: 0)
            ],
            schedule: nil,
            imageCount: 0,
            voiceMemoCount: 0
        )
    ]
}

// MARK: - View

private struct TodayNotesWidgetView: View {
    let entry: TodayNotesEntry

    private var theme: WidgetTheme { entry.theme }

    /// The three kinds of widget text, each at the size it has been set to.
    private func headerFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        theme.font(size * entry.type.header, weight: weight)
    }

    private func listFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        theme.font(size * entry.type.list, weight: weight)
    }

    private func detailFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        theme.font(size * entry.type.detail, weight: weight)
    }
    private var focused: WidgetNote? { entry.focusedNote }
    private var isEmpty: Bool { entry.notes.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let focused {
                focusedNote(focused)
            } else if isEmpty {
                // Nothing to list, so the day itself fills the widget.
                clockAndCalendar
            } else {
                ViewThatFits(in: .vertical) {
                    noteList(limit: 8)
                    noteList(limit: 7)
                    noteList(limit: 6)
                    noteList(limit: 5)
                    noteList(limit: 4)
                    noteList(limit: 3)
                    noteList(limit: 2)
                    noteList(limit: 1)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            newNoteButton
        }
        .padding(18)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            theme.background
        }
        .widgetURL(WidgetLink.today)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Out of a note and back to the day, still without leaving the
            // Home Screen.
            if focused != nil {
                Button(intent: ShowWidgetTodayIntent()) {
                    Image(systemName: "chevron.left")
                        .font(headerFont(15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 26, height: 26)
                        .background(theme.buttonFill, in: theme.buttonShape)
                        .overlay {
                            theme.buttonShape.stroke(theme.border)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to today")
            }

            // The title always opens the app, focused or not.
            titleLink

            Spacer()

            if !isEmpty, focused == nil {
                Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(headerFont(13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private var titleLink: some View {
        let title = HStack(spacing: 9) {
            WidgetLogo()
                .frame(width: 18, height: 18)

            Text("Today")
                .font(headerFont(22, weight: .semibold))
        }

        if let destination = WidgetLink.today {
            Link(destination: destination) { title }
                .accessibilityLabel("Open Wispr")
        } else {
            title
        }
    }

    // MARK: A focused note

    /// One note, given the whole widget: every line, and a checklist you can
    /// cross off from here.
    private func focusedNote(_ note: WidgetNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if note.hasMeta {
                meta(of: note)
            }

            ViewThatFits(in: .vertical) {
                lines(of: note, size: 16)
                lines(of: note, size: 15)
                lines(of: note, size: 14)
                lines(of: note, size: 13)
                lines(of: note, size: 12)
            }

            if note.blocks.isEmpty {
                Text("Attachment")
                    .font(detailFont(15))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func lines(of note: WidgetNote, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: size * 0.45) {
            ForEach(note.blocks) { block in
                line(block, in: note, size: size)
                    .padding(.leading, CGFloat(block.indent) * 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func line(_ block: WidgetBlock, in note: WidgetNote, size: CGFloat) -> some View {
        if block.isChecklistItem {
            Button(
                intent: ToggleWidgetChecklistItemIntent(
                    noteID: note.id,
                    blockID: block.id,
                    isChecked: !block.isChecked
                )
            ) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: block.isChecked ? "checkmark.circle.fill" : "circle")
                        .font(detailFont(size - 1))
                        .foregroundStyle(.white.opacity(block.isChecked ? 0.45 : 0.75))

                    Text(block.text)
                        .font(detailFont(size))
                        .strikethrough(block.isChecked, color: .white.opacity(0.4))
                        .foregroundStyle(.white.opacity(block.isChecked ? 0.42 : 1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(block.text)
            .accessibilityHint(block.isChecked ? "Crosses the item back on" : "Crosses the item off")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if let marker = block.marker {
                    Text(marker)
                        .font(detailFont(size))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Text(block.text)
                    .font(detailFont(size))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: The day's list

    private func noteList(limit: Int) -> some View {
        let shown = Array(entry.notes.prefix(limit))
        let overflow = max(0, entry.notes.count - shown.count)

        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, note in
                if index > 0 {
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: 1)
                }

                // A tap opens the note here rather than in the app, so the whole
                // of it can be read without leaving the Home Screen.
                Button(intent: FocusWidgetNoteIntent(noteID: note.id)) {
                    noteRow(note)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(note.summary)
                .accessibilityHint("Opens this note in the widget")
            }

            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(listFont(12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
    }

    private func noteRow(_ note: WidgetNote) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(note.summary)
                .font(listFont(15))
                .lineSpacing(2)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if note.hasMeta {
                meta(of: note)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// When a note happens and what it carries besides words.
    private func meta(of note: WidgetNote) -> some View {
        HStack(spacing: 12) {
            if let schedule = note.schedule {
                Label(schedule, systemImage: "clock")
            }
            if note.imageCount > 0 {
                Label("\(note.imageCount)", systemImage: "photo")
            }
            if note.voiceMemoCount > 0 {
                Label("\(note.voiceMemoCount)", systemImage: "waveform")
            }
        }
        .font(theme.font(11, weight: .medium))
        .foregroundStyle(.white.opacity(0.46))
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }

    // MARK: An empty day

    /// The face shown on a day with nothing written down: the time, the date,
    /// and the month around it.
    private var clockAndCalendar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.date, style: .time)
                    .font(theme.clockFont(44))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(entry.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(theme.font(14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)

            MonthCalendar(date: entry.date, theme: theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: New note

    /// Straight into a new note for today, without a stop on the way.
    @ViewBuilder
    private var newNoteButton: some View {
        if let destination = WidgetLink.newNote {
            HStack {
                Spacer()

                Link(destination: destination) {
                    Image(systemName: "plus")
                        .font(theme.font(19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(theme.buttonFill, in: theme.buttonShape)
                        .overlay {
                            theme.buttonShape.stroke(theme.border)
                        }
                }
                .accessibilityLabel("New note")
            }
        }
    }
}

// MARK: - Month calendar

/// The month `date` falls in, laid out as a week-per-row grid with today marked.
private struct MonthCalendar: View {
    let date: Date
    let theme: WidgetTheme

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(theme.font(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        cell(for: day)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func cell(for day: Int?) -> some View {
        if let day {
            let isToday = day == calendar.component(.day, from: date)

            Text("\(day)")
                .font(theme.font(13, weight: isToday ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? theme.markedDay : .white.opacity(0.72))
                .frame(width: 26, height: 26)
                .background {
                    if isToday {
                        theme.buttonShape.fill(.white)
                    }
                }
                .frame(maxWidth: .infinity)
        } else {
            Color.clear
                .frame(height: 26)
                .frame(maxWidth: .infinity)
        }
    }

    /// Weeks of the month, each seven cells wide; `nil` where the month has not
    /// begun or has already ended.
    private var weeks: [[Int?]] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let days = calendar.range(of: .day, in: .month, for: date)
        else { return [] }

        let firstWeekday = calendar.component(.weekday, from: month.start)
        let leadingBlanks = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [Int?] = Array(repeating: nil, count: leadingBlanks) + days.map { $0 }
        while cells.count % 7 != 0 {
            cells.append(nil)
        }

        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// Weekday initials rotated to start on the locale's first day of the week.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let start = min(max(calendar.firstWeekday - 1, 0), symbols.count - 1)
        return Array(symbols[start...] + symbols[..<start])
    }
}

private struct WidgetLogo: View {
    var body: some View {
        GeometryReader { proxy in
            let cell = proxy.size.width * 0.42
            let gap = proxy.size.width - cell * 2

            ZStack(alignment: .topLeading) {
                square(cell)
                square(cell).offset(x: cell + gap)
                square(cell).offset(y: cell + gap)
            }
        }
    }

    private func square(_ size: CGFloat) -> some View {
        Rectangle()
            .fill(.white)
            .frame(width: size, height: size)
    }
}

struct TodayNotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBridge.kind, provider: TodayNotesProvider()) { entry in
            TodayNotesWidgetView(entry: entry)
        }
        .configurationDisplayName("Today’s Notes")
        .description("See what you wrote down for today.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct WisprWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayNotesWidget()
    }
}

#Preview("Mixed notes", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(date: .now, notes: TodayNotesProvider.previewNotes)
}

#Preview("Focused note", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(
        date: .now,
        notes: TodayNotesProvider.previewNotes,
        focusedNoteID: TodayNotesProvider.previewNotes[0].id
    )
}

#Preview("Empty", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(date: .now, notes: [])
}

#Preview("Legacy notes", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(date: .now, notes: TodayNotesProvider.previewNotes, theme: .legacy)
}

#Preview("Legacy empty", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(date: .now, notes: [], theme: .legacy)
}
