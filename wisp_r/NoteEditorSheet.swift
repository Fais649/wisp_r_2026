import SwiftUI
import PhotosUI

/// A rich text editor for one note.
///
/// Structure lives in the text as leading tabs and markers (see ``NoteMarkup``),
/// which is what lets a single `TextEditor` offer Notes-style checklists. The
/// markup is parsed back into ``NoteBlock`` values when the sheet is saved.
///
/// The bar above the keyboard carries only the checklist toggle, cancel and
/// save; character formatting stays available under Format in the system text
/// selection menu.
struct NoteEditorSheet: View {
    /// Set explicitly so the media carousel can be clipped to exactly the same
    /// curve as the sheet it sits in.
    static let cornerRadius: CGFloat = 20

    let note: Note
    let day: Date
    let capturesCreationLocation: Bool
    let onCommit: (Note) -> Void
    /// Called after the note has been saved when the calendar button was used
    /// to send it to another day.
    let onMove: (Date) -> Void

    @State private var text: AttributedString
    @State private var selection = AttributedTextSelection()
    @State private var attachments: [NoteAttachment]
    @State private var hasFinished = false
    /// Files written during this session, removed again if the sheet is cancelled.
    @State private var addedAttachments: [NoteAttachment] = []
    /// Attachments taken off the note, removed from disk only once saved.
    @State private var removedAttachments: [NoteAttachment] = []

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isShowingPhotoPicker = false
    @State private var isShowingFileImporter = false
    @State private var isShowingCamera = false
    @State private var isShowingScanner = false
    @State private var previewRequest: AttachmentPreviewRequest?

    @State private var isShowingMoveSheet = false
    @State private var isShowingScheduleSheet = false
    /// The time set in this session, kept here until the note is saved.
    @State private var schedule: NoteSchedule?
    /// The day the event starts on, which may move off the note's current day.
    @State private var scheduleDay: Date
    /// The day chosen in the move picker, acted on once it has closed.
    @State private var pendingMove: Date?

    @State private var recorder = VoiceMemoRecorder()
    @State private var expandedTranscripts: Set<UUID> = []
    @State private var transcribingIDs: Set<UUID> = []
    @State private var transcriptionErrors: [UUID: String] = [:]
    @State private var micPermissionDenied = false

