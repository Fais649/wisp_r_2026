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

/// When a note happens: either a span of time on its day, making it a calendar
/// event, or a single time the note is due by.
///
/// Times are minutes from midnight rather than dates, so a note keeps its time
/// when it is moved to another day.
struct NoteSchedule: Equatable, Codable {
    /// The latest a note can be due: 9 PM.
    static let latestDueMinute = 21 * 60

    var startMinute: Int
    /// `nil` when the note is simply due by `startMinute` rather than filling a span.
    var endMinute: Int?

    var isEvent: Bool { endMinute != nil }

    // MARK: Times on a day

    func start(on day: Date) -> Date {
        Self.date(atMinute: startMinute, on: day)
    }

    func end(on day: Date) -> Date? {
        endMinute.map { Self.date(atMinute: $0, on: day) }
    }

    /// e.g. "9:30 – 10:30 AM", or "Due by 9:00 PM".
    func summary(on day: Date) -> String {
        let start = start(on: day)
        guard let end = end(on: day), end > start else {
            return "Due by \(start.formatted(date: .omitted, time: .shortened))"
        }

        return (start..<end).formatted(
            Date.IntervalFormatStyle(date: .omitted, time: .shortened)
        )
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
}

/// A single thing written down on a given day.
struct Note: Identifiable, Equatable {
    var id = UUID()
    var blocks: [NoteBlock] = []
    var attachments: [NoteAttachment] = []
    /// Set once the note has been given a time; `nil` for a plain note.
    var schedule: NoteSchedule?
    var createdAt = Date.now

    var mediaAttachments: [NoteAttachment] { attachments.filter(\.kind.isVisualMedia) }
    var documentAttachments: [NoteAttachment] { attachments.filter { $0.kind == .document } }
    var voiceMemos: [NoteAttachment] { attachments.filter { $0.kind == .audio } }

    /// The note with blank lines dropped, as it should be stored.
    var trimmed: Note {
        var copy = self
        copy.blocks = blocks.filter { !$0.isBlank }
        return copy
    }

    /// A note holding only attachments is still worth keeping.
    var isEmpty: Bool { blocks.allSatisfy(\.isBlank) && attachments.isEmpty }

    /// The note in one line, for the day previews and pickers that list notes
    /// without drawing them.
    var summaryLine: String {
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
    private enum CodingKeys: String, CodingKey { case id, blocks, attachments, schedule, createdAt }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        blocks = try container.decode([NoteBlock].self, forKey: .blocks)
        attachments = try container.decodeIfPresent([NoteAttachment].self, forKey: .attachments) ?? []
        schedule = try container.decodeIfPresent(NoteSchedule.self, forKey: .schedule)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(blocks, forKey: .blocks)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(schedule, forKey: .schedule)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

// MARK: - Store

/// Holds every note, keyed by the day it belongs to, and persists them to disk.
@Observable
final class NoteStore {
    private(set) var notesByDay: [String: [Note]] = [:]

    private let fileURL: URL?

    /// Pass `persistsToDisk: false` for previews and other throwaway stores.
    init(persistsToDisk: Bool = true) {
        fileURL = persistsToDisk ? Self.makeFileURL() : nil
        load()
        publishWidgetSnapshot()
    }

    // MARK: Reading

    func notes(on day: Date) -> [Note] {
        notesByDay[Self.key(for: day)] ?? []
    }

    // MARK: Writing

    /// Inserts the note, replaces it if it already exists, or removes it when empty.
    func save(_ note: Note, on day: Date) {
        let key = Self.key(for: day)
        var notes = notesByDay[key] ?? []
        let trimmed = note.trimmed

        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            if trimmed.isEmpty {
                discardFiles(of: [notes[index]])
                notes.remove(at: index)
            } else {
                notes[index] = trimmed
            }
        } else if !trimmed.isEmpty {
            notes.append(trimmed)
        }

        notesByDay[key] = notes
        persist()
    }

    /// Crosses a checklist item off (or back on) and sinks checked items to the
    /// bottom of their note.
    func toggleChecklistItem(_ blockID: UUID, inNote noteID: UUID, on day: Date) {
        let key = Self.key(for: day)
        guard var notes = notesByDay[key],
              let noteIndex = notes.firstIndex(where: { $0.id == noteID })
        else { return }

        var note = notes[noteIndex]
        guard let blockIndex = note.blocks.firstIndex(where: { $0.id == blockID }),
              note.blocks[blockIndex].isChecklistItem
        else { return }

        let isChecked = !note.blocks[blockIndex].isChecked
        note.blocks[blockIndex].kind = .checklist(isChecked: isChecked)
        // Stable partition: checked items move down, everything else keeps its order.
        note.blocks = note.blocks.filter { !$0.isChecked } + note.blocks.filter(\.isChecked)

        notes[noteIndex] = note
        notesByDay[key] = notes
        persist()
    }

    /// Gives a note a time, or takes it away again when passed `nil`.
    func setSchedule(_ schedule: NoteSchedule?, forNote noteID: UUID, on day: Date) {
        let key = Self.key(for: day)
        guard var notes = notesByDay[key],
              let index = notes.firstIndex(where: { $0.id == noteID })
        else { return }

        notes[index].schedule = schedule
        notesByDay[key] = notes
        persist()
    }

    /// Stores a transcript produced from the day view, so it isn't lost.
    func setTranscript(
        _ transcript: String,
        forAttachment attachmentID: UUID,
        inNote noteID: UUID,
        on day: Date
    ) {
        let key = Self.key(for: day)
        guard var notes = notesByDay[key],
              let noteIndex = notes.firstIndex(where: { $0.id == noteID }),
              let attachmentIndex = notes[noteIndex].attachments.firstIndex(where: { $0.id == attachmentID })
        else { return }

        notes[noteIndex].attachments[attachmentIndex].transcript = transcript
        notesByDay[key] = notes
        persist()
    }

    func delete(_ noteID: UUID, on day: Date) {
        delete([noteID], on: day)
    }

    func delete(_ noteIDs: Set<UUID>, on day: Date) {
        guard !noteIDs.isEmpty else { return }
        let key = Self.key(for: day)
        discardFiles(of: (notesByDay[key] ?? []).filter { noteIDs.contains($0.id) })
        notesByDay[key]?.removeAll { noteIDs.contains($0.id) }
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
    func move(_ noteIDs: Set<UUID>, from source: Date, to destination: Date) {
        let sourceKey = Self.key(for: source)
        let destinationKey = Self.key(for: destination)
        guard !noteIDs.isEmpty, sourceKey != destinationKey else { return }

        guard var sourceNotes = notesByDay[sourceKey] else { return }
        let moved = sourceNotes.filter { noteIDs.contains($0.id) }
        guard !moved.isEmpty else { return }

        sourceNotes.removeAll { noteIDs.contains($0.id) }
        notesByDay[sourceKey] = sourceNotes
        notesByDay[destinationKey, default: []].append(contentsOf: moved)
        persist()
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
        }
    }

    private func publishWidgetSnapshot() {
        #if os(iOS)
        guard fileURL != nil else { return }
        TodayWidgetSnapshotPublisher.publish(notesByDay)
        #endif
    }
}
