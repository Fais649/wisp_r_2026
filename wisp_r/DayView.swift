import SwiftUI

/// The main view: one page per day in a horizontally paging scroll view, each
/// page a list of that day's notes.
///
/// Paging runs chronologically left to right, so swiping right moves into the
/// past and swiping left into the future. Tapping the space under the notes
/// starts a new one, tapping a note opens it, and tapping a checklist item
/// crosses it off. Press and hold a note, or swipe it, for Select — which
/// begins a batch selection — and Delete.
struct DayView: View {
    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// How many days either side of today can be paged to.
    private static let pageReach = 400

    /// What the back button reads, so pushing the day view from somewhere other
    /// than the menu still names where it came from.
    private let backTitle: String

    private let today = Calendar.current.startOfDay(for: .now)

    @State private var visibleDayOffset: Int?
    @State private var editingNote: Note?
    @State private var isSelecting = false
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var isShowingMoveSheet = false
    @State private var movingNote: NoteOnDay?
    @State private var schedulingNote: NoteOnDay?
    @State private var previewRequest: AttachmentPreviewRequest?
    @State private var expandedTranscripts: Set<UUID> = []
    @State private var transcribingIDs: Set<UUID> = []
    @State private var transcriptionErrors: [UUID: String] = [:]

    /// Opens on `initialDay`, or today when none is given.
    init(initialDay: Date? = nil, backTitle: String = "Wispr") {
        self.backTitle = backTitle

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let target = calendar.startOfDay(for: initialDay ?? today)
        let offset = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        _visibleDayOffset = State(initialValue: min(max(offset, -Self.pageReach), Self.pageReach))
    }

    private var dayOffsets: [Int] { Array(-Self.pageReach...Self.pageReach) }

    /// The day currently paged into view.
    private var day: Date { date(atOffset: visibleDayOffset ?? 0) }

    private func date(atOffset offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today
    }

