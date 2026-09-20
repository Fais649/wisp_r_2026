import AppIntents
import SwiftUI
import WidgetKit

private enum WidgetBridge {
    static let appGroup = "group.com.punksys.wispr"
    static let filename = "TodayWidgetSnapshot.json"
    static let actionsFilename = "TodayWidgetActions.json"
    static let timelinesFilename = "TodayWidgetTimelines.json"
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

    static func note(_ id: UUID) -> URL? {
        URL(string: "wispr://note/\(id.uuidString)")
    }
}

/// What a tap on a note does, as chosen in the app's settings.
private enum WidgetNoteTap: String {
    case openInApp
    case focusInWidget

    static var current: WidgetNoteTap {
        let stored = WidgetBridge.sharedDefaults?.string(forKey: "widgetNoteTap") ?? ""
        return WidgetNoteTap(rawValue: stored) ?? .openInApp
    }
}

// MARK: - Theme

/// The look the app is wearing, read from the settings it shares with the
/// widget. Kept as its own small copy rather than shared code, because the
/// widget draws a different set of things than the app does.
private enum WidgetTheme: String {
    case standard
    case legacy
    case newspaper

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
        case .newspaper:
            .system(size: size, weight: weight, design: .serif)
        }
    }

    /// The clock is the one place the default theme rounds its digits.
    func clockFont(_ size: CGFloat) -> Font {
        switch self {
        case .standard: .system(size: size, weight: .semibold, design: .rounded)
        case .legacy, .newspaper: font(size, weight: .semibold)
        }
    }

    var ink: Color {
        switch self {
        case .standard, .legacy: .white
        case .newspaper: Color(red: 0.11, green: 0.10, blue: 0.09)
        }
    }

    var onAccent: Color { .white }

    var separator: Color {
        switch self {
        case .standard: ink.opacity(0.09)
        case .legacy: ink.opacity(0.18)
        case .newspaper: ink.opacity(0.28)
        }
    }

    var border: Color {
        switch self {
        case .standard: ink.opacity(0.16)
        case .legacy: ink.opacity(0.22)
        case .newspaper: ink.opacity(0.3)
        }
    }

    /// Legacy draws its buttons rather than filling them.
    var buttonFill: Color {
        switch self {
        case .standard: ink.opacity(0.12)
        case .legacy: .clear
        case .newspaper: ink.opacity(0.06)
        }
    }

    /// Round in the default theme, square-ish in legacy.
    var buttonShape: AnyShape {
        switch self {
        case .standard: AnyShape(Circle())
        case .legacy: AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .newspaper: AnyShape(Rectangle())
        }
    }

    /// The checklist box, drawn the way the app draws it.
    var markShape: AnyShape {
        switch self {
        case .standard: AnyShape(Circle())
        case .legacy, .newspaper: AnyShape(Rectangle())
        }
    }

    /// The surface a note card sits on. The widget has no glass, so the default
    /// theme fills a little more strongly than the app's card does.
    var cardFill: Color {
        switch self {
        case .standard: ink.opacity(0.09)
        case .legacy: ink.opacity(0.03)
        case .newspaper: Color(red: 0.97, green: 0.96, blue: 0.93)
        }
    }

    /// Legacy draws boxes rather than filling them.
    var cardBorder: Color? {
        switch self {
        case .standard: nil
        case .legacy: ink.opacity(0.22)
        case .newspaper: ink.opacity(0.26)
        }
    }

    /// Legacy keeps its corners nearly square.
    func cardRadius(_ requested: CGFloat) -> CGFloat {
        switch self {
        case .standard: requested
        case .legacy: min(requested, 4)
        case .newspaper: 0
        }
    }

    /// The colour today's date is written in once it has been marked.
    var markedDay: Color {
        switch self {
        case .standard: Color(red: 0.19, green: 0.185, blue: 0.195)
        case .legacy: .black
        case .newspaper: Color(red: 0.94, green: 0.93, blue: 0.89)
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
        case .newspaper:
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.93, blue: 0.89),
                    Color(red: 0.91, green: 0.89, blue: 0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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
    /// Missing from snapshots written before notes carried a heading.
    var title: String?
    var blocks: [WidgetBlock]
    let schedule: String?
    let imageCount: Int
    let voiceMemoCount: Int
    /// The timeline the note is filed under, looked up in the entry's map.
    var timelineID: UUID?

    var hasMeta: Bool { schedule != nil || imageCount > 0 || voiceMemoCount > 0 }

    var checkedItems: [WidgetBlock] { blocks.filter { $0.isChecklistItem && $0.isChecked } }
    /// Everything still worth reading: the note's words, minus what has been
    /// crossed off.
    var openLines: [WidgetBlock] { blocks.filter { !($0.isChecklistItem && $0.isChecked) } }
    var openItemCount: Int { blocks.filter { $0.isChecklistItem && !$0.isChecked }.count }

    /// The note read aloud in one run, for the card's accessibility label.
    var summary: String {
        let lines = [title].compactMap { $0 } + blocks.map(\.listLine)
        guard !lines.isEmpty else { return "Attachment" }
        return lines.joined(separator: "\n")
    }
}

/// A timeline as the widget needs it, published by the app beside the notes.
private struct WidgetTimeline: Decodable {
    let name: String
    let icon: String
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }
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
    private static let checkedKey = "focusedShowsChecked"

    /// Whether the focused note is showing what has been crossed off rather
    /// than what is left to do.
    static var showsChecked: Bool {
        WidgetBridge.sharedDefaults?.bool(forKey: checkedKey) ?? false
    }

    static func setShowsChecked(_ showsChecked: Bool) {
        WidgetBridge.sharedDefaults?.set(showsChecked, forKey: checkedKey)
    }

    /// The widget finds its way back to the day by itself, so a note left
    /// focused doesn't hide today for good.
    static let lifetime: TimeInterval = 10 * 60

    static func set(_ noteID: UUID?) {
        guard let defaults = WidgetBridge.sharedDefaults else { return }
        // Every note opens on what is still to be done.
        defaults.removeObject(forKey: checkedKey)

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

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetFocus.set(UUID(uuidString: noteID))
        return .result()
    }
}

