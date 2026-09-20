import Foundation
import SwiftUI
#if os(iOS)
import WidgetKit
#endif

// MARK: - Model

/// The colours a timeline can wear. A fixed set rather than a free colour, so
/// the menu stays as muted as the rest of the app.
enum TimelineTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case rose
    case clay
    case amber
    case moss
    case sage
    case teal
    case iris
    case plum
    case slate
    case sand

    var id: String { rawValue }

    /// Kept as numbers rather than only a `Color`, so the widget can be sent
    /// the same colour without a second copy of the palette to drift from.
    var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .rose: (0.42, 0.23, 0.28)
        case .clay: (0.44, 0.28, 0.22)
        case .amber: (0.44, 0.39, 0.27)
        case .moss: (0.27, 0.38, 0.28)
        case .sage: (0.30, 0.40, 0.36)
        case .teal: (0.23, 0.37, 0.42)
        case .iris: (0.32, 0.31, 0.46)
        case .plum: (0.38, 0.26, 0.42)
        case .slate: (0.28, 0.30, 0.34)
        case .sand: (0.40, 0.36, 0.31)
        }
    }

    /// The fill behind the row.
    var fill: Color {
        Color(red: components.red, green: components.green, blue: components.blue)
    }
}

/// A category a note can belong to, as listed under TIMELINES on the menu.
/// It may sit on its own or inside one group — groups don't nest any further.
struct NoteTimeline: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var icon: String = "circle.fill"
    var tint: TimelineTint = .slate
    /// The group this timeline is filed under, if any.
    var groupID: UUID?

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

/// A folder of timelines. Deleting one frees its timelines rather than taking
/// them with it.
struct TimelineGroup: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// Drawn inside the folder, so a group still reads as its own thing.
    var icon: String = "folder"

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

// MARK: - Store

/// Holds every timeline and group, and persists them to disk.
///
/// Which notes belong to a timeline is kept on the notes themselves
/// (``Note/timelineID``), so a note carries its timeline wherever it moves.
@Observable
final class TimelineStore {
    private(set) var timelines: [NoteTimeline] = []
    private(set) var groups: [TimelineGroup] = []

    private let fileURL: URL?

    /// Pass `persistsToDisk: false` for previews and other throwaway stores.
    init(persistsToDisk: Bool = true) {
        fileURL = persistsToDisk ? Self.makeFileURL() : nil
        load()
        publishToWidget()
    }

    // MARK: Reading

    func timeline(_ id: UUID?) -> NoteTimeline? {
        guard let id else { return nil }
        return timelines.first { $0.id == id }
    }

    func group(_ id: UUID?) -> TimelineGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// The timelines filed under a group, in the order they were added.
    func timelines(in groupID: UUID) -> [NoteTimeline] {
        timelines.filter { $0.groupID == groupID }
    }

    /// The timelines that belong to no group.
    var ungroupedTimelines: [NoteTimeline] {
        timelines.filter { $0.groupID == nil }
    }

    /// Every timeline in a group, for gathering that group's notes.
    func timelineIDs(in groupID: UUID) -> Set<UUID> {
        Set(timelines(in: groupID).map(\.id))
    }

    var isEmpty: Bool { timelines.isEmpty && groups.isEmpty }

    // MARK: Writing

    /// Inserts a timeline, or replaces the one it shares an id with.
    func save(_ timeline: NoteTimeline) {
        // A group that has since been deleted would otherwise strand the row.
        var resolved = timeline
        if let groupID = resolved.groupID, group(groupID) == nil {
            resolved.groupID = nil
        }

        if let index = timelines.firstIndex(where: { $0.id == resolved.id }) {
            timelines[index] = resolved
        } else {
            timelines.append(resolved)
        }
        persist()
    }

    func save(_ group: TimelineGroup) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        persist()
    }

    func delete(timeline id: UUID) {
        timelines.removeAll { $0.id == id }
        persist()
    }

    /// Deleting a group leaves its timelines behind as ungrouped ones.
    func delete(group id: UUID) {
        groups.removeAll { $0.id == id }
        for index in timelines.indices where timelines[index].groupID == id {
            timelines[index].groupID = nil
        }
        persist()
    }

    /// Files a timeline under a group, or sets it loose again with `nil`.
    func move(timeline id: UUID, toGroup groupID: UUID?) {
        guard let index = timelines.firstIndex(where: { $0.id == id }),
              timelines[index].groupID != groupID
        else { return }

        timelines[index].groupID = groupID
        persist()
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var timelines: [NoteTimeline] = []
        var groups: [TimelineGroup] = []
    }

    private static func makeFileURL() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "WisprTimelines.json")
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            timelines = stored.timelines
            groups = stored.groups
        } catch {
            print("Wispr: could not read saved timelines — \(error)")
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            let stored = Stored(timelines: timelines, groups: groups)
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            print("Wispr: could not save timelines — \(error)")
        }
        publishToWidget()
    }

    // MARK: The widget's copy

    /// What the widget needs to draw a note's timeline: its name, its symbol
    /// and its colour, by id.
    private struct WidgetTimeline: Encodable {
        let name: String
        let icon: String
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Timelines travel to the widget in their own file rather than inside the
    /// notes snapshot, so renaming or recolouring one refreshes the widget
    /// without waiting for a note to change.
    private func publishToWidget() {
        #if os(iOS)
        // A throwaway store must not overwrite the real one's file.
        guard fileURL != nil,
              let container = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: TodayWidgetSnapshotPublisher.appGroup
              )
        else { return }

        let payload = timelines.reduce(into: [String: WidgetTimeline]()) { payload, timeline in
            let colour = timeline.tint.components
            payload[timeline.id.uuidString] = WidgetTimeline(
                name: timeline.displayName,
                icon: timeline.icon,
                red: colour.red,
                green: colour.green,
                blue: colour.blue
            )
        }

        do {
            try JSONEncoder().encode(payload)
                .write(to: container.appending(path: Self.widgetFilename), options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetSnapshotPublisher.widgetKind)
        } catch {
            print("Wispr: could not send the timelines to the widget — \(error)")
        }
        #endif
    }

    static let widgetFilename = "TodayWidgetTimelines.json"
}

#if DEBUG
extension TimelineStore {
    /// A store with a group and a few timelines, for previews.
    static func previewSeeded() -> TimelineStore {
        let store = TimelineStore(persistsToDisk: false)
        let trips = TimelineGroup(name: "Trips", icon: "airplane")
        store.save(trips)
        store.save(NoteTimeline(name: "Friends", icon: "person.2.fill", tint: .rose))
        store.save(NoteTimeline(name: "Programming", icon: "chevron.left.forwardslash.chevron.right", tint: .amber))
        store.save(NoteTimeline(name: "Japan", icon: "map.fill", tint: .iris, groupID: trips.id))
        store.save(NoteTimeline(name: "Lisbon", icon: "sun.max.fill", tint: .teal, groupID: trips.id))
        return store
    }
}
#endif