    var body: some View {
        ZStack {
            WisprBackground()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                days
            }
        }
        .overlay(alignment: jumpButtonAlignment) {
            if !isShowingToday, !isSelecting {
                jumpToTodayButton
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                selectionToolbar
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editingNote) { note in
            NavigationStack {
                NoteEditorSheet(
                    note: note,
                    day: day,
                    onCommit: { edited in store.save(edited, on: day) },
                    onMove: { destination in move(note, from: day, to: destination) }
                )
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .sheet(isPresented: $isShowingMoveSheet) {
            MoveNotesSheet(
                noteCount: selectedNoteIDs.count,
                startingFrom: day,
                moving: selectedNoteIDs
            ) { destination in
                moveSelected(to: destination)
            }
        }
        .sheet(item: $movingNote) { request in
            MoveNotesSheet(noteCount: 1, startingFrom: request.day, moving: [request.note.id]) { destination in
                move(request.note, from: request.day, to: destination)
            }
        }
        .sheet(item: $schedulingNote) { request in
            NoteScheduleSheet(note: request.note, day: request.day) { schedule in
                withAnimation(.snappy) {
                    store.setSchedule(schedule, forNote: request.note.id, on: request.day)
                }
            }
        }
        .sheet(item: $previewRequest) { request in
            AttachmentPreview(entries: request.entries, startIndex: request.startIndex)
                .ignoresSafeArea()
        }
    }

    // MARK: - Days

    private var days: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(dayOffsets, id: \.self) { offset in
                    page(for: date(atOffset: offset))
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $visibleDayOffset)
        // Selection belongs to one day, so stay put while gathering notes.
        .scrollDisabled(isSelecting)
    }

    /// One day: its heading, its notes, and room underneath to tap.
    private func page(for pageDay: Date) -> some View {
        List {
            header(for: pageDay)
                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 6, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(store.notes(on: pageDay)) { note in
                // No insets: the row is exactly the card, so a press and hold
                // lifts the card itself rather than a wider strip around it.
                noteRow(note, on: pageDay)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            newNoteArea
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        // Gaps between cards come from the list, and the side margins from the
        // content insets, so neither ends up inside a row.
        .listRowSpacing(12)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text(backTitle)
                        .font(.system(size: 17))
                }
                .foregroundStyle(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    private func header(for pageDay: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DayFormat.relativeTitle(for: pageDay))
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)

            Text(DayFormat.dateSubtitle(for: pageDay))
                .font(.system(size: 15))
                .foregroundStyle(Color.wisprSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noteRow(_ note: Note, on pageDay: Date) -> some View {
        NoteCard(
            note: note,
            day: pageDay,
            isSelecting: isSelecting,
            isSelected: selectedNoteIDs.contains(note.id),
            onToggle: { block in
                withAnimation(.snappy) {
                    store.toggleChecklistItem(block.id, inNote: note.id, on: pageDay)
                }
            },
            onEdit: { editingNote = note },
            onSelect: { toggleSelection(of: note) },
            onOpenAttachment: { openAttachment($0, in: note) },
            transcriptExpansion: { transcriptExpansion(for: $0) },
            onTranscribe: { transcribe($0, in: note, on: pageDay) },
            transcribingIDs: transcribingIDs,
            transcriptionErrors: transcriptionErrors
        )
        // The same two actions on a press and hold as on a swipe. A row swipe
        // and the day paging both want a horizontal drag on the same pixels, so
        // the swipe only wins sometimes; the menu always works.
        .contextMenu {
            if !isSelecting {
                noteActions(for: note, on: pageDay)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isSelecting {
                Button {
                    enterSelectMode(selecting: note)
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .tint(.indigo)
            }
        }
        .swipeActions(edge: .trailing) {
            if !isSelecting {
                Button(role: .destructive) {
                    withAnimation(.snappy) {
                        store.delete(note.id, on: pageDay)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func noteActions(for note: Note, on pageDay: Date) -> some View {
        Button {
            enterSelectMode(selecting: note)
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }

        Button {
            movingNote = NoteOnDay(note: note, day: pageDay)
        } label: {
            Label("Move to…", systemImage: "calendar")
        }

        Button {
            schedulingNote = NoteOnDay(note: note, day: pageDay)
        } label: {
            Label(note.schedule == nil ? "Set time" : "Change time", systemImage: "clock")
        }

        Button(role: .destructive) {
            withAnimation(.snappy) {
                store.delete(note.id, on: pageDay)
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// The empty space below a day's notes; tapping it writes something new.
    private var newNoteArea: some View {
        Color.clear
            .frame(height: 360)
            .contentShape(Rectangle())
            .onTapGesture(perform: startNewNote)
    }

    // MARK: - Select mode

    private var selectionToolbar: some View {
        HStack(spacing: 16) {
            Button("Cancel", action: exitSelectMode)

            Spacer()

            Text("^[\(selectedNoteIDs.count) note](inflect: true) selected")
                .font(.system(size: 14))
                .foregroundStyle(Color.wisprSecondaryText)

            Spacer()

            Button {
                isShowingMoveSheet = true
            } label: {
                Label("Move to another day", systemImage: "calendar")
                    .labelStyle(.iconOnly)
            }
            .disabled(selectedNoteIDs.isEmpty)

            Button(role: .destructive, action: deleteSelected) {
                Label("Delete selected notes", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .disabled(selectedNoteIDs.isEmpty)
        }
        .buttonStyle(.glass(.regular.interactive()))
        .font(.system(size: 17))
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(alignment: .top) {
            Rectangle()
                .fill(Color.wisprSeparator)
                .frame(height: 1)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }

    private func enterSelectMode(selecting note: Note) {
        withAnimation(.snappy) {
            isSelecting = true
            selectedNoteIDs = [note.id]
        }
    }

    private func exitSelectMode() {
        withAnimation(.snappy) {
            isSelecting = false
            selectedNoteIDs = []
        }
    }

    private func toggleSelection(of note: Note) {
        withAnimation(.snappy) {
            if selectedNoteIDs.contains(note.id) {
                selectedNoteIDs.remove(note.id)
            } else {
                selectedNoteIDs.insert(note.id)
            }
        }
    }

    private func deleteSelected() {
        withAnimation(.snappy) {
            store.delete(selectedNoteIDs, on: day)
        }
        exitSelectMode()
    }

    private func moveSelected(to destination: Date) {
        withAnimation(.snappy) {
            store.move(selectedNoteIDs, from: day, to: destination)
        }
        exitSelectMode()
    }

    private func move(_ note: Note, from source: Date, to destination: Date) {
        withAnimation(.snappy) {
            store.move([note.id], from: source, to: destination)
        }
    }

    // MARK: - Jumping back to today

    private var isShowingToday: Bool { (visibleDayOffset ?? 0) == 0 }
    private var isShowingPast: Bool { (visibleDayOffset ?? 0) < 0 }

    /// Sits on the side today lies on: trailing when looking at the past,
    /// leading when looking at the future.
    private var jumpButtonAlignment: Alignment {
        isShowingPast ? .bottomTrailing : .bottomLeading
    }

    private var jumpToTodayButton: some View {
        Button {
            withAnimation(.snappy) { visibleDayOffset = 0 }
        } label: {
            Image(systemName: "diamond.fill")
                .font(.system(size: 19))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.bar, in: Circle())
                .overlay {
                    Circle().stroke(Color.wisprSeparator)
                }
        }
        .buttonStyle(.plain)
        .padding(24)
        .accessibilityLabel("Back to today")
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Notes

    private func startNewNote() {
        guard !isSelecting else { return }
        editingNote = Note(blocks: [NoteBlock()])
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

    private func transcribe(_ memo: NoteAttachment, in note: Note, on pageDay: Date) {
        transcribingIDs.insert(memo.id)
        transcriptionErrors[memo.id] = nil

        Task {
            defer { transcribingIDs.remove(memo.id) }
            do {
                let transcript = try await VoiceMemoTranscriber.transcript(of: memo)
                withAnimation(.snappy) {
                    store.setTranscript(transcript, forAttachment: memo.id, inNote: note.id, on: pageDay)
                    expandedTranscripts.insert(memo.id)
                }
            } catch {
                transcriptionErrors[memo.id] = error.localizedDescription
            }
        }
    }

    // MARK: - Attachments

    /// Previews the tapped attachment. Media opens as a swipeable group so the
    /// rest of the note's photos are one swipe away.
    private func openAttachment(_ attachment: NoteAttachment, in note: Note) {
        let group = attachment.kind.isVisualMedia ? note.mediaAttachments : [attachment]
        previewRequest = AttachmentPreviewRequest(group, startingAt: attachment)
    }
}

// MARK: - Note card

struct NoteCard: View {
    let note: Note
    /// The day the note sits on, so its time can be read against it.
    var day: Date = .now
    var isSelecting = false
    var isSelected = false
    let onToggle: (NoteBlock) -> Void
    let onEdit: () -> Void
    var onSelect: () -> Void = {}
    var onOpenAttachment: (NoteAttachment) -> Void = { _ in }
    var transcriptExpansion: (NoteAttachment) -> Binding<Bool> = { _ in .constant(false) }
    var onTranscribe: (NoteAttachment) -> Void = { _ in }
    var transcribingIDs: Set<UUID> = []
    var transcriptionErrors: [UUID: String] = [:]

    private var numbers: [UUID: Int] { NoteMarkup.numbers(for: note.blocks) }
    private var hasText: Bool { note.blocks.contains { !$0.isBlank } }
    private var hasBody: Bool {
        hasText || !note.documentAttachments.isEmpty || note.schedule != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Media sits flush with the card edges, text underneath.
            if !note.mediaAttachments.isEmpty {
                MediaMosaic(attachments: note.mediaAttachments, onOpen: onOpenAttachment)
            }

            if hasBody {
                body(of: note)
            }

            // Memos run the full width of the card, like the media above.
            ForEach(note.voiceMemos) { memo in
                VoiceMemoView(
                    attachment: memo,
                    isTranscriptExpanded: transcriptExpansion(memo),
                    onTranscribe: { onTranscribe(memo) },
                    isTranscribing: transcribingIDs.contains(memo.id),
                    transcriptionError: transcriptionErrors[memo.id]
                )
            }

            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wisprGlassCard()
        // Sits above the rows so a tap selects the note rather than editing it.
        .overlay {
            if isSelecting {
                selectionLayer
            }
        }
    }

    /// The documents and text of a note. Generous vertical padding keeps a
    /// comfortable area to tap into editing, especially under pictures.
    private func body(of note: Note) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The time leads the note, the way a heading would.
            if let schedule = note.schedule {
                NoteScheduleLabel(schedule: schedule, day: day)
            }

            ForEach(note.documentAttachments) { attachment in
                Button {
                    onOpenAttachment(attachment)
                } label: {
                    DocumentAttachmentRow(attachment: attachment)
                        .wisprCardBackground(cornerRadius: 10)
                }
                .buttonStyle(.plain)
            }

            if !note.blocks.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(note.blocks) { block in
                        row(for: block)
                            .padding(.leading, CGFloat(block.indent) * 18)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        // Less than the top: the footer closes the card underneath.
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// When the note was written, closing every card. It doubles as somewhere
    /// to tap into editing on a card that is nothing but pictures or a memo.
    private var footer: some View {
        Text(createdCaption)
            .font(.system(size: 11).italic())
            .foregroundStyle(Color.white.opacity(0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, footerTopPadding)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens this note")
    }

    /// Media and memos run flush to the card edge, so the gap above the footer
    /// belongs here; a text body has already left one behind itself.
    private var footerTopPadding: CGFloat {
        hasBody && note.voiceMemos.isEmpty ? 0 : 12
    }

    /// The time the note was written, dated as well when that was some other
    /// day — which is what a note moved here looks like.
    private var createdCaption: String {
        let time = note.createdAt.formatted(date: .omitted, time: .shortened)
        guard Calendar.current.isDate(note.createdAt, inSameDayAs: day) else {
            let date = note.createdAt.formatted(
                Date.FormatStyle().month(.abbreviated).day()
            )
            return "Written \(date) at \(time)"
        }

        return "Written at \(time)"
    }

    private var selectionLayer: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.08) : .clear)
                .strokeBorder(isSelected ? Color.white.opacity(0.5) : Color.wisprSeparator, lineWidth: 1.5)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? .white : Color.white.opacity(0.45))
                .padding(10)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func row(for block: NoteBlock) -> some View {
        switch block.kind {
        case .paragraph:
            blockText(block)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onEdit)

        case .checklist(let isChecked):
            ChecklistItemRow(
                block: block,
                isChecked: isChecked,
                onToggle: { onToggle(block) },
                onEdit: onEdit
            )

        case .bullet:
            markedRow(block, marker: Text("•"))

        case .numbered:
            markedRow(block, marker: Text("\(numbers[block.id] ?? 1)."))
        }
    }

    private func markedRow(_ block: NoteBlock, marker: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            marker
                .font(.system(size: 17))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(minWidth: 14, alignment: .leading)

            blockText(block)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
    }

    private func blockText(_ block: NoteBlock) -> some View {
        Text(block.text)
            .font(.system(size: 17))
            .foregroundStyle(.white)
    }
}

// MARK: - Media mosaic

/// Attached photos and videos laid out above a note's text: one fills the
/// width, two share it, three pair a tall image with a stack, and four or more
/// form a grid whose last tile counts the remainder.
///
/// The height is derived from the measured width and the tiles simply fill
/// their slots. Sizing the tiles with `aspectRatio` instead would let the row's
/// available height decide the layout, since a thumbnail is flexible in both
/// directions — which shrinks the images and leaves the row the wrong height.
private struct MediaMosaic: View {
    let attachments: [NoteAttachment]
    let onOpen: (NoteAttachment) -> Void

    private let spacing: CGFloat = 2
    @State private var width: CGFloat = 0

    private var height: CGFloat {
        guard width > 0 else { return 0 }
        let half = (width - spacing) / 2

        return switch attachments.count {
        case 1: width * 0.72    // a little wider than it is tall
        case 2, 3: half         // squares, or a square beside a stacked pair
        default: half * 2 + spacing
        }
    }

    var body: some View {
        tiles
            .frame(height: height)
            .clipped()
            // Measured from a zero-height backdrop, so the width is known
            // before the tiles are given their slots.
            .background {
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            }
    }

    @ViewBuilder
    private var tiles: some View {
        switch attachments.count {
        case 1:
            tile(attachments[0])

        case 2:
            HStack(spacing: spacing) {
                tile(attachments[0])
                tile(attachments[1])
            }

        case 3:
            HStack(spacing: spacing) {
                tile(attachments[0])
                VStack(spacing: spacing) {
                    tile(attachments[1])
                    tile(attachments[2])
                }
            }

        default:
            VStack(spacing: spacing) {
                HStack(spacing: spacing) {
                    tile(attachments[0])
                    tile(attachments[1])
                }
                HStack(spacing: spacing) {
                    tile(attachments[2])
                    tile(attachments[3], remainder: attachments.count - 4)
                }
            }
        }
    }

    private func tile(_ attachment: NoteAttachment, remainder: Int = 0) -> some View {
        Button {
            onOpen(attachment)
        } label: {
            AttachmentThumbnail(attachment: attachment)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if remainder > 0 {
                        ZStack {
                            Color.black.opacity(0.45)
                            Text("+\(remainder)")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

private struct ChecklistItemRow: View {
    let block: NoteBlock
    let isChecked: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void

    /// Width of the strip at the trailing edge that opens the note, so a note
    /// made only of checklist items can still be edited.
    private let editStripWidth: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isChecked ? Color.white.opacity(0.45) : Color.white.opacity(0.7))

                Text(block.text)
                    .font(.system(size: 17))
                    .strikethrough(isChecked, color: Color.white.opacity(0.45))
                    .foregroundStyle(isChecked ? Color.white.opacity(0.4) : .white)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            Color.clear
                .frame(width: editStripWidth)
                .contentShape(Rectangle())
                .onTapGesture(perform: onEdit)
                .accessibilityLabel("Edit note")
                .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - Day formatting

enum DayFormat {
    /// "Today", "Yesterday", "Tomorrow", or e.g. "3 days ago".
    static func relativeTitle(for day: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let target = calendar.startOfDay(for: day)
        let dayOffset = calendar.dateComponents([.day], from: today, to: target).day ?? 0

        let title: String
        switch dayOffset {
        case 0: title = "Today"
        case 1: title = "Tomorrow"
        case -1: title = "Yesterday"
        default: title = target.formatted(.relative(presentation: .named, unitsStyle: .wide))
        }

        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// e.g. "Wednesday, September 16, 2026".
    static func dateSubtitle(for day: Date) -> String {
        day.formatted(
            Date.FormatStyle()
                .weekday(.wide)
                .month(.wide)
                .day()
                .year()
        )
    }
}

#if DEBUG
extension NoteStore {
    /// A store holding a few notes on today, for previews only.
    static func previewSeeded() -> NoteStore {
        let store = NoteStore(persistsToDisk: false)
        let today = Calendar.current.startOfDay(for: .now)
        var heading = AttributedString("Groceries for the week")
        heading.font = .system(size: 22, weight: .semibold)

        store.save(
            Note(blocks: [
                NoteBlock(text: heading),
                NoteBlock(text: "Milk", kind: .checklist(isChecked: false)),
                NoteBlock(text: "Coffee beans", kind: .checklist(isChecked: false)),
                NoteBlock(text: "Bread", kind: .checklist(isChecked: true))
            ]),
            on: today
        )
        store.save(
            Note(blocks: [
                NoteBlock(text: "Bike service"),
                NoteBlock(text: "Call the shop", kind: .numbered),
                NoteBlock(text: "Ask about the wheel", kind: .numbered, indent: 1),
                NoteBlock(text: "Drop it off Friday", kind: .numbered),
                NoteBlock(text: "Spare tube", kind: .bullet)
            ]),
            on: today
        )
        store.save(
            Note(
                blocks: [NoteBlock(text: "Dentist")],
                schedule: NoteSchedule(startMinute: 9 * 60 + 30, endMinute: 10 * 60 + 15)
            ),
            on: today
        )
        store.save(
            Note(
                blocks: [NoteBlock(text: "Tomorrow's reminder")],
                schedule: NoteSchedule(startMinute: 21 * 60, endMinute: nil)
            ),
            on: Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        )
        return store
    }
}
#endif

#Preview("Several notes") {
    DayView()
        .environment(NoteStore.previewSeeded())
        .preferredColorScheme(.dark)
}

#Preview("One note") {
    let store = NoteStore(persistsToDisk: false)
    store.save(
        Note(blocks: [
            NoteBlock(text: "Call the bike shop"),
            NoteBlock(text: "Ask about the wheel", kind: .checklist(isChecked: false))
        ]),
        on: Calendar.current.startOfDay(for: .now)
    )

    return DayView()
        .environment(store)
        .preferredColorScheme(.dark)
}

#Preview("Media layouts") {
    let store = NoteStore(persistsToDisk: false)
    let today = Calendar.current.startOfDay(for: .now)

    for count in [1, 2, 3, 5] {
        let pictures: [NoteAttachment] = (0..<count).map { index in
            NoteAttachment(kind: .image, fileName: "preview-\(index).jpg", displayName: "Photo")
        }
        let caption: String = count == 1 ? "1 picture" : "\(count) pictures"

        store.save(
            Note(blocks: [NoteBlock(text: AttributedString(caption))], attachments: pictures),
            on: today
        )
    }

    return DayView()
        .environment(store)
        .preferredColorScheme(.dark)
}
