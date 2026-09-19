#if os(iOS)
import Foundation
import WidgetKit

/// The deliberately small, read-only data contract sent to the widget.
private struct TodayWidgetSnapshot: Encodable {
    let notesByDay: [String: [TodayWidgetNote]]
}

private struct TodayWidgetNote: Encodable {
    let id: UUID
    let text: String
    let schedule: String?
    let imageCount: Int
    let voiceMemoCount: Int
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

        let displayNotes = notesByDay.reduce(into: [String: [TodayWidgetNote]]()) { result, item in
            guard let day = NoteStore.date(forKey: item.key) else { return }
            result[item.key] = item.value.map { makeWidgetNote($0, on: day) }
        }
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

    private static func makeWidgetNote(_ note: Note, on day: Date) -> TodayWidgetNote {
        let text = note.blocks
            .filter { !$0.isBlank }
            .map(displayLine)
            .joined(separator: "\n")

        return TodayWidgetNote(
            id: note.id,
            text: text.isEmpty ? "Attachment" : text,
            schedule: note.schedule?.summary(on: day),
            imageCount: note.mediaAttachments.count,
            voiceMemoCount: note.voiceMemos.count
        )
    }

    private static func displayLine(_ block: NoteBlock) -> String {
        let text = String(block.text.characters)
        let prefix: String

        switch block.kind {
        case .paragraph:
            prefix = ""
        case .checklist(let isChecked):
            prefix = isChecked ? "✓  " : "○  "
        case .bullet:
            prefix = "•  "
        case .numbered:
            prefix = "–  "
        }

        return String(repeating: "  ", count: max(0, block.indent)) + prefix + text
    }
}
#endif