/// Back out of a focused note to the day's list.
struct ShowWidgetTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Today in the Widget"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetFocus.set(nil)
        return .result()
    }
}

/// Swaps a focused note between what is left to do and what has been crossed
/// off, so neither list has to share the widget with the other.
struct ShowWidgetCrossedOffIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Crossed-Off Items"
    static let isDiscoverable = false

    @Parameter(title: "Crossed Off") var showsChecked: Bool

    init() {}

    init(showsChecked: Bool) {
        self.showsChecked = showsChecked
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetFocus.setShowsChecked(showsChecked)
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

    @MainActor
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
    /// Every timeline the app knows of, by id.
    var timelines: [String: WidgetTimeline] = [:]
    /// Set while the focused note is showing what has been crossed off.
    var showsChecked = false
    /// What a tap on a note does.
    var noteTap: WidgetNoteTap = .openInApp

    var focusedNote: WidgetNote? {
        guard let focusedNoteID else { return nil }
        return notes.first { $0.id == focusedNoteID }
    }

    /// The timeline a note is filed under, if it still exists.
    func timeline(of note: WidgetNote) -> WidgetTimeline? {
        guard let id = note.timelineID else { return nil }
        return timelines[id.uuidString]
    }
}

private struct TodayNotesProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayNotesEntry {
        TodayNotesEntry(
            date: .now,
            notes: Self.previewNotes,
            theme: .current,
            type: .current,
            timelines: Self.previewTimelines
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayNotesEntry) -> Void) {
        let now = Date.now
        guard !context.isPreview else {
            completion(
                TodayNotesEntry(
                    date: now,
                    notes: Self.previewNotes,
                    theme: .current,
                    type: .current,
                    timelines: Self.previewTimelines
                )
            )
            return
        }

        completion(
            TodayNotesEntry(
                date: now,
                notes: Self.loadNotes(for: now),
                focusedNoteID: WidgetFocus.current(at: now)?.id,
                theme: .current,
                type: .current,
                timelines: Self.loadTimelines(),
                showsChecked: WidgetFocus.showsChecked,
                noteTap: .current
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayNotesEntry>) -> Void) {
        let now = Date.now
        let notes = Self.loadNotes(for: now)
        let focus = WidgetFocus.current(at: now)
        let theme = WidgetTheme.current
        let type = WidgetTypeScale.current
        let timelines = Self.loadTimelines()
        let noteTap = WidgetNoteTap.current
        let midnight = Self.nextMidnight(after: now)

        var entries = [
            TodayNotesEntry(
                date: now,
                notes: notes,
                focusedNoteID: focus?.id,
                theme: theme,
                type: type,
                timelines: timelines,
                showsChecked: WidgetFocus.showsChecked,
                noteTap: noteTap
            )
        ]
        // A second entry drops the focus again on its own.
        if let focus, focus.expiry < midnight {
            entries.append(
                TodayNotesEntry(
                    date: focus.expiry,
                    notes: notes,
                    theme: theme,
                    type: type,
                    timelines: timelines,
                    noteTap: noteTap
                )
            )
        }

        completion(Timeline(entries: entries, policy: .after(midnight)))
    }

    private static func loadTimelines() -> [String: WidgetTimeline] {
        guard let fileURL = WidgetBridge.sharedFile(WidgetBridge.timelinesFilename),
              let data = try? Data(contentsOf: fileURL),
              let timelines = try? JSONDecoder().decode([String: WidgetTimeline].self, from: data)
        else { return [:] }

        return timelines
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

    private static let programmingID = UUID()
    private static let friendsID = UUID()

    static let previewTimelines: [String: WidgetTimeline] = [
        programmingID.uuidString: WidgetTimeline(
            name: "Programming",
            icon: "chevron.left.forwardslash.chevron.right",
            red: 0.44,
            green: 0.39,
            blue: 0.27
        ),
        friendsID.uuidString: WidgetTimeline(
            name: "Friends",
            icon: "person.2.fill",
            red: 0.42,
            green: 0.23,
            blue: 0.28
        )
    ]

    /// A note long enough to need both the cap and the crossed-off button.
    static let previewLongNote = WidgetNote(
        id: UUID(),
        title: "Prototype enhancements",
        blocks: [
            WidgetBlock(id: UUID(), text: "photo sync", kind: "checklist", isChecked: false, number: nil, indent: 0),
            WidgetBlock(id: UUID(), text: "ipod scrollwheel/dial style date navigation prototype", kind: "checklist", isChecked: false, number: nil, indent: 0),
            WidgetBlock(id: UUID(), text: "share sheet", kind: "checklist", isChecked: false, number: nil, indent: 0),
            WidgetBlock(id: UUID(), text: "add timelines", kind: "checklist", isChecked: false, number: nil, indent: 0),
            WidgetBlock(id: UUID(), text: "zooming into map reveals note content like on an infinite canvas", kind: "checklist", isChecked: false, number: nil, indent: 0),
            WidgetBlock(id: UUID(), text: "multiline checklist item should indent all lines", kind: "checklist", isChecked: true, number: nil, indent: 0),
            WidgetBlock(id: UUID(), text: "drag to reorder note order", kind: "checklist", isChecked: true, number: nil, indent: 0),
            WidgetBlock(id: UUID(), text: "better checkbox icons (bigger, more distinct)", kind: "checklist", isChecked: true, number: nil, indent: 0),
            WidgetBlock(id: UUID(), text: "light floating animations on icons like they drifting in space", kind: "checklist", isChecked: true, number: nil, indent: 0),
            WidgetBlock(id: UUID(), text: "move note icons to outside circle and have thin line point to map location", kind: "checklist", isChecked: true, number: nil, indent: 0)
        ],
        schedule: nil,
        imageCount: 0,
        voiceMemoCount: 0,
        timelineID: programmingID
    )

    static let previewNotes = [
        WidgetNote(
            id: UUID(),
            title: "Today’s widget pass",
            blocks: [
                WidgetBlock(id: UUID(), text: "Sketch the Today widget", kind: "paragraph", isChecked: false, number: nil, indent: 0),
                WidgetBlock(id: UUID(), text: "Test long notes on a small phone, the kind that wrap onto a second line", kind: "checklist", isChecked: false, number: nil, indent: 0),
                WidgetBlock(id: UUID(), text: "Check the empty day", kind: "checklist", isChecked: false, number: nil, indent: 0),
                WidgetBlock(id: UUID(), text: "Read the widget guidelines", kind: "checklist", isChecked: true, number: nil, indent: 0)
            ],
            schedule: "Due by 11:30 AM",
            imageCount: 2,
            voiceMemoCount: 0,
            timelineID: programmingID
        ),
        WidgetNote(
            id: UUID(),
            title: "Dinner ideas",
            blocks: [
                WidgetBlock(id: UUID(), text: "Dinner ideas for the weekend", kind: "paragraph", isChecked: false, number: nil, indent: 0)
            ],
            schedule: nil,
            imageCount: 0,
            voiceMemoCount: 1,
            timelineID: friendsID
        ),
        WidgetNote(
            id: UUID(),
            title: "Ship it",
            blocks: [
                WidgetBlock(id: UUID(), text: "Send the updated build", kind: "checklist", isChecked: true, number: nil, indent: 0)
            ],
            schedule: nil,
            imageCount: 0,
            voiceMemoCount: 0,
            timelineID: nil
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
                // Richest first, and the first that fits wins: the day gives up
                // detail on every note before it gives up a note.
                ViewThatFits(in: .vertical) {
                    noteList(limit: 8, blocks: 4)
                    noteList(limit: 8, blocks: 2)
                    noteList(limit: 8, blocks: 1)
                    noteList(limit: 8, blocks: 0)
                    noteList(limit: 6, blocks: 0)
                    noteList(limit: 5, blocks: 0)
                    noteList(limit: 4, blocks: 0)
                    noteList(limit: 3, blocks: 0)
                    noteList(limit: 2, blocks: 0)
                    noteList(limit: 1, blocks: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            bottomBar
        }
        .padding(18)
        .foregroundStyle(theme.ink)
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
                        .foregroundStyle(theme.ink.opacity(0.75))
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
                    .foregroundStyle(theme.ink.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private var titleLink: some View {
        let title = HStack(spacing: 9) {
            WidgetLogo(theme: theme)
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

    /// One note, given the whole widget: what is left to do, and a checklist
    /// you can cross off from here.
    ///
    /// Crossed-off items are put away behind the button below rather than
    /// shown, and the lines that remain are capped rather than shrunk past
    /// reading size — a box too small to hit is worth less than a line the
    /// note doesn't show.
    private func focusedNote(_ note: WidgetNote) -> some View {
        let lines = entry.showsChecked ? note.checkedItems : note.openLines

        return ViewThatFits(in: .vertical) {
            focusedCard(note, lines: lines, limit: 8, size: 17)
            focusedCard(note, lines: lines, limit: 7, size: 17)
            focusedCard(note, lines: lines, limit: 6, size: 16)
            focusedCard(note, lines: lines, limit: 5, size: 16)
            focusedCard(note, lines: lines, limit: 4, size: 15)
            focusedCard(note, lines: lines, limit: 3, size: 15)
            focusedCard(note, lines: lines, limit: 2, size: 15)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func focusedCard(
        _ note: WidgetNote,
        lines: [WidgetBlock],
        limit: Int,
        size: CGFloat
    ) -> some View {
        noteCard(
            note,
            lines: lines,
            size: size,
            scale: entry.type.detail,
            interactive: true,
            blockLimit: limit,
            emptyLabel: entry.showsChecked ? "Nothing crossed off yet" : nil
        )
    }

    // MARK: A note as a card

    /// A note drawn the way the app draws it: a card washed with its timeline's
    /// colour, that timeline's mark in the corner, and the note's own heading
    /// above its lines.
    ///
    /// `blockLimit` and `lineLimit` are how the day's list keeps a long note to
    /// a glance; a focused note passes neither and is drawn whole.
    private func noteCard(
        _ note: WidgetNote,
        lines: [WidgetBlock],
        size: CGFloat,
        scale: CGFloat,
        interactive: Bool,
        blockLimit: Int? = nil,
        lineLimit: Int? = nil,
        emptyLabel: String? = nil
    ) -> some View {
        let timeline = entry.timeline(of: note)
        let radius = theme.cardRadius(14)
        let title = note.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A heading can stand for the note on its own, but a note without one
        // always shows a line, whatever the day's list asked for.
        let allowance = blockLimit.map { title.isEmpty ? max($0, 1) : $0 }
        let shown = allowance.map { Array(lines.prefix($0)) } ?? lines
        let hidden = lines.count - shown.count
        let placeholder = shown.isEmpty ? (emptyLabel ?? (title.isEmpty ? "Attachment" : nil)) : nil

        func font(_ points: CGFloat, weight: Font.Weight = .regular) -> Font {
            theme.font(points * scale, weight: weight)
        }

        return VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                Text(title)
                    .font(font(size + 3, weight: .semibold))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Leaves the corner to the mark, as the app's card does.
                    .padding(.trailing, timeline == nil ? 0 : 26)
            }

            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { block in
                        line(
                            block,
                            in: note,
                            size: size,
                            scale: scale,
                            interactive: interactive,
                            lineLimit: lineLimit
                        )
                        .padding(.leading, CGFloat(block.indent) * 18)
                    }
                }
            }

            if let placeholder {
                Text(placeholder)
                    .font(font(size - 2))
                    .foregroundStyle(theme.ink.opacity(0.5))
            }

            // The lines that didn't fit are counted alongside the note's other
            // marks rather than on a line of their own, which would cost the
            // very room they were cut for.
            if note.hasMeta || hidden > 0 {
                meta(of: note, hiddenLines: hidden)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                theme.cardFill
                if let timeline {
                    timeline.color.opacity(0.38)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if let border = theme.cardBorder {
                RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(border)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let timeline {
                timelineMark(timeline)
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
    }

    /// The timeline's symbol on its colour, as it reads in the app.
    private func timelineMark(_ timeline: WidgetTimeline, size: CGFloat = 22) -> some View {
        Image(systemName: timeline.icon)
            .font(theme.font(size * 0.55))
            .foregroundStyle(theme.onAccent)
            .frame(width: size, height: size)
            .background(
                timeline.color,
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func line(
        _ block: WidgetBlock,
        in note: WidgetNote,
        size: CGFloat,
        scale: CGFloat,
        interactive: Bool,
        lineLimit: Int?
    ) -> some View {
        if block.isChecklistItem {
            if interactive {
                Button(
                    intent: ToggleWidgetChecklistItemIntent(
                        noteID: note.id,
                        blockID: block.id,
                        isChecked: !block.isChecked
                    )
                ) {
                    checklistRow(block, size: size, scale: scale, lineLimit: lineLimit)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(block.text)
                .accessibilityHint(block.isChecked ? "Crosses the item back on" : "Crosses the item off")
            } else {
                // In the day's list the whole card is the button, so the boxes
                // are drawn rather than offered.
                checklistRow(block, size: size, scale: scale, lineLimit: lineLimit)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let marker = block.marker {
                    Text(marker)
                        .font(theme.font(size * scale))
                        .foregroundStyle(theme.ink.opacity(0.6))
                        .frame(minWidth: 14, alignment: .leading)
                }

                // Its own column, so a line that wraps stays clear of the marker.
                Text(block.text)
                    .font(theme.font(size * scale))
                    .lineSpacing(2)
                    .lineLimit(lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func checklistRow(
        _ block: WidgetBlock,
        size: CGFloat,
        scale: CGFloat,
        lineLimit: Int?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // The app draws a 23pt box against 17pt text; kept in proportion as
            // the widget shrinks its type to fit.
            WidgetChecklistMark(
                isChecked: block.isChecked,
                theme: theme,
                size: size * scale * (23 / 17)
            )
            .padding(.top, 1)

            Text(block.text)
                .font(theme.font(size * scale))
                .lineSpacing(2)
                .strikethrough(block.isChecked, color: theme.ink.opacity(0.45))
                .foregroundStyle(block.isChecked ? theme.ink.opacity(0.4) : theme.ink)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: The day's list

    /// A tapped note either opens here, without leaving the Home Screen, or in
    /// the app on the note itself — whichever the app's settings ask for.
    @ViewBuilder
    private func tapTarget<Content: View>(
        for note: WidgetNote,
        @ViewBuilder content: () -> Content
    ) -> some View {
        switch entry.noteTap {
        case .focusInWidget:
            Button(intent: FocusWidgetNoteIntent(noteID: note.id)) {
                content()
            }
            .buttonStyle(.plain)

        case .openInApp:
            if let destination = WidgetLink.note(note.id) {
                Link(destination: destination) { content() }
            } else {
                content()
            }
        }
    }

    /// `blocks` is how many of each note's lines the card carries; at zero the
    /// heading stands for the note on its own.
    private func noteList(limit: Int, blocks: Int) -> some View {
        let shown = Array(entry.notes.prefix(limit))
        let overflow = max(0, entry.notes.count - shown.count)

        return VStack(spacing: 10) {
            ForEach(shown) { note in
                tapTarget(for: note) {
                    noteCard(
                        note,
                        lines: note.blocks,
                        size: 17,
                        scale: entry.type.list,
                        interactive: false,
                        blockLimit: blocks,
                        lineLimit: blocks <= 1 ? 2 : 1
                    )
                }
                .accessibilityLabel(note.summary)
                .accessibilityHint(
                    entry.noteTap == .focusInWidget
                        ? "Opens this note in the widget"
                        : "Opens this note in Wispr"
                )
            }

            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(listFont(12, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// When a note happens, what it carries besides words, and how much of it
    /// the card had to leave out.
    private func meta(of note: WidgetNote, hiddenLines: Int = 0) -> some View {
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
            if hiddenLines > 0 {
                Label("+\(hiddenLines)", systemImage: "text.alignleft")
            }
        }
        .font(theme.font(11, weight: .medium))
        .foregroundStyle(theme.ink.opacity(0.46))
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
                    .foregroundStyle(theme.ink.opacity(0.5))
            }

            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)

            MonthCalendar(date: entry.date, theme: theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: The bottom row

    /// What has been crossed off on the left, a new note on the right.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let focused, !focused.checkedItems.isEmpty || entry.showsChecked {
                crossedOffToggle(focused)
            }

            Spacer(minLength: 0)

            newNoteButton
        }
    }

    /// Swaps the focused note between what is left and what is done: one list
    /// at a time, so neither has to be squeezed to fit beside the other.
    private func crossedOffToggle(_ note: WidgetNote) -> some View {
        let showing = entry.showsChecked
        let count = showing ? note.openItemCount : note.checkedItems.count
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius(17), style: .continuous)

        return Button(intent: ShowWidgetCrossedOffIntent(showsChecked: !showing)) {
            HStack(spacing: 7) {
                Image(systemName: showing ? "circle" : "checkmark.circle")
                Text(showing ? "\(count) to do" : "\(count) done")
            }
            .font(headerFont(13, weight: .medium))
            .foregroundStyle(theme.ink.opacity(0.75))
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(theme.buttonFill, in: shape)
            .overlay { shape.stroke(theme.border) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showing ? "Show what is left to do" : "Show what is crossed off")
    }

    /// Straight into a new note for today, without a stop on the way.
    @ViewBuilder
    private var newNoteButton: some View {
        if let destination = WidgetLink.newNote {
            Link(destination: destination) {
                Image(systemName: "plus")
                    .font(theme.font(19, weight: .semibold))
                    .foregroundStyle(theme.ink)
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

// MARK: - Month calendar

/// The month `date` falls in, laid out as a week-per-row grid with today marked.
private struct MonthCalendar: View {
    let date: Date
    let theme: WidgetTheme

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(weekdaySymbols.enumerated(), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(theme.font(11, weight: .semibold))
                        .foregroundStyle(theme.ink.opacity(0.35))
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(weeks.enumerated(), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(week.enumerated(), id: \.offset) { _, day in
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
                .foregroundStyle(isToday ? theme.markedDay : theme.ink.opacity(0.72))
                .frame(width: 26, height: 26)
                .background {
                    if isToday {
                        theme.buttonShape.fill(theme.ink)
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

/// The checklist box, drawn the way the app draws it: a ring in the default
/// theme, a square in legacy.
private struct WidgetChecklistMark: View {
    let isChecked: Bool
    let theme: WidgetTheme
    var size: CGFloat = 23

    var body: some View {
        ZStack {
            theme.markShape
                .stroke(theme.ink.opacity(isChecked ? 0.5 : 0.72), lineWidth: 1.5)

            if isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.52, weight: .bold))
                    .foregroundStyle(theme.ink.opacity(0.68))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct WidgetLogo: View {
    let theme: WidgetTheme

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
            .fill(theme.ink)
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

#if DEBUG
#Preview("Mixed notes", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(
        date: .now,
        notes: TodayNotesProvider.previewNotes,
        timelines: TodayNotesProvider.previewTimelines
    )
}

#Preview("Focused note", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(
        date: .now,
        notes: TodayNotesProvider.previewNotes,
        focusedNoteID: TodayNotesProvider.previewNotes[0].id,
        timelines: TodayNotesProvider.previewTimelines
    )
}

#Preview("Long checklist", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(
        date: .now,
        notes: [TodayNotesProvider.previewLongNote],
        focusedNoteID: TodayNotesProvider.previewLongNote.id,
        timelines: TodayNotesProvider.previewTimelines
    )
}

#Preview("Crossed off", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(
        date: .now,
        notes: [TodayNotesProvider.previewLongNote],
        focusedNoteID: TodayNotesProvider.previewLongNote.id,
        timelines: TodayNotesProvider.previewTimelines,
        showsChecked: true
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
    TodayNotesEntry(
        date: .now,
        notes: TodayNotesProvider.previewNotes,
        theme: .legacy,
        timelines: TodayNotesProvider.previewTimelines
    )
}

#Preview("Legacy empty", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(date: .now, notes: [], theme: .legacy)
}

#Preview("Newspaper notes", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(
        date: .now,
        notes: TodayNotesProvider.previewNotes,
        theme: .newspaper,
        timelines: TodayNotesProvider.previewTimelines
    )
}
#endif