    @FocusState private var isEditorFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationHistory.self) private var locationHistory

    init(
        note: Note,
        day: Date,
        capturesCreationLocation: Bool = false,
        onCommit: @escaping (Note) -> Void,
        onMove: @escaping (Date) -> Void = { _ in }
    ) {
        self.note = note
        self.day = day
        self.capturesCreationLocation = capturesCreationLocation
        self.onCommit = onCommit
        self.onMove = onMove
        _text = State(initialValue: NoteMarkup.text(from: note.blocks))
        _attachments = State(initialValue: note.attachments)
        _schedule = State(initialValue: note.schedule)
        _scheduleDay = State(initialValue: day)
    }

    var body: some View {
        // No navigation bar: nothing sits above the note itself.
        VStack(spacing: 0) {
            // Edge to edge, following the sheet's rounded top corners.
            if !mediaAttachments.isEmpty {
                MediaCarousel(
                    attachments: mediaAttachments,
                    onOpen: { previewMedia(startingAt: $0) },
                    onRemove: remove
                )
            }

            if !documentAttachments.isEmpty {
                DocumentAttachmentList(
                    attachments: documentAttachments,
                    onOpen: { previewDocument($0) },
                    onRemove: remove
                )
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }

            if let schedule {
                NoteScheduleLabel(schedule: schedule, day: scheduleDay)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .onTapGesture { present { isShowingScheduleSheet = true } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Changes the note's time")
            }

            TextEditor(text: $text, selection: $selection)
                .font(.wispr(17, role: .editor))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                // Lets the keyboard — and with it the bar — be put away.
                .scrollDismissesKeyboard(.interactively)
                .padding(.horizontal, 14)
                .padding(.top, mediaAttachments.isEmpty ? 16 : 8)
                .focused($isEditorFocused)
                .onChange(of: text) { oldValue, newValue in
                    continueList(from: oldValue, to: newValue)
                }.toolbar {
                    keyboardToolbar
                }
        }
        .background(WisprBackground())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // Sharing one inset keeps memos structurally above the
                // accessory bar instead of relying on a fixed clearance.
                if !voiceMemos.isEmpty || recorder.isRecording {
                    pinnedMemoCard
                }
            }
        }
        .tint(.white)
        // Opens over half the screen, and can be pulled the rest of the way up.
        .presentationDetents([.medium, .large])
        .wisprSheetEdge(cornerRadius: Self.cornerRadius)
        // Also saves when the sheet is swiped away rather than dismissed.
        .onDisappear(perform: save)
        .onAppear { isEditorFocused = true }
        .task {
            if capturesCreationLocation {
                locationHistory.requestLocationForNewNote()
            }
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: nil,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPickedMedia(items) }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: AttachmentStore.allowedDocumentTypes,
            allowsMultipleSelection: true
        ) { result in
            importDocuments(from: result)
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker(onCapture: add)
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isShowingScanner) {
            DocumentScanner(onScan: add)
                .ignoresSafeArea()
        }
        .sheet(item: $previewRequest) { request in
            AttachmentPreview(entries: request.entries, startIndex: request.startIndex)
                .ignoresSafeArea()
        }
        // The move is finished once the picker has closed, rather than from
        // inside it, so the editor isn't dismissed mid-dismissal.
        .sheet(isPresented: $isShowingMoveSheet, onDismiss: completeMove) {
            MoveNotesSheet(noteCount: 1, startingFrom: day, moving: [note.id]) { destination in
                pendingMove = destination
            }
        }
        .sheet(isPresented: $isShowingScheduleSheet) {
            NoteScheduleSheet(note: scheduledNote, day: scheduleDay) { newSchedule, startDay in
                withAnimation(.snappy) {
                    schedule = newSchedule
                    scheduleDay = startDay
                }
            }
        }
        .alert("Microphone access is off", isPresented: $micPermissionDenied) {
            Button("OK") {}
        } message: {
            Text("Allow microphone access in Settings to record voice memos.")
        }
    }

    // MARK: - Keyboard toolbar

    /// Sits directly above the keyboard: checklist and add actions on the left,
    /// keyboard dismissal centered, and finishing actions on the right.
    private var keyboardToolbar: ToolbarItemGroup<some View> {
        ToolbarItemGroup(placement: .keyboard) {
        Button(action: toggleChecklist) {
                    Image(systemName: "checklist")
                        .frame(width: 44, height: 44)
            }

                addAttachmentMenu
                    .frame(width: 44, height: 44)

                calendarMenu
                    .frame(width: 44, height: 44)

            Button {
                isEditorFocused = false
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
            }

                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }

                Button(action: saveAndDismiss) {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .frame(width: 44, height: 44)
                }
    }
}

    /// Sending the note to another day, or giving it a time on this one.
    private var calendarMenu: some View {
        Menu {
            Button {
                present { isShowingMoveSheet = true }
            } label: {
                Label("Move to…", systemImage: "calendar")
            }

            Button {
                present { isShowingScheduleSheet = true }
            } label: {
                Label(schedule == nil ? "Set time" : "Change time", systemImage: "clock")
            }
        } label: {
            Image(systemName: "calendar")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Schedule note")
    }

    /// Puts the keyboard away first, so the sheet isn't pushed up by it.
    private func present(_ sheet: @escaping () -> Void) {
        isEditorFocused = false
        sheet()
    }

    /// The note as it stands in this session, so the schedule sheet opens on
    /// the time set here rather than the one the note was saved with.
    private var scheduledNote: Note {
        var copy = note
        copy.schedule = schedule
        return copy
    }

    private var addAttachmentMenu: some View {
        Menu {
            Section("Media") {
                Button {
                    isShowingPhotoPicker = true
                } label: {
                    Label("Choose photos or videos", systemImage: "photo.on.rectangle")
                }

                Button {
                    isShowingCamera = true
                } label: {
                    Label("Take photo or video", systemImage: "camera")
                }
                .disabled(!CameraPicker.isAvailable)
            }

            Section("Documents") {
                Button {
                    isShowingFileImporter = true
                } label: {
                    Label("Choose file", systemImage: "folder")
                }

                Button {
                    isShowingScanner = true
                } label: {
                    Label("Scan document", systemImage: "doc.viewfinder")
                }
                .disabled(!DocumentScanner.isSupported)
            }

            Section {
                Button(action: startRecording) {
                    Label("Record a voice memo", systemImage: "mic")
                }
                .disabled(recorder.isRecording)
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Add attachment")
    }

    // MARK: - Voice memos

    /// The memos pinned above the keyboard bar while writing, running edge to
    /// edge like the ones in a day view card.
    private var pinnedMemoCard: some View {
        VStack(spacing: 0) {
            if recorder.isRecording {
                recordingRow
            }

            ForEach(voiceMemos) { memo in
                VoiceMemoView(
                    attachment: memo,
                    isTranscriptExpanded: transcriptExpansion(for: memo),
                    onTranscribe: { transcribe(memo) },
                    isTranscribing: transcribingIDs.contains(memo.id),
                    transcriptionError: transcriptionErrors[memo.id]
                )
                .contextMenu {
                    Button(role: .destructive) {
                        remove(memo)
                    } label: {
                        Label("Delete memo", systemImage: "trash")
                    }
                }
            }
        }
        .background(.bar)
    }

    /// Shown while recording: a live level trace, the elapsed time and a stop button.
    private var recordingRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)

            WaveformView(samples: Array(recorder.levels.suffix(44)))
                .frame(height: 28)
                .frame(maxWidth: .infinity)

            Text(recorder.formattedElapsed)
                .font(.wispr(13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.7))

            Button {
                recorder.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.wispr(14))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard recording")

            Button(action: stopRecording) {
                Image(systemName: "stop.fill")
                    .font(.wispr(14))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.04))
        .background(alignment: .top) {
            Rectangle()
                .fill(Color.wisprSeparator)
                .frame(height: 1)
        }
    }

    private func startRecording() {
        Task {
            let started = await recorder.start()
            if !started { micPermissionDenied = true }
        }
    }

    private func stopRecording() {
        guard let memo = recorder.finish() else { return }
        add(memo)
    }

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

    private func transcribe(_ memo: NoteAttachment) {
        transcribingIDs.insert(memo.id)
        transcriptionErrors[memo.id] = nil

        Task {
            defer { transcribingIDs.remove(memo.id) }
            do {
                let transcript = try await VoiceMemoTranscriber.transcript(of: memo)
                guard let index = attachments.firstIndex(where: { $0.id == memo.id }) else { return }
                withAnimation(.snappy) {
                    attachments[index].transcript = transcript
                    expandedTranscripts.insert(memo.id)
                }
            } catch {
                transcriptionErrors[memo.id] = error.localizedDescription
            }
        }
    }

    // MARK: - Attachments

    private var mediaAttachments: [NoteAttachment] { attachments.filter(\.kind.isVisualMedia) }
    private var documentAttachments: [NoteAttachment] { attachments.filter { $0.kind == .document } }
    private var voiceMemos: [NoteAttachment] { attachments.filter { $0.kind == .audio } }

    private func add(_ attachment: NoteAttachment) {
        withAnimation(.snappy) {
            attachments.append(attachment)
        }
        addedAttachments.append(attachment)
    }

    private func remove(_ attachment: NoteAttachment) {
        withAnimation(.snappy) {
            attachments.removeAll { $0.id == attachment.id }
        }
        if let index = addedAttachments.firstIndex(where: { $0.id == attachment.id }) {
            // Added and removed in the same session: the file can go now.
            addedAttachments.remove(at: index)
            AttachmentStore.delete([attachment])
        } else {
            removedAttachments.append(attachment)
        }
    }

    private func importPickedMedia(_ items: [PhotosPickerItem]) async {
        for item in items {
            let contentType = item.supportedContentTypes.first
            let kind = AttachmentStore.kind(for: contentType)
            let fileExtension = contentType?.preferredFilenameExtension ?? (kind == .video ? "mov" : "jpg")

            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            guard let attachment = AttachmentStore.store(
                data,
                extension: fileExtension,
                displayName: kind == .video ? "Video" : "Photo",
                kind: kind
            ) else { continue }

            add(attachment)
        }
        photoSelection = []
    }

    private func importDocuments(from result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                guard let attachment = AttachmentStore.importFile(at: url, kind: .document) else { continue }
                add(attachment)
            }
        case .failure(let error):
            print("Wispr: could not attach file — \(error)")
        }
    }

    /// Media previews open as a swipeable group; a document opens on its own.
    private func previewMedia(startingAt attachment: NoteAttachment) {
        previewRequest = AttachmentPreviewRequest(mediaAttachments, startingAt: attachment)
    }

    private func previewDocument(_ attachment: NoteAttachment) {
        previewRequest = AttachmentPreviewRequest([attachment], startingAt: attachment)
    }

    // MARK: - Finishing

    private func saveAndDismiss() {
        save()
        dismiss()
    }

    /// Saves the note onto its current day first, so the move has something to
    /// carry across — a note being written for the first time included.
    private func completeMove() {
        guard let destination = pendingMove else { return }
        pendingMove = nil

        commit(movingTo: destination)
        dismiss()
    }

    private func save() {
        commit(movingTo: nil)
    }

    /// Saves the note, then moves it when the event starts on another day or
    /// the move picker chose one. An explicit destination wins over the event's
    /// start day.
    private func commit(movingTo destination: Date?) {
        guard !hasFinished else { return }
        hasFinished = true

        var updated = note
        updated.blocks = NoteMarkup.blocks(from: text)
        updated.attachments = attachments
        updated.schedule = schedule
        if capturesCreationLocation, updated.location == nil {
            updated.location = locationHistory.locationForNewNote()
        }
        onCommit(updated)

        let target = destination ?? scheduleDay
        if !Calendar.current.isDate(target, inSameDayAs: day) {
            onMove(target)
        }

        // Files of attachments taken off the note are no longer referenced.
        AttachmentThumbnails.shared.forget(removedAttachments)
        AttachmentStore.delete(removedAttachments)
    }

    /// Leaves the note exactly as it was, whether it is new or being edited,
    /// discarding any files added during this session.
    private func cancel() {
        hasFinished = true
        AttachmentThumbnails.shared.forget(addedAttachments)
        AttachmentStore.delete(addedAttachments)
        dismiss()
    }

    // MARK: - Character formatting

    /// Turns the selected lines into checklist items, or back into plain
    /// paragraphs when all of them already are.
    private func toggleChecklist() {
        let lines = selectedLines()
        guard !lines.isEmpty else { return }

        let alreadyChecklist = lines.allSatisfy { line in
            switch NoteMarkup.parseLine(line.text).marker {
            case .unchecked, .checked: true
            default: false
            }
        }

        let edits = lines.map { line in
            let parsed = NoteMarkup.parseLine(line.text)
            return TextEdit(
                start: line.start + parsed.indent,
                length: parsed.markerLength,
                replacement: alreadyChecklist ? "" : NoteMarkup.unchecked
            )
        }

        apply(edits)
    }

    /// Continues a list when Return is pressed inside one, and leaves the list
    /// when Return is pressed on an item that is still empty.
    private func continueList(from oldValue: AttributedString, to newValue: AttributedString) {
        let oldCharacters = Array(String(oldValue.characters))
        let characters = Array(String(newValue.characters))

        // Only react to a single typed newline; programmatic edits differ by more.
        guard characters.count == oldCharacters.count + 1,
              let newlineOffset = firstDifference(between: oldCharacters, and: characters),
              characters[newlineOffset] == "\n"
        else { return }

        let lineStart = lineStartOffset(in: characters, containing: newlineOffset)
        let brokenLine = String(characters[lineStart..<newlineOffset])
        let parsed = NoteMarkup.parseLine(brokenLine)

        guard let marker = parsed.marker else {
            // Plain text: carry the indentation onto the new line.
            guard parsed.indent > 0 else { return }
            let indentation = String(repeating: NoteMarkup.indentUnit, count: parsed.indent)
            insert(indentation, at: newlineOffset + 1)
            setCaret(to: newlineOffset + 1 + indentation.count)
            return
        }

        if brokenLine.count == parsed.contentOffset {
            // The item was empty, so leave the list instead of continuing it.
            removeCharacters(at: lineStart, count: parsed.contentOffset)
            setCaret(to: newlineOffset + 1 - parsed.contentOffset)
            return
        }

        let nextMarker: String
        switch marker {
        case .unchecked, .checked: nextMarker = NoteMarkup.unchecked
        case .bullet: nextMarker = NoteMarkup.bullet
        case .numbered(let number): nextMarker = "\(number + 1). "
        }

        let prefix = String(repeating: NoteMarkup.indentUnit, count: parsed.indent) + nextMarker
        insert(prefix, at: newlineOffset + 1)
        setCaret(to: newlineOffset + 1 + prefix.count)
    }

    // MARK: - Text editing helpers

    private struct TextEdit {
        var start: Int
        var length: Int
        var replacement: String

    }

    /// Applies edits back to front so earlier offsets stay valid. The attributed
    /// string updates the bound selection in the same mutation, keeping the
    /// insertion point synchronized with toolbar-driven edits.
    private func apply(_ edits: [TextEdit]) {
        guard !edits.isEmpty else { return }

        text.transform(updating: &selection) { updated in
            for edit in edits.reversed() {
                let lower = updated.index(atCharacterOffset: edit.start)
                let upper = updated.index(atCharacterOffset: edit.start + edit.length)
                updated.replaceSubrange(lower..<upper, with: AttributedString(edit.replacement))
            }
        }
    }

    private func insert(_ string: String, at offset: Int) {
        text.transform(updating: &selection) { updated in
            updated.insert(AttributedString(string), at: updated.index(atCharacterOffset: offset))
        }
    }

    private func removeCharacters(at offset: Int, count: Int) {
        text.transform(updating: &selection) { updated in
            let lower = updated.index(atCharacterOffset: offset)
            let upper = updated.index(atCharacterOffset: offset + count)
            updated.removeSubrange(lower..<upper)
        }
    }

    private func setCaret(to offset: Int) {
        let clamped = min(max(offset, 0), text.characters.count)
        let index = text.index(atCharacterOffset: clamped)
        selection = AttributedTextSelection(range: index..<index)
    }

    private func selectionOffsets() -> (start: Int, end: Int) {
        switch selection.indices(in: text) {
        case .insertionPoint(let index):
            let offset = text.characterOffset(of: index)
            return (offset, offset)
        case .ranges(let rangeSet):
            guard let first = rangeSet.ranges.first, let last = rangeSet.ranges.last else {
                return (0, 0)
            }
            return (text.characterOffset(of: first.lowerBound), text.characterOffset(of: last.upperBound))
        }
    }

    /// Every line the selection touches, in document order.
    private func selectedLines() -> [(start: Int, text: String)] {
        let characters = Array(String(text.characters))
        let offsets = selectionOffsets()
        let lowerBound = min(offsets.start, offsets.end)
        let upperBound = max(offsets.start, offsets.end)

        var lines: [(start: Int, text: String)] = []
        var lineStart = 0

        while true {
            var lineEnd = lineStart
            while lineEnd < characters.count, characters[lineEnd] != "\n" { lineEnd += 1 }
            if lineStart <= upperBound, lineEnd >= lowerBound {
                lines.append((lineStart, String(characters[lineStart..<lineEnd])))
            }
            if lineEnd >= characters.count { break }
            lineStart = lineEnd + 1
        }

        return lines
    }

    private func firstDifference(between old: [Character], and new: [Character]) -> Int? {
        for offset in 0..<min(old.count, new.count) where old[offset] != new[offset] {
            return offset
        }
        return old.count < new.count ? old.count : nil
    }

    private func lineStartOffset(in characters: [Character], containing offset: Int) -> Int {
        var start = min(offset, characters.count)
        while start > 0, characters[start - 1] != "\n" { start -= 1 }
        return start
    }
}

