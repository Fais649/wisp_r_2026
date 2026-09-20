import SwiftUI
import Playgrounds

/// Everywhere the menu leads. Shared so a moment's timeline can push a day of
/// its own.
enum WisprScreen: Hashable {
    /// A day in the day view; `nil` means today.
    case day(Date?)
    case moment(Moment)
    /// One timeline's notes, by its id.
    case timeline(UUID)
    /// Every note on every timeline in a group.
    case timelineGroup(UUID)
    case settings
}

struct ContentView: View {
    /// Starts on the day view; the back button reveals the menu behind it.
    @State private var path: [WisprScreen] = [.day(nil)]

    /// Set when the widget's plus is tapped, so today opens straight into a
    /// blank note. A fresh value each time, so asking twice works twice.
    @State private var newNoteRequest: UUID?

    /// Set when a note is tapped in the widget and the app is what should open.
    @State private var openNoteRequest: UUID?

    @Environment(NoteStore.self) private var store
    @Environment(TimelineStore.self) private var timelines

    /// The sheet the timelines section has open, if any.
    @State private var isCreatingTimeline = false
    @State private var isCreatingGroup = false
    @State private var editingTimeline: NoteTimeline?
    @State private var editingGroup: TimelineGroup?

    var body: some View {
        NavigationStack(path: $path) {
            menu
                .navigationDestination(for: WisprScreen.self) { screen in
                    destination(for: screen)
                }
        }
        .preferredColorScheme(AppSettings.shared.theme.colorScheme)
        .sheet(isPresented: $isCreatingTimeline) {
            TimelineEditorSheet()
        }
        .sheet(isPresented: $isCreatingGroup) {
            TimelineGroupEditorSheet()
        }
        .sheet(item: $editingTimeline) { timeline in
            TimelineEditorSheet(editing: timeline)
        }
        .sheet(item: $editingGroup) { group in
            TimelineGroupEditorSheet(editing: group)
        }
        .onOpenURL { url in
            guard url.scheme == "wispr" else { return }

            switch url.host {
            case "today":
                path = [.day(nil)]

            case "new":
                path = [.day(nil)]
                newNoteRequest = UUID()

            // A note tapped in the widget: its own day, opened on it.
            case "note":
                guard let noteID = UUID(uuidString: url.lastPathComponent) else { break }
                path = [.day(store.storedDay(of: noteID))]
                openNoteRequest = noteID

            default:
                break
            }
        }
    }

    @ViewBuilder
    private func destination(for screen: WisprScreen) -> some View {
        switch screen {
        case .day(let day):
            DayView(
                initialDay: day,
                backTitle: backTitle(forDayAfter: screen),
                newNoteRequest: $newNoteRequest,
                openNoteRequest: $openNoteRequest
            )

        case .moment(let moment):
            MomentTimelineView(moment: moment)

        case .timeline(let id):
            if let timeline = timelines.timeline(id) {
                MomentTimelineView(feed: .timeline(timeline))
            }

        case .timelineGroup(let id):
            if let group = timelines.group(id) {
                MomentTimelineView(
                    feed: .group(group, timelineIDs: timelines.timelineIDs(in: id))
                )
            }

        case .settings:
            SettingsView()
        }
    }

    /// A day pushed from a moment's timeline goes back to that timeline, so the
    /// back button names it rather than the menu.
    private func backTitle(forDayAfter screen: WisprScreen) -> String {
        guard let index = path.firstIndex(of: screen), index > 0 else {
            return AppSettings.shared.displayTitle
        }

        switch path[index - 1] {
        case .moment(let moment): return moment.title
        case .timeline(let id): return timelines.timeline(id)?.displayName ?? AppSettings.shared.displayTitle
        case .timelineGroup(let id): return timelines.group(id)?.displayName ?? AppSettings.shared.displayTitle
        default: return AppSettings.shared.displayTitle
        }
    }

