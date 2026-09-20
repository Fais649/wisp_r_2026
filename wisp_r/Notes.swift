import CoreLocation
import Foundation
import SwiftUI

// MARK: - Model

/// One line of a note: a paragraph of rich text, or a checklist, bullet or
/// numbered list item, at some indent level.
struct NoteBlock: Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case paragraph
        case checklist(isChecked: Bool)
        case bullet
        case numbered
    }

    var id = UUID()
    var text = AttributedString()
    var kind: Kind = .paragraph
    var indent = 0

    var isChecked: Bool {
        if case .checklist(let isChecked) = kind { return isChecked }
        return false
    }

    var isChecklistItem: Bool {
        if case .checklist = kind { return true }
        return false
    }

    /// True when the line holds nothing but whitespace.
    var isBlank: Bool {
        String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// When a note happens: either a span of time, making it a calendar event, or a
/// single time the note is due by.
///
/// Times are minutes from midnight on the day the note is stored, so moving the
/// note keeps its time of day. An event may run past that day (`endDayOffset`)
/// and may fill whole days with no time of day (`isAllDay`).
struct NoteSchedule: Equatable, Codable {
    /// The latest a note can be due: 9 PM.
    static let latestDueMinute = 21 * 60

    var startMinute: Int
    /// `nil` when the note is simply due by `startMinute`, or when it is all day.
    var endMinute: Int?
    /// Midnights between the note's day and the day the event ends. Zero means
    /// it starts and ends on the same day.
    var endDayOffset: Int
    var isAllDay: Bool
    /// A human-readable place for calendar events. Due dates don't use it.
    var eventLocation: String?
    /// The resolved event destination used for its map annotation.
    var eventLatitude: Double?
    var eventLongitude: Double?

    var isEvent: Bool { isAllDay || endMinute != nil }

    init(
        startMinute: Int,
        endMinute: Int? = nil,
        endDayOffset: Int = 0,
        isAllDay: Bool = false,
        eventLocation: String? = nil,
        eventLatitude: Double? = nil,
        eventLongitude: Double? = nil
    ) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.endDayOffset = max(0, endDayOffset)
        self.isAllDay = isAllDay
        self.eventLocation = Self.normalizedLocation(eventLocation)
        self.eventLatitude = eventLatitude
        self.eventLongitude = eventLongitude
    }

    // MARK: Times on a day

    /// `day` is the day the note is stored on, which is the event's first day.
    func start(on day: Date) -> Date {
        if isAllDay { return Calendar.current.startOfDay(for: day) }
        return Self.date(atMinute: startMinute, on: day)
    }

    func end(on day: Date) -> Date? {
        guard isEvent, !isAllDay else { return nil }
        return editorEnd(on: day)
    }

    /// The end the schedule editor shows. For an all-day event this is the last
    /// day included, not the midnight after it that calendars store.
    func editorEnd(on day: Date) -> Date {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: day)
        let endDay = calendar.date(byAdding: .day, value: endDayOffset, to: startDay) ?? startDay
        if isAllDay { return endDay }
        return Self.date(atMinute: endMinute ?? startMinute, on: endDay)
    }

    /// True when this event, stored on `home`, is still going on `day`.
    func covers(_ day: Date, storedOn home: Date) -> Bool {
        guard isEvent else { return false }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: home)
        let target = calendar.startOfDay(for: day)
        guard target >= start,
              let last = calendar.date(byAdding: .day, value: endDayOffset, to: start)
        else { return false }
        return target <= last
    }

    /// e.g. "9:30 – 10:30 AM", "All day", or "Due by 9:00 PM".
    func summary(on day: Date) -> String {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: day)

        if isAllDay {
            if endDayOffset == 0 { return "All day" }
            let last = calendar.date(byAdding: .day, value: endDayOffset, to: startDay) ?? startDay
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: last) ?? last
            return (startDay..<endExclusive).formatted(
                Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
            )
        }

        let start = start(on: day)
        guard let end = end(on: day), end > start else {
            return "Due by \(start.formatted(date: .omitted, time: .shortened))"
        }

        return (start..<end).formatted(
            Date.IntervalFormatStyle(
                date: endDayOffset > 0 ? .abbreviated : .omitted,
                time: .shortened
            )
        )
    }

    /// The start and end to write into a calendar. All-day events end at
    /// midnight after the last day, in GMT, which is how EventKit stores them.
    func calendarInterval(storedOn day: Date) -> CalendarInterval? {
        guard isEvent else { return nil }
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: day)

        if isAllDay {
            let endDay = calendar.date(byAdding: .day, value: endDayOffset + 1, to: startDay) ?? startDay
            return CalendarInterval(
                start: Self.allDayBoundary(startDay),
                end: Self.allDayBoundary(endDay),
                isAllDay: true
            )
        }

        let start = Self.date(atMinute: startMinute, on: startDay)
        let endDay = calendar.date(byAdding: .day, value: endDayOffset, to: startDay) ?? startDay
        var end = Self.date(atMinute: endMinute ?? startMinute, on: endDay)
        if end <= start { end = start.addingTimeInterval(60) }
        return CalendarInterval(start: start, end: end, isAllDay: false)
    }

    struct CalendarInterval: Equatable {
        var start: Date
        var end: Date
        var isAllDay: Bool
    }

    // MARK: Converting

    static func date(atMinute minute: Int, on day: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(
            byAdding: .minute,
            value: minute,
            to: calendar.startOfDay(for: day)
        ) ?? day
    }

    /// The minutes from midnight a date falls on, whatever day it is.
    static func minute(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Midnight GMT of that calendar day. EventKit stores all-day events that way,
    /// so a local midnight would shift them a day in time zones west of Greenwich.
    static func allDayBoundary(_ day: Date) -> Date {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return gmt.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) ?? day
    }

    /// The local calendar day an EventKit all-day boundary falls on.
    static func localDay(fromAllDayBoundary date: Date) -> Date {
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = gmt.dateComponents([.year, .month, .day], from: date)
        return Calendar.current.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
            ?? Calendar.current.startOfDay(for: date)
    }

    // MARK: Codable

    // Written by hand so notes saved before all-day and multi-day events existed
    // still decode.
    private enum CodingKeys: String, CodingKey {
        case startMinute, endMinute, endDayOffset, isAllDay, eventLocation
        case eventLatitude, eventLongitude
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startMinute = try container.decode(Int.self, forKey: .startMinute)
        endMinute = try container.decodeIfPresent(Int.self, forKey: .endMinute)
        endDayOffset = try container.decodeIfPresent(Int.self, forKey: .endDayOffset) ?? 0
        isAllDay = try container.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        eventLocation = Self.normalizedLocation(
            try container.decodeIfPresent(String.self, forKey: .eventLocation)
        )
        eventLatitude = try container.decodeIfPresent(Double.self, forKey: .eventLatitude)
        eventLongitude = try container.decodeIfPresent(Double.self, forKey: .eventLongitude)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startMinute, forKey: .startMinute)
        try container.encodeIfPresent(endMinute, forKey: .endMinute)
        if endDayOffset != 0 { try container.encode(endDayOffset, forKey: .endDayOffset) }
        if isAllDay { try container.encode(isAllDay, forKey: .isAllDay) }
        try container.encodeIfPresent(eventLocation, forKey: .eventLocation)
        try container.encodeIfPresent(eventLatitude, forKey: .eventLatitude)
        try container.encodeIfPresent(eventLongitude, forKey: .eventLongitude)
    }

    private static func normalizedLocation(_ location: String?) -> String? {
        let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The coordinate captured when a note is first written.
struct NoteLocation: Equatable, Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let capturedAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A single thing written down on a given day.
struct Note: Identifiable, Equatable {
    var id = UUID()
    /// A concise heading, generated on-device when the person leaves it blank.
    var title: String?
    var blocks: [NoteBlock] = []
    var attachments: [NoteAttachment] = []
    var location: NoteLocation?
    /// An SF Symbol selected on-device to represent this note on its day map.
    var mapSymbol: String?
    /// The timeline this note is filed under, if any. Kept on the note so it
    /// travels with it between days.
    var timelineID: UUID?
    /// Set once the note has been given a time; `nil` for a plain note.
    var schedule: NoteSchedule?
    /// The calendar event this note mirrors, when it is synced.
    var calendarEventID: String?
    /// Start of one occurrence, so instances of a repeating event stay distinct.
    var calendarOccurrence: Date?
    /// The calendar's last modified date once both sides match. `nil` means
    /// local edits still need pushing, and a refresh must not overwrite them.
    var calendarRevision: Date?
    var createdAt = Date.now

    var mediaAttachments: [NoteAttachment] { attachments.filter(\.kind.isVisualMedia) }
    var documentAttachments: [NoteAttachment] { attachments.filter { $0.kind == .document } }
    var voiceMemos: [NoteAttachment] { attachments.filter { $0.kind == .audio } }

    /// Planned event coordinates take precedence over where the note was written.
    var mapLocation: NoteLocation? {
        if let schedule, schedule.isEvent {
            if let latitude = schedule.eventLatitude,
               let longitude = schedule.eventLongitude {
                return NoteLocation(latitude: latitude, longitude: longitude, capturedAt: createdAt)
            }
            // Don't imply an unresolved named destination is where the note was written.
            if schedule.eventLocation != nil { return nil }
        }
        return location
    }

    /// The note with blank lines dropped, as it should be stored.
    var trimmed: Note {
        var copy = self
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        copy.title = trimmedTitle.isEmpty ? nil : trimmedTitle
        copy.blocks = blocks.filter { !$0.isBlank }
        return copy
    }

    /// A titled note or a note holding only attachments is still worth keeping.
    var isEmpty: Bool {
        let hasTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return !hasTitle && blocks.allSatisfy(\.isBlank) && attachments.isEmpty
    }

    /// The note in one line, for the day previews and pickers that list notes
    /// without drawing them.
    var summaryLine: String {
        if let title, !title.isEmpty { return title }
        if let written = blocks.first(where: { !$0.isBlank }) {
            return String(written.text.characters)
        }

        let pictures = mediaAttachments.count
        if pictures > 0 { return pictures == 1 ? "1 picture" : "\(pictures) pictures" }
        if !voiceMemos.isEmpty { return "Voice memo" }
        if let document = documentAttachments.first { return document.displayName }
        return "Empty note"
    }

    /// The symbol that stands for what the note mostly is.
    var previewSymbol: String {
        if schedule?.isEvent == true { return "calendar" }
        if schedule != nil { return "clock" }
        if !mediaAttachments.isEmpty { return "photo" }
        if !voiceMemos.isEmpty { return "waveform" }
        if !documentAttachments.isEmpty { return "doc.text" }
        if blocks.contains(where: \.isChecklistItem) { return "checklist" }
        return "text.alignleft"
    }

    /// The plain title a calendar event should carry: the first written line.
    var calendarTitle: String {
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let written = blocks.first(where: { !$0.isBlank }) {
            let line = String(written.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { return line }
        }
        return "New Event"
    }

    /// Replaces the first written line with a calendar title. A calendar title
    /// is plain text, so a rename made in the calendar app drops that line's formatting.
    mutating func setCalendarTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "New Event" : trimmed
        guard resolved != calendarTitle else { return }
        self.title = resolved
    }

    /// Plain content supplied to the on-device model. The stored title is left
    /// out so generation is based on what the note says, not its old heading.
    var titleGenerationContent: String {
        var parts = blocks.compactMap { block -> String? in
            let text = String(block.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let location = schedule?.eventLocation { parts.append("Location: \(location)") }
        parts.append(contentsOf: attachments.map(\.displayName))
        return parts.joined(separator: "\n")
    }
}

/// A note together with the day it lives on, for the sheets that need both.
struct NoteOnDay: Identifiable {
    let note: Note
    let day: Date

    var id: UUID { note.id }
}

// MARK: - Codable

// `AttributedString` needs an explicit attribute scope to encode its SwiftUI
// attributes (fonts, colors, underlines), so the conformance is written by hand.
extension NoteBlock: Codable {
    private enum CodingKeys: String, CodingKey { case id, text, kind, indent }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(
            AttributedString.self,
            forKey: .text,
            configuration: AttributeScopes.SwiftUIAttributes.decodingConfiguration
        )
        kind = try container.decode(Kind.self, forKey: .kind)
        indent = try container.decodeIfPresent(Int.self, forKey: .indent) ?? 0
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(
            text,
            forKey: .text,
            configuration: AttributeScopes.SwiftUIAttributes.encodingConfiguration
        )
        try container.encode(kind, forKey: .kind)
        try container.encode(indent, forKey: .indent)
    }
}

// Written by hand so that notes saved before attachments and schedules existed
// still decode.
extension Note: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, blocks, attachments, location, mapSymbol, schedule, createdAt
        case calendarEventID, calendarOccurrence, calendarRevision, timelineID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        blocks = try container.decode([NoteBlock].self, forKey: .blocks)
        attachments = try container.decodeIfPresent([NoteAttachment].self, forKey: .attachments) ?? []
        location = try container.decodeIfPresent(NoteLocation.self, forKey: .location)
        mapSymbol = try container.decodeIfPresent(String.self, forKey: .mapSymbol)
        timelineID = try container.decodeIfPresent(UUID.self, forKey: .timelineID)
        schedule = try container.decodeIfPresent(NoteSchedule.self, forKey: .schedule)
        calendarEventID = try container.decodeIfPresent(String.self, forKey: .calendarEventID)
        calendarOccurrence = try container.decodeIfPresent(Date.self, forKey: .calendarOccurrence)
        calendarRevision = try container.decodeIfPresent(Date.self, forKey: .calendarRevision)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(blocks, forKey: .blocks)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(mapSymbol, forKey: .mapSymbol)
        try container.encodeIfPresent(timelineID, forKey: .timelineID)
        try container.encodeIfPresent(schedule, forKey: .schedule)
        try container.encodeIfPresent(calendarEventID, forKey: .calendarEventID)
        try container.encodeIfPresent(calendarOccurrence, forKey: .calendarOccurrence)
        try container.encodeIfPresent(calendarRevision, forKey: .calendarRevision)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

// MARK: - Store

/// Holds every note, keyed by the day it belongs to, and persists them to disk.
@Observable
final class NoteStore {
    private(set) var notesByDay: [String: [Note]] = [:]

    private let fileURL: URL?
    private let calendarSync = CalendarSync()
    @ObservationIgnored private var symbolAssignments: Set<UUID> = []
    @ObservationIgnored private var titleAssignments: Set<UUID> = []
    /// Set while applying a calendar refresh, so it isn't pushed straight back.
    private var isApplyingCalendar = false

    /// Pass `persistsToDisk: false` for previews and other throwaway stores.
    init(persistsToDisk: Bool = true) {
        fileURL = persistsToDisk ? Self.makeFileURL() : nil
        load()
        applyPendingWidgetActions()
        publishWidgetSnapshot()
        if fileURL != nil {
            calendarSync.start(with: self)
        }
    }

    /// Reads the default calendar again. Called when the app becomes active.
    func syncCalendar() {
        calendarSync.notesDidChange()
    }

    // MARK: Reading

    /// Notes stored on `day`, with events that started earlier and still cover it
    /// leading the list.
    func notes(on day: Date) -> [Note] {
        let key = Self.key(for: day)
        let own = notesByDay[key] ?? []
        let ownIDs = Set(own.map(\.id))
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: day)
        var carried: [Note] = []

        for (otherKey, notes) in notesByDay {
            guard otherKey != key, let home = Self.date(forKey: otherKey) else { continue }
            for note in notes where !ownIDs.contains(note.id) {
                guard let schedule = note.schedule, schedule.covers(target, storedOn: home) else { continue }
                carried.append(note)
            }
        }

        carried.sort { lhs, rhs in
            let leftAllDay = lhs.schedule?.isAllDay == true
            let rightAllDay = rhs.schedule?.isAllDay == true
            if leftAllDay != rightAllDay { return leftAllDay }
            return (lhs.schedule?.startMinute ?? 0) < (rhs.schedule?.startMinute ?? 0)
        }
        return carried + own
    }

    /// Every day that has a note, including the later days of a multi-day event.
    func daysHoldingNotes() -> [Date] {
        var days = Set<Date>()
        let calendar = Calendar.current

        for (key, notes) in notesByDay {
            guard let home = Self.date(forKey: key) else { continue }
            let start = calendar.startOfDay(for: home)
            days.insert(start)
            for note in notes {
                guard let schedule = note.schedule, schedule.isEvent, schedule.endDayOffset > 0 else { continue }
                for offset in 1...schedule.endDayOffset {
                    if let later = calendar.date(byAdding: .day, value: offset, to: start) {
                        days.insert(calendar.startOfDay(for: later))
                    }
                }
            }
        }
        return days.sorted()
    }

    /// The day a note is stored on. A multi-day event lives on its first day,
    /// even when it is shown on the days that follow.
    func storedDay(of noteID: UUID) -> Date? {
        guard let key = locate(noteID)?.key else { return nil }
        return Self.date(forKey: key)
    }

    /// Lazily backfills symbols for existing notes and repairs duplicates that
    /// can arise when a note moves to a different day.
    func ensureMapSymbols(on day: Date) {
        var used = Set<String>()
        for note in notes(on: day) {
            if let symbol = note.mapSymbol, !used.contains(symbol) {
                used.insert(symbol)
                continue
            }
            guard symbolAssignments.insert(note.id).inserted else { continue }
            Task { [weak self] in
                await self?.assignMapSymbol(to: note.id, visibleOn: day)
            }
        }
    }

    /// Lazily gives existing untitled notes a heading without blocking the day
    /// view. A deterministic fallback is used when the local model is unavailable.
    func ensureGeneratedTitles(on day: Date) {
        for note in notes(on: day) where note.title == nil {
            guard titleAssignments.insert(note.id).inserted else { continue }
            Task { [weak self] in
                await self?.assignGeneratedTitle(to: note.id)
            }
        }
    }

    // MARK: Writing

    /// Inserts the note, replaces it wherever it already lives, or removes it when empty.
    func save(_ note: Note, on day: Date) {
        var trimmed = note.trimmed
        if !isApplyingCalendar {
            trimmed.calendarRevision = nil
        }

        if trimmed.isEmpty {
            delete([trimmed.id], on: day)
            return
        }

        if let located = locate(trimmed.id) {
            if notesByDay[located.key]?[located.index].summaryLine != trimmed.summaryLine {
                trimmed.mapSymbol = nil
            }
            notesByDay[located.key]?[located.index] = trimmed
        } else {
            notesByDay[Self.key(for: day), default: []].append(trimmed)
        }
        persist()
        ensureMapSymbols(on: day)
        ensureGeneratedTitles(on: day)
    }

    private func assignGeneratedTitle(to noteID: UUID) async {
        defer { titleAssignments.remove(noteID) }
        guard let located = locate(noteID),
              let note = notesByDay[located.key]?[located.index],
              note.title == nil
        else { return }

        let title = await NoteTitleAssigner.shared.title(
            for: note.titleGenerationContent,
            fallback: note.summaryLine
        )
        guard let latest = locate(noteID), notesByDay[latest.key]?[latest.index].title == nil else { return }
        notesByDay[latest.key]?[latest.index].title = title
        persist()
    }

    private func assignMapSymbol(to noteID: UUID, visibleOn day: Date) async {
        defer { symbolAssignments.remove(noteID) }
        guard let note = notes(on: day).first(where: { $0.id == noteID }) else { return }

        let used = Set(notes(on: day).compactMap { candidate in
            candidate.id == noteID ? nil : candidate.mapSymbol
        })
        let symbol = await NoteSymbolAssigner.shared.symbol(
            for: note.summaryLine,
            noteID: note.id,
            excluding: used
        )

        guard let located = locate(noteID) else { return }
        notesByDay[located.key]?[located.index].mapSymbol = symbol
        persist()
    }

    /// Persists the order produced by SwiftUI's native List reordering. Events
    /// carried over from another day remain anchored ahead of the notes that are
    /// actually stored on this day and can't themselves be moved here.
    func reorderNotes(on day: Date, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let key = Self.key(for: day)
        guard let storedNotes = notesByDay[key], !storedNotes.isEmpty else { return }

        let storedIDs = Set(storedNotes.map(\.id))
        var visibleNotes = notes(on: day)
        let movedIDs = offsets.compactMap { index in
            visibleNotes.indices.contains(index) ? visibleNotes[index].id : nil
        }
        guard !movedIDs.isEmpty, movedIDs.allSatisfy(storedIDs.contains) else { return }

        visibleNotes.move(fromOffsets: offsets, toOffset: destination)
        let reordered = visibleNotes.filter { storedIDs.contains($0.id) }
        guard reordered.count == storedNotes.count else { return }

        notesByDay[key] = reordered
        persist()
    }

    /// Crosses a checklist item off (or back on) and sinks checked items to the
    /// bottom of their note.
    func toggleChecklistItem(_ blockID: UUID, inNote noteID: UUID, on day: Date) {
        guard let located = locate(noteID, preferring: day),
              let block = notesByDay[located.key]?[located.index].blocks.first(where: { $0.id == blockID })
        else { return }

        guard setChecklistItem(blockID, inNote: noteID, checked: !block.isChecked, on: day) else { return }
        persist()
    }

    /// Puts a checklist item into a given state, whatever it was in before.
    /// Returns whether anything changed; the caller persists, so a batch of
    /// these is written once.
    @discardableResult
    private func setChecklistItem(
        _ blockID: UUID,
        inNote noteID: UUID,
        checked isChecked: Bool,
        on day: Date?
    ) -> Bool {
        guard let located = locate(noteID, preferring: day),
              var note = notesByDay[located.key]?[located.index],
              let blockIndex = note.blocks.firstIndex(where: { $0.id == blockID }),
              note.blocks[blockIndex].isChecklistItem,
              note.blocks[blockIndex].isChecked != isChecked
        else { return false }

        note.blocks[blockIndex].kind = .checklist(isChecked: isChecked)
        // Stable partition: checked items move down, everything else keeps its order.
        note.blocks = note.blocks.filter { !$0.isChecked } + note.blocks.filter(\.isChecked)
        if !isApplyingCalendar { note.calendarRevision = nil }

        notesByDay[located.key]?[located.index] = note
        return true
    }

    /// Writes in the checklist items crossed off from the widget while the app
    /// wasn't running. Called on launch and whenever the app becomes active.
    func applyPendingWidgetActions() {
        #if os(iOS)
        // A throwaway store (previews, tests) must not swallow real taps.
        guard fileURL != nil else { return }

        let actions = TodayWidgetActionQueue.pending()
        guard !actions.isEmpty else { return }

        var changed = false
        for action in actions {
            let didChange = setChecklistItem(
                action.blockID,
                inNote: action.noteID,
                checked: action.isChecked,
                on: nil
            )
            changed = changed || didChange
        }

        TodayWidgetActionQueue.clear(Set(actions.map(\.id)))
        // Even with nothing to change, the widget is drawing its own copy of
        // these taps and needs a snapshot without them.
        if changed {
            persist()
        } else {
            publishWidgetSnapshot()
        }
        #endif
    }

    /// Gives a note a time, or takes it away again when passed `nil`.
    func setSchedule(_ schedule: NoteSchedule?, forNote noteID: UUID, on day: Date) {
        guard let located = locate(noteID, preferring: day) else { return }
        notesByDay[located.key]?[located.index].schedule = schedule
        if !isApplyingCalendar {
            notesByDay[located.key]?[located.index].calendarRevision = nil
        }
        persist()
    }

    /// Files a note under a timeline, or takes it out of one with `nil`.
    func setTimeline(_ timelineID: UUID?, forNote noteID: UUID, on day: Date) {
        guard let located = locate(noteID, preferring: day),
              notesByDay[located.key]?[located.index].timelineID != timelineID
        else { return }

        notesByDay[located.key]?[located.index].timelineID = timelineID
        persist()
    }

    /// Unfiles every note left behind by a deleted timeline.
    func clearTimeline(_ timelineID: UUID) {
        var changed = false
        for (key, notes) in notesByDay {
            for (index, note) in notes.enumerated() where note.timelineID == timelineID {
                notesByDay[key]?[index].timelineID = nil
                changed = true
            }
        }
        guard changed else { return }
        persist()
    }

    /// Stores a transcript produced from the day view, so it isn't lost.
    func setTranscript(
        _ transcript: String,
        forAttachment attachmentID: UUID,
        inNote noteID: UUID,
        on day: Date
    ) {
        guard let located = locate(noteID, preferring: day),
              var note = notesByDay[located.key]?[located.index],
              let attachmentIndex = note.attachments.firstIndex(where: { $0.id == attachmentID })
        else { return }

        note.attachments[attachmentIndex].transcript = transcript
        if !isApplyingCalendar { note.calendarRevision = nil }
        notesByDay[located.key]?[located.index] = note
        persist()
    }

    func delete(_ noteID: UUID, on day: Date) {
        delete([noteID], on: day)
    }

    func delete(_ noteIDs: Set<UUID>, on day: Date) {
        guard !noteIDs.isEmpty else { return }
        var removed: [Note] = []
        let preferred = Self.key(for: day)
        let keys = [preferred] + notesByDay.keys.filter { $0 != preferred }

        for key in keys {
            guard var notes = notesByDay[key] else { continue }
            let going = notes.filter { noteIDs.contains($0.id) }
            guard !going.isEmpty else { continue }
            removed.append(contentsOf: going)
            notes.removeAll { noteIDs.contains($0.id) }
            notesByDay[key] = notes
        }

        guard !removed.isEmpty else { return }
        discardFiles(of: removed)
        if !isApplyingCalendar {
            calendarSync.remove(removed)
        }
        persist()
    }

    /// Deleting a note takes its attachment files with it.
    private func discardFiles(of notes: [Note]) {
        let attachments = notes.flatMap(\.attachments)
        guard !attachments.isEmpty else { return }
        AttachmentThumbnails.shared.forget(attachments)
        AttachmentStore.delete(attachments)
    }

    /// Moves notes to another day, keeping their order at the end of that day.
    /// A multi-day event is stored on its first day, so the note is found wherever
    /// it lives rather than only on `source`.
    func move(_ noteIDs: Set<UUID>, from source: Date, to destination: Date) {
        let destinationKey = Self.key(for: destination)
        guard !noteIDs.isEmpty else { return }

        var moved: [Note] = []
        let preferred = Self.key(for: source)
        let keys = [preferred] + notesByDay.keys.filter { $0 != preferred }

        for key in keys where key != destinationKey {
            guard var notes = notesByDay[key] else { continue }
            let leaving = notes.filter { noteIDs.contains($0.id) }
            guard !leaving.isEmpty else { continue }
            notes.removeAll { noteIDs.contains($0.id) }
            notesByDay[key] = notes
            moved.append(contentsOf: leaving)
        }

        guard !moved.isEmpty else { return }
        if !isApplyingCalendar {
            for index in moved.indices {
                moved[index].calendarRevision = nil
            }
        }
        notesByDay[destinationKey, default: []].append(contentsOf: moved)
        persist()
    }

    // MARK: Calendar refresh

    /// Inserts or updates a note brought in from the calendar, without pushing
    /// that change straight back out.
    func applyCalendarNote(_ note: Note, on day: Date) {
        isApplyingCalendar = true
        defer { isApplyingCalendar = false }

        save(note, on: day)
        guard let stored = storedDay(of: note.id),
              !Calendar.current.isDate(stored, inSameDayAs: day)
        else { return }
        move([note.id], from: stored, to: day)
    }

    /// Drops a note whose calendar event was deleted, without trying to delete
    /// that event again.
    func removeCalendarNote(_ noteID: UUID, on day: Date) {
        isApplyingCalendar = true
        defer { isApplyingCalendar = false }
        delete([noteID], on: day)
    }

    /// Records the calendar item a note now mirrors, but only if the note wasn't
    /// edited again while the write was in flight.
    func stampCalendarLink(
        id: String?,
        occurrence: Date?,
        revision: Date?,
        for noteID: UUID,
        title: String,
        schedule: NoteSchedule?
    ) -> Bool {
        guard let located = locate(noteID),
              var note = notesByDay[located.key]?[located.index],
              note.calendarTitle == title,
              note.schedule == schedule
        else { return false }

        note.calendarEventID = id
        note.calendarOccurrence = occurrence
        note.calendarRevision = revision

        isApplyingCalendar = true
        notesByDay[located.key]?[located.index] = note
        persist()
        isApplyingCalendar = false
        return true
    }

    /// Remembers which calendar event a note belongs to when the note was edited
    /// again before the link could be stamped. The revision stays clear so the
    /// newer text is pushed next.
    func attachCalendarEvent(id: String, occurrence: Date?, for noteID: UUID) {
        guard let located = locate(noteID),
              notesByDay[located.key]?[located.index].calendarEventID == nil
        else { return }
        isApplyingCalendar = true
        notesByDay[located.key]?[located.index].calendarEventID = id
        notesByDay[located.key]?[located.index].calendarOccurrence = occurrence
        persist()
        isApplyingCalendar = false
    }

    /// Where a note is stored. `day` is checked first because that is usually it;
    /// a multi-day event shown on a later day is found on its first day instead.
    private func locate(_ noteID: UUID, preferring day: Date? = nil) -> (key: String, index: Int)? {
        if let day {
            let key = Self.key(for: day)
            if let index = notesByDay[key]?.firstIndex(where: { $0.id == noteID }) {
                return (key, index)
            }
        }
        for (key, notes) in notesByDay {
            if let index = notes.firstIndex(where: { $0.id == noteID }) {
                return (key, index)
            }
        }
        return nil
    }

    // MARK: Day keys

    /// A calendar-day key such as `2026-09-16`.
    static func key(for day: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The start of the calendar day a stored key refers to, for walking the
    /// notes back out in date order.
    static func date(forKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        )
    }

    // MARK: Persistence

    private static func makeFileURL() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "WisprNotes.json")
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            notesByDay = try JSONDecoder().decode([String: [Note]].self, from: data)
        } catch {
            print("Wispr: could not read saved notes — \(error)")
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try JSONEncoder().encode(notesByDay).write(to: fileURL, options: .atomic)
            publishWidgetSnapshot()
        } catch {
            print("Wispr: could not save notes — \(error)")
            return
        }
        if !isApplyingCalendar {
            calendarSync.notesDidChange()
        }
    }

    private func publishWidgetSnapshot() {
        #if os(iOS)
        guard fileURL != nil else { return }
        TodayWidgetSnapshotPublisher.publish(notesByDay)
        #endif
    }
}