// MARK: - Media carousel

/// Photos and videos as a paging carousel that runs edge to edge above the
/// text, taking up no more than a third of the sheet so there is always room
/// to write.
private struct MediaCarousel: View {
    let attachments: [NoteAttachment]
    let onOpen: (NoteAttachment) -> Void
    let onRemove: (NoteAttachment) -> Void

    /// Share of the sheet's height the carousel may use.
    private let heightFraction: CGFloat = 0.3

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(attachments) { attachment in
                    Button {
                        onOpen(attachment)
                    } label: {
                        AttachmentThumbnail(attachment: attachment)
                            .containerRelativeFrame(.horizontal)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            onRemove(attachment)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .containerRelativeFrame(.vertical) { height, _ in height * heightFraction }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: NoteEditorSheet.cornerRadius,
                topTrailingRadius: NoteEditorSheet.cornerRadius,
                style: .continuous
            )
        )
        .overlay(alignment: .bottom) {
            if attachments.count > 1 {
                Text("\(attachments.count) items")
                    .font(.wispr(12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.bottom, 10)
            }
        }
    }
}

// MARK: - Document attachments

/// Attached documents as rows, tappable to preview their contents.
private struct DocumentAttachmentList: View {
    let attachments: [NoteAttachment]
    let onOpen: (NoteAttachment) -> Void
    let onRemove: (NoteAttachment) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(attachments) { attachment in
                Button {
                    onOpen(attachment)
                } label: {
                    DocumentAttachmentRow(attachment: attachment)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        onRemove(attachment)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }

                if attachment.id != attachments.last?.id {
                    Rectangle()
                        .fill(Color.wisprSeparator)
                        .frame(height: 1)
                        .padding(.leading, 44)
                }
            }
        }
        .wisprCardBackground(cornerRadius: 12)
    }
}

struct DocumentAttachmentRow: View {
    let attachment: NoteAttachment

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: attachment.symbolName)
                .font(.wispr(18))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.wispr(15))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(attachment.formattedSize)
                    .font(.wispr(12))
                    .foregroundStyle(Color.wisprSecondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .contentShape(Rectangle())
    }
}

#if DEBUG
#Preview {
    NoteEditorSheet(
        note: Note(blocks: [
            NoteBlock(text: "Packing list"),
            NoteBlock(text: "Charger", kind: .checklist(isChecked: false)),
            NoteBlock(text: "Cables", kind: .bullet, indent: 1),
            NoteBlock(text: "Passport", kind: .checklist(isChecked: true))
        ]),
        day: .now
    ) { _ in }
    .preferredColorScheme(.dark)
}
#endif