    private var menu: some View {
        ZStack {
            WisprBackground()

            // Scrolls: the timelines section grows with however many are made.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HeaderView()
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    // "Today" stands alone above the first section, and opens the day view.
                    NavigationLink(value: WisprScreen.day(nil)) {
                        MenuRow(title: "Today", icon: "diamond.fill", iconWeight: .regular)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 46)

                    SectionHeader(title: "MOMENTS")
                        .padding(.top, 45)

                    CardGroup {
                        momentRow(.notes)
                        RowDivider()
                        momentRow(.tasks)
                        RowDivider()
                        momentRow(.events)
                        RowDivider()
                        momentRow(.photos)
                        RowDivider()
                        momentRow(.memos)
                    }
                    .padding(.top, 14)

                    timelinesHeader
                        .padding(.top, 44)

                    timelinesSection
                        .padding(.top, 13)

                    NavigationLink(value: WisprScreen.settings) {
                        MenuRow(title: "Settings", icon: "gearshape.fill")
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 58)

                    Spacer(minLength: 0)
                }
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// A moments row, opening that moment's timeline.
    private func momentRow(_ moment: Moment) -> some View {
        NavigationLink(value: WisprScreen.moment(moment)) {
            MenuRow(title: moment.title, icon: moment.icon)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Timelines

    private var timelinesHeader: some View {
        HStack {
            Text("TIMELINES")
                .kerning(0.6)

            Spacer()

            Button {
                isCreatingGroup = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.wispr(15))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New group")

            Button {
                isCreatingTimeline = true
            } label: {
                Image(systemName: "plus")
                    .font(.wispr(15, weight: .semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .accessibilityLabel("New timeline")
        }
        .font(.wispr(12, weight: .medium))
        .foregroundStyle(Color.wisprSecondaryText)
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var timelinesSection: some View {
        VStack(spacing: 10) {
            ForEach(timelines.groups) { group in
                groupCard(group)
            }

            if !timelines.ungroupedTimelines.isEmpty {
                looseTimelines
            }

            if timelines.isEmpty {
                Text("No timelines yet")
                    .font(.wispr(15))
                    .foregroundStyle(Color.wisprSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .frame(height: 43)
                    .wisprCardBackground()
            }
        }
        .padding(.horizontal, 20)
    }

    /// A group and the timelines filed under it. Dropping a timeline anywhere
    /// on the card files it here.
    private func groupCard(_ group: TimelineGroup) -> some View {
        let members = timelines.timelines(in: group.id)

        return VStack(spacing: 0) {
            SwipeActionsRow(
                onEdit: { editingGroup = group },
                onDelete: { delete(group) }
            ) {
                NavigationLink(value: WisprScreen.timelineGroup(group.id)) {
                    TimelineGroupRow(group: group, count: members.count)
                }
                .buttonStyle(.plain)
            }

            ForEach(members) { timeline in
                RowDivider()
                timelineRow(timeline, isNested: true)
            }
        }
        .wisprCardBackground()
        .dropDestination(for: String.self) { items, _ in
            file(items, into: group.id)
        }
    }

    /// The timelines in no group. Dropping one here takes it out of whichever
    /// group it was in.
    private var looseTimelines: some View {
        VStack(spacing: 0) {
            ForEach(Array(timelines.ungroupedTimelines.enumerated()), id: \.element.id) { index, timeline in
                if index > 0 { RowDivider() }
                timelineRow(timeline, isNested: false)
            }
        }
        .wisprCardBackground()
        .dropDestination(for: String.self) { items, _ in
            file(items, into: nil)
        }
    }

    private func timelineRow(_ timeline: NoteTimeline, isNested: Bool) -> some View {
        SwipeActionsRow(
            onEdit: { editingTimeline = timeline },
            onDelete: { delete(timeline) }
        ) {
            NavigationLink(value: WisprScreen.timeline(timeline.id)) {
                TimelineRow(timeline: timeline, isNested: isNested)
            }
            .buttonStyle(.plain)
            .draggable(timeline.id.uuidString) {
                // What follows the finger: the row's mark alone.
                TimelineMark(timeline: timeline, size: 34)
            }
        }
    }

    /// Files dragged timelines under a group, or sets them loose with `nil`.
    private func file(_ items: [String], into groupID: UUID?) -> Bool {
        let moved = items.compactMap(UUID.init(uuidString:)).filter { timelines.timeline($0) != nil }
        guard !moved.isEmpty else { return false }

        withAnimation(.snappy) {
            for id in moved {
                timelines.move(timeline: id, toGroup: groupID)
            }
        }
        return true
    }

    private func delete(_ timeline: NoteTimeline) {
        withAnimation(.snappy) {
            timelines.delete(timeline: timeline.id)
        }
        // The notes stay; they simply belong to nothing again.
        store.clearTimeline(timeline.id)
    }

    /// A deleted group leaves its timelines behind, ungrouped.
    private func delete(_ group: TimelineGroup) {
        withAnimation(.snappy) {
            timelines.delete(group: group.id)
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    var body: some View {
        HStack(spacing: 14) {
            LogoMark()
                .frame(width: 22, height: 22)

            Text(AppSettings.shared.displayTitle)
                .font(.wispr(21, weight: .medium, role: .header))
                .foregroundStyle(Color.wisprInk)
        }
    }
}

/// The three-square mark used as the app's logo.
private struct LogoMark: View {
    var body: some View {
        GeometryReader { proxy in
            let cell = proxy.size.width * 0.42
            let gap = proxy.size.width - cell * 2

            ZStack(alignment: .topLeading) {
                square(size: cell)
                square(size: cell)
                    .offset(x: cell + gap)
                square(size: cell)
                    .offset(y: cell + gap)
            }
        }
    }

    private func square(size: CGFloat) -> some View {
        Rectangle()
            .fill(Color.wisprInk)
            .frame(width: size, height: size)
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .kerning(0.6)
            Spacer()
        }
        .font(.wispr(12, weight: .medium))
        .foregroundStyle(Color.wisprSecondaryText)
        .padding(.horizontal, 40)
    }
}

// MARK: - Rows

private struct CardGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .wisprCardBackground()
        .padding(.horizontal, 20)
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.wisprSeparator)
            .frame(height: 1)
            .padding(.leading, 20)
    }
}

private struct MenuRow: View {
    let title: String
    let icon: String
    var iconWeight: Font.Weight = .regular

    var body: some View {
        HStack {
            Text(title)
                .font(.wispr(18))
                .foregroundStyle(Color.wisprInk)
            Spacer()
            Image(systemName: icon)
                .font(.wispr(17, weight: iconWeight))
                .foregroundStyle(Color.wisprInk)
                // Decoration only; the title names the row. Left visible, some
                // symbols carry traits of their own — `checkmark.square` reads
                // as "selected" — which misdescribes the row as a button.
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .frame(height: 43)
        // The whole row is the target, not just the text and icon.
        .contentShape(Rectangle())
    }
}

private struct TimelineRow: View {
    let timeline: NoteTimeline
    /// A timeline inside a group is stepped in behind its folder.
    var isNested: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            TimelineMark(timeline: timeline, size: 24)

            Text(timeline.displayName)
                .font(.wispr(18))
                .foregroundStyle(Color.wisprOnAccent)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.wispr(16, weight: .semibold))
                .foregroundStyle(Color.wisprOnAccent.opacity(0.85))
        }
        .padding(.leading, isNested ? 34 : 20)
        .padding(.trailing, 20)
        .frame(height: 43)
        .background(timeline.tint.fill)
        .contentShape(Rectangle())
    }
}

private struct TimelineGroupRow: View {
    let group: TimelineGroup
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            TimelineGroupMark(icon: group.icon, size: 24)

            Text(group.displayName)
                .font(.wispr(18))
                .foregroundStyle(Color.wisprInk)

            Spacer()

            Text(count == 1 ? "1 timeline" : "\(count) timelines")
                .font(.wispr(13))
                .foregroundStyle(Color.wisprSecondaryText)

            Image(systemName: "chevron.right")
                .font(.wispr(16, weight: .semibold))
                .foregroundStyle(Color.wisprInk.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .frame(height: 43)
        .contentShape(Rectangle())
    }
}

// MARK: - Swiping

/// A row that answers to a swipe: to the left far enough deletes it, to the
/// right far enough edits it. Nothing stays open — the row springs back the
/// moment it is let go, and the action follows.
private struct SwipeActionsRow<Content: View>: View {
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: Content

    /// How far the row must travel for the action to take.
    private static var threshold: CGFloat { 68 }
    /// How far it can travel at all, so a long swipe doesn't leave the row adrift.
    private static var limit: CGFloat { 110 }

    @State private var offset: CGFloat = 0

    var body: some View {
        content
            .offset(x: offset)
            .background(alignment: .leading) {
                badge("pencil", tint: Color.wisprInk.opacity(0.16), isShowing: offset > 0)
            }
            .background(alignment: .trailing) {
                badge("trash", tint: Color.red.opacity(0.85), isShowing: offset < 0)
            }
            // Clipped to the row, so the badges stay behind it rather than
            // spilling over the cards above and below.
            .clipped()
            // Simultaneous, so a drag that starts on a row can still scroll
            // the menu; only a sideways one is taken as a swipe.
            .simultaneousGesture(swipe)
    }

    private func badge(_ symbol: String, tint: Color, isShowing: Bool) -> some View {
        ZStack {
            tint
            Image(systemName: symbol)
                .font(.wispr(16, weight: .semibold))
                .foregroundStyle(Color.wisprInk)
                .padding(.horizontal, 24)
                // Fills out as the row commits to the action.
                .scaleEffect(0.8 + 0.2 * min(abs(offset) / Self.threshold, 1))
        }
        .frame(width: max(abs(offset), 0))
        .opacity(isShowing ? 1 : 0)
        .accessibilityHidden(true)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                // Vertical drags belong to the scroll view; the row sits still.
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    offset = 0
                    return
                }
                offset = max(-Self.limit, min(Self.limit, value.translation.width))
            }
            .onEnded { value in
                let travelled = offset
                withAnimation(.snappy) { offset = 0 }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                if travelled <= -Self.threshold {
                    onDelete()
                } else if travelled >= Self.threshold {
                    onEdit()
                }
            }
    }
}

#if DEBUG
#Preview {
    AppSettings.preview()

    return ContentView()
        .environment(NoteStore(persistsToDisk: false))
        .environment(LocationHistory())
        .environment(TimelineStore.previewSeeded())
}

#Playground {
    _ = 1 + 2
}

#Preview("Legacy theme") {
    AppSettings.preview(theme: .legacy)

    return ContentView()
        .environment(NoteStore(persistsToDisk: false))
        .environment(LocationHistory())
        .environment(TimelineStore.previewSeeded())
}
#endif
