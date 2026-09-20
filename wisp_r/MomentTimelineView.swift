import SwiftUI

// MARK: - Moments

/// One kind of thing a note can hold, as listed under MOMENTS on the menu.
/// Each has a timeline of every note that holds it.
enum Moment: String, Hashable, CaseIterable, Identifiable {
    case notes
    case tasks
    case events
    case photos
    case memos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "Notes"
        case .tasks: "Tasks"
        case .events: "Events"
        case .photos: "Photos"
        case .memos: "Memos"
        }
    }

    var icon: String {
        switch self {
        case .notes: "text.alignleft"
        case .tasks: "checkmark.square"
        case .events: "calendar"
        case .photos: "photo.fill"
        case .memos: "mic.fill"
        }
    }

    /// True when the note belongs on this moment's timeline.
    func matches(_ note: Note) -> Bool {
        switch self {
        // Written text, as opposed to a note that is nothing but a task list.
        case .notes: note.blocks.contains { !$0.isChecklistItem && !$0.isBlank }
        case .tasks: note.blocks.contains(where: \.isChecklistItem)
        // Both kinds of time: a span, and a note simply due by one.
        case .events: note.schedule != nil
        // Videos come along with the photos; they share a note's mosaic.
        case .photos: !note.mediaAttachments.isEmpty
        case .memos: !note.voiceMemos.isEmpty
        }
    }

    /// Events read best in time order; everything else keeps the order it was
    /// written in.
    func ordered(_ notes: [Note]) -> [Note] {
        guard self == .events else { return notes }
        return notes.sorted { lhs, rhs in
            let leftAllDay = lhs.schedule?.isAllDay == true
            let rightAllDay = rhs.schedule?.isAllDay == true
            if leftAllDay != rightAllDay { return leftAllDay }
            return (lhs.schedule?.startMinute ?? 0) < (rhs.schedule?.startMinute ?? 0)
        }
    }
}

// MARK: - Feeds

/// What a timeline screen is showing: a kind of moment, a timeline, or a group
/// of timelines. Each answers the same two questions — which notes belong, and
/// in what order — so one view can draw them all.
struct NoteFeed {
    let title: String
    let icon: String
    /// Shown on a day with nothing in it, e.g. "No notes today".
    let emptyLabel: String
    let matches: (Note) -> Bool
    var ordered: ([Note]) -> [Note] = { $0 }
    /// A timeline's colour, carried into the screen's heading.
    var tint: Color?

    static func moment(_ moment: Moment) -> NoteFeed {
        NoteFeed(
            title: moment.title,
            icon: moment.icon,
            emptyLabel: "No \(moment.title.lowercased()) today",
            matches: moment.matches,
            ordered: moment.ordered
        )
    }

    static func timeline(_ timeline: NoteTimeline) -> NoteFeed {
        NoteFeed(
            title: timeline.displayName,
            icon: timeline.icon,
            emptyLabel: "Nothing on this timeline today",
            matches: { $0.timelineID == timeline.id },
            tint: timeline.tint.fill
        )
    }

    /// Every note on every timeline filed under the group.
    static func group(_ group: TimelineGroup, timelineIDs: Set<UUID>) -> NoteFeed {
        NoteFeed(
            title: group.displayName,
            icon: group.icon,
            emptyLabel: "Nothing in this group today",
            matches: { note in
                guard let id = note.timelineID else { return false }
                return timelineIDs.contains(id)
            }
        )
    }
}

// MARK: - Timeline

/// Every note in a feed, in one vertical scroll: the past above, the future
/// below, opening on today.
///
/// Each day is introduced by its relative and actual date, which double as the
/// separators between notes; tapping one opens that day in the day view.
struct MomentTimelineView: View {
    let feed: NoteFeed

    init(feed: NoteFeed) {
        self.feed = feed
    }

    init(moment: Moment) {
        self.init(feed: .moment(moment))
    }

    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let today = Calendar.current.startOfDay(for: .now)

    /// Set up front so the timeline is already sitting on today when it appears.
    @State private var position = ScrollPosition(id: NoteStore.key(for: .now), anchor: .top)
    @State private var editRequest: NoteOnDay?
    @State private var previewRequest: AttachmentPreviewRequest?
    @State private var expandedTranscripts: Set<UUID> = []
    @State private var transcribingIDs: Set<UUID> = []
    @State private var transcriptionErrors: [UUID: String] = [:]

    private struct DaySection: Identifiable {
        let day: Date
        let notes: [Note]

        var id: String { NoteStore.key(for: day) }
    }

    /// The days holding matching notes, oldest first. Today is always among
    /// them, so there is something to open on and a mark between past and future.
    private var sections: [DaySection] {
        var notesByDay: [Date: [Note]] = [today: []]
        var days = Set(store.daysHoldingNotes())
        days.insert(today)

        for day in days {
            let matching = store.notes(on: day).filter(feed.matches)
            if matching.isEmpty, !Calendar.current.isDate(day, inSameDayAs: today) { continue }
            notesByDay[Calendar.current.startOfDay(for: day)] = feed.ordered(matching)
        }

        return notesByDay
            .map { DaySection(day: $0.key, notes: $0.value) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        ZStack {
            WisprBackground()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                timeline
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editRequest) { request in
            NavigationStack {
                NoteEditorSheet(
                    note: request.note,
                    day: request.day,
                    onCommit: { edited in store.save(edited, on: request.day) },
                    onMove: { destination in
                        withAnimation(.snappy) {
                            store.move([request.note.id], from: request.day, to: destination)
                        }
                    }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .sheet(item: $previewRequest) { request in
            AttachmentPreview(entries: request.entries, startIndex: request.startIndex)
                .ignoresSafeArea()
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.wispr(17, weight: .semibold))
                    Text(AppSettings.shared.displayTitle)
                        .font(.wispr(17))
                }
                .foregroundStyle(Color.wisprInk.opacity(0.6))
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 8) {
                Text(feed.title)
                Image(systemName: feed.icon)
            }
            .font(.wispr(17))
            .foregroundStyle(feed.tint == nil ? Color.wisprInk : Color.wisprOnAccent)
            // A timeline brings its colour with it, so the screen is placed at
            // a glance; the moments have none and stay plain.
            .padding(.horizontal, feed.tint == nil ? 0 : 10)
            .padding(.vertical, feed.tint == nil ? 0 : 5)
            .background {
                if let tint = feed.tint {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint)
                }
            }
        }
    }

