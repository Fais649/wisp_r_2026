#if os(iOS)
import Foundation
import WidgetKit

/// The deliberately small, read-only data contract sent to the widget.
private struct TodayWidgetSnapshot: Encodable {
    let notesByDay: [String: [TodayWidgetNote]]
}

private struct TodayWidgetNote: Encodable {
    let id: UUID
    let blocks: [TodayWidgetBlock]
    let schedule: String?
    let imageCount: Int
    let voiceMemoCount: Int
}

/// One line of a note, sent whole rather than pre-drawn, so the widget can lay
/// a focused note out properly and cross its checklist items off.
private struct TodayWidgetBlock: Encodable {
    let id: UUID
    let text: String
    let kind: String
    let isChecked: Bool
    let number: Int?
    let indent: Int
}

enum TodayWidgetSnapshotPublisher {
    static let appGroup = "group.com.punksys.wispr"
    static let filename = "TodayWidgetSnapshot.json"
    static let widgetKind = "TodayNotesWidget"

    /// Rebuilds the widget's display-only view of every populated day.
    ///
    /// Keeping day buckets (instead of only the current day) means WidgetKit can
    /// roll over at midnight without waiting for the app to launch again.
    static func publish(_ notesByDay: [String: [Note]]) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { return }

        let displayNotes = expandedWidgetNotes(notesByDay)
        let snapshot = TodayWidgetSnapshot(notesByDay: displayNotes)
        let destination = container.appending(path: filename)

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: destination, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        } catch {
            print("Wispr: could not refresh the Today widget — \(error)")
        }
    }

    /// A multi-day event is stored on its first day, but the widget for each
    /// later day should still show it, with the range read from that first day.
    private static func expandedWidgetNotes(
        _ notesByDay: [String: [Note]]
    ) -> [String: [TodayWidgetNote]] {
        var display: [String: [TodayWidgetNote]] = [:]
        let calendar = Calendar.current

        for (key, notes) in notesByDay {
            guard let home = NoteStore.date(forKey: key) else { continue }
            let start = calendar.startOfDay(for: home)
            for note in notes {
                let widgetNote = makeWidgetNote(note, on: home)
                append(widgetNote, to: key, in: &display)
                guard let schedule = note.schedule, schedule.isEvent, schedule.endDayOffset > 0 else { continue }
                for offset in 1...schedule.endDayOffset {
                    guard let later = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
                    append(widgetNote, to: NoteStore.key(for: later), in: &display)
                }
            }
        }
        return display
    }

    private static func append(
        _ note: TodayWidgetNote,
        to key: String,
        in notes: inout [String: [TodayWidgetNote]]
    ) {
        if notes[key]?.contains(where: { $0.id == note.id }) == true { return }
        notes[key, default: []].append(note)
    }

    private static func makeWidgetNote(_ note: Note, on day: Date) -> TodayWidgetNote {
        let numbers = NoteMarkup.numbers(for: note.blocks)
        let blocks = note.blocks
            .filter { !$0.isBlank }
            .map { block in
                TodayWidgetBlock(
                    id: block.id,
                    text: String(block.text.characters),
                    kind: kindName(block.kind),
                    isChecked: block.isChecked,
                    number: numbers[block.id],
                    indent: max(0, block.indent)
                )
            }

        return TodayWidgetNote(
            id: note.id,
            blocks: blocks,
            schedule: note.schedule?.summary(on: day),
            imageCount: note.mediaAttachments.count,
            voiceMemoCount: note.voiceMemos.count
        )
    }

    private static func kindName(_ kind: NoteBlock.Kind) -> String {
        switch kind {
        case .paragraph: "paragraph"
        case .checklist: "checklist"
        case .bullet: "bullet"
        case .numbered: "numbered"
        }
    }
}

// MARK: - Taps made on the widget

/// A checklist item crossed off (or back on) from the widget, waiting for the
/// app to write it into the notes themselves.
///
/// The widget can only read the snapshot — the notes live in the app's own
/// container — so a tap out there is left here as an instruction, and the
/// widget draws the result until the app catches up.
struct TodayWidgetAction: Codable, Identifiable {
    let id: UUID
    let noteID: UUID
    let blockID: UUID
    /// The state the item should end up in, rather than "flip it", so applying
    /// the same instruction twice cannot undo itself.
    let isChecked: Bool
    let date: Date
}

enum TodayWidgetActionQueue {
    static let filename = "TodayWidgetActions.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: TodayWidgetSnapshotPublisher.appGroup)?
            .appending(path: filename)
    }

    static func pending() -> [TodayWidgetAction] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([TodayWidgetAction].self, from: data)) ?? []
    }

    /// Drops the instructions that have been carried out, leaving any that the
    /// widget added in the meantime.
    static func clear(_ applied: Set<UUID>) {
        guard let fileURL else { return }
        let remaining = pending().filter { !applied.contains($0.id) }

        do {
            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                try JSONEncoder().encode(remaining).write(to: fileURL, options: .atomic)
            }
        } catch {
            print("Wispr: could not clear the widget's pending taps — \(error)")
        }
    }
}
#endif