    // MARK: - Days

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    daySection(section)
                }

                // A container's worth of room at the end, so the last day — and
                // today, on a quiet week — can still be scrolled up to the top.
                Color.clear
                    .containerRelativeFrame(.vertical)
            }
            // On the stack rather than the days: the scroll position only lands
            // on today when the whole layout is the target.
            .scrollTargetLayout()
        }
        // The side margins inset the scrolled content rather than padding the
        // target layout, which would leave the layout narrower than the scroll
        // view and lay the days out off to one side until the first scroll.
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollPosition($position, anchor: .top)
        .scrollIndicators(.hidden)
        // Laying out lazily means the days above today are only measured as
        // they are reached, so the opening scroll lands short. Asking again
        // once the first pass is done puts today at the top for real.
        .task { position.scrollTo(id: NoteStore.key(for: today), anchor: .top) }
    }

    private func daySection(_ section: DaySection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            dayHeader(for: section.day)

            if section.notes.isEmpty {
                emptyDay
            } else {
                ForEach(section.notes) { note in
                    card(for: note, on: section.day)
                }
            }
        }
        .padding(.bottom, 28)
    }

    /// The separator above a day's notes; tapping it opens that day.
    private func dayHeader(for day: Date) -> some View {
        NavigationLink(value: WisprScreen.day(day)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DayFormat.relativeTitle(for: day))
                            .font(.wispr(20, weight: .semibold))
                            .foregroundStyle(Color.wisprInk)

                        Text(DayFormat.dateSubtitle(for: day))
                            .font(.wispr(13))
                            .foregroundStyle(Color.wisprSecondaryText)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.wispr(13, weight: .semibold))
                        .foregroundStyle(Color.wisprSecondaryText)
                }

                Rectangle()
                    .fill(Color.wisprSeparator)
                    .frame(height: 1)
            }
            .padding(.top, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this day")
    }

    private var emptyDay: some View {
        Text(feed.emptyLabel)
            .font(.wispr(15))
            .foregroundStyle(Color.wisprSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Notes

    private func card(for note: Note, on day: Date) -> some View {
        let stored = store.storedDay(of: note.id) ?? day
        return NoteCard(
            note: note,
            day: stored,
            onToggle: { block in
                withAnimation(.snappy) {
                    store.toggleChecklistItem(block.id, inNote: note.id, on: day)
                }
            },
            onEdit: { editRequest = NoteOnDay(note: note, day: stored) },
            onOpenAttachment: { openAttachment($0, in: note) },
            transcriptExpansion: { transcriptExpansion(for: $0) },
            onTranscribe: { transcribe($0, in: note, on: day) },
            transcribingIDs: transcribingIDs,
            transcriptionErrors: transcriptionErrors
        )
    }

    // MARK: - Voice memos

    private func transcriptExpansion(for memo: NoteAttachment) -> Binding<Bool> {
        Binding(
            get: { expandedTranscripts.contains(memo.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedTranscripts.insert(memo.id)
                } else {
                    expandedTranscripts.remove(memo.id)
                }
            }
        )
    }

    private func transcribe(_ memo: NoteAttachment, in note: Note, on day: Date) {
        transcribingIDs.insert(memo.id)
        transcriptionErrors[memo.id] = nil

        Task {
            defer { transcribingIDs.remove(memo.id) }
            do {
                let transcript = try await VoiceMemoTranscriber.transcript(of: memo)
                withAnimation(.snappy) {
                    store.setTranscript(transcript, forAttachment: memo.id, inNote: note.id, on: day)
                    expandedTranscripts.insert(memo.id)
                }
            } catch {
                transcriptionErrors[memo.id] = error.localizedDescription
            }
        }
    }

    // MARK: - Attachments

    /// Media opens as a swipeable group, so the note's other pictures are one
    /// swipe away.
    private func openAttachment(_ attachment: NoteAttachment, in note: Note) {
        let group = attachment.kind.isVisualMedia ? note.mediaAttachments : [attachment]
        previewRequest = AttachmentPreviewRequest(group, startingAt: attachment)
    }
}

#if DEBUG
#Preview("Notes") {
    NavigationStack {
        MomentTimelineView(moment: .notes)
            .environment(NoteStore.previewSeeded())
            .environment(TimelineStore.previewSeeded())
    }
    .preferredColorScheme(.dark)
}

#Preview("Tasks") {
    NavigationStack {
        MomentTimelineView(moment: .tasks)
            .environment(NoteStore.previewSeeded())
            .environment(TimelineStore.previewSeeded())
    }
    .preferredColorScheme(.dark)
}

#Preview("Events") {
    NavigationStack {
        MomentTimelineView(moment: .events)
            .environment(NoteStore.previewSeeded())
            .environment(TimelineStore.previewSeeded())
    }
    .preferredColorScheme(.dark)
}
#endif
