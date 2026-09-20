import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    @Environment(LocationHistory.self) private var locationHistory
    @Environment(\.dismiss) private var dismiss

    /// How many days either side of today can be paged to.
    private static let pageReach = 400
    private static let dayOffsets = Array(-pageReach...pageReach)

    /// What the back button reads, so pushing the day view from somewhere other
    /// than the menu still names where it came from.
    private let backTitle: String

    /// A request from outside — the widget's plus — to write something new.
    /// Cleared once honoured.
    @Binding private var newNoteRequest: UUID?

    private let today = Calendar.current.startOfDay(for: .now)

    @State private var visibleDayOffset: Int?
    @State private var editingNote: Note?
    @State private var isCreatingNote = false
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
    init(
        initialDay: Date? = nil,
        backTitle: String = AppSettings.shared.displayTitle,
        newNoteRequest: Binding<UUID?> = .constant(nil)
    ) {
        self.backTitle = backTitle
        _newNoteRequest = newNoteRequest

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let target = calendar.startOfDay(for: initialDay ?? today)
        let offset = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        _visibleDayOffset = State(initialValue: min(max(offset, -Self.pageReach), Self.pageReach))
    }

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
        // `task(id:)` rather than `onChange`: a request from the widget can
        // land before this view exists, when the tap launches the app cold.
        .task(id: newNoteRequest) {
            guard newNoteRequest != nil else { return }
            newNoteRequest = nil
            composeNewNoteForToday()
        }
        .sheet(item: $editingNote) { note in
            let home = store.storedDay(of: note.id) ?? day
            NavigationStack {
                NoteEditorSheet(
                    note: note,
                    day: home,
                    capturesCreationLocation: isCreatingNote,
                    onCommit: { edited in store.save(edited, on: home) },
                    onMove: { destination in move(note, from: home, to: destination) }
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
            let home = store.storedDay(of: request.note.id) ?? request.day
            NoteScheduleSheet(note: request.note, day: home) { schedule, startDay in
                withAnimation(.snappy) {
                    store.setSchedule(schedule, forNote: request.note.id, on: home)
                    if !Calendar.current.isDate(startDay, inSameDayAs: home) {
                        store.move([request.note.id], from: home, to: startDay)
                    }
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
                ForEach(Self.dayOffsets, id: \.self) { offset in
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
        let samples = locationHistory.samples(on: pageDay)
        let notes = store.notes(on: pageDay)
        let hasMapContent = !samples.isEmpty || notes.contains { $0.mapLocation != nil }

        return List {
            if hasMapContent {
                DayPathBackdrop(samples: samples, notes: notes) { note in
                    isCreatingNote = false
                    editingNote = note
                }
                    .aspectRatio(1, contentMode: .fit)
                    .dayScrollDepthTransition()
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            header(for: pageDay)
                .dayScrollDepthTransition()
                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 6, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(notes) { note in
                // No insets: the row is exactly the card, so a press and hold
                // lifts the card itself rather than a wider strip around it.
                noteRow(note, on: pageDay)
                    .dayScrollDepthTransition()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            newNoteArea
                .dayScrollDepthTransition()
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
        .scrollBounceBehavior(.always, axes: .vertical)
        .environment(\.defaultMinListRowHeight, 0)
        .task(id: pageDay) {
            store.ensureMapSymbols(on: pageDay)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.wispr(17, weight: .semibold))
                    Text(backTitle)
                        .font(.wispr(17))
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
                .font(.wispr(34, weight: .semibold, role: .header))
                .foregroundStyle(.white)

            Text(DayFormat.dateSubtitle(for: pageDay))
                .font(.wispr(15, role: .header))
                .foregroundStyle(Color.wisprSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noteRow(_ note: Note, on pageDay: Date) -> some View {
        NoteCard(
            note: note,
            day: store.storedDay(of: note.id) ?? pageDay,
            isSelecting: isSelecting,
            isSelected: selectedNoteIDs.contains(note.id),
            onToggle: { block in
                withAnimation(.snappy) {
                    store.toggleChecklistItem(block.id, inNote: note.id, on: pageDay)
                }
            },
            onEdit: {
                isCreatingNote = false
                editingNote = note
            },
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
                .font(.wispr(14))
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
        .font(.wispr(17))
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
                .font(.wispr(19))
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
        isCreatingNote = true
        editingNote = Note(
            blocks: [NoteBlock()],
            location: locationHistory.locationForNewNote()
        )
    }

    /// Pages back to today and opens a blank note there, whatever the day view
    /// was doing beforehand.
    private func composeNewNoteForToday() {
        withAnimation(.snappy) {
            isSelecting = false
            selectedNoteIDs = []
            visibleDayOffset = 0
        }

        isCreatingNote = true
        editingNote = Note(
            blocks: [NoteBlock()],
            location: locationHistory.locationForNewNote()
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

// MARK: - Day scrolling and map

private struct DayScrollDepthTransition: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollTransition(.interactive(timingCurve: .easeOut), axis: .vertical) { content, phase in
            content
                .blur(radius: 7 * max(0, -phase.value))
                .opacity(1 - 0.45 * max(0, -phase.value))
                .scaleEffect(1 - 0.035 * max(0, -phase.value), anchor: .bottom)
        }
    }
}

private extension View {
    func dayScrollDepthTransition() -> some View {
        modifier(DayScrollDepthTransition())
    }
}

private struct DayPathBackdrop: View {
    let samples: [LocationSample]
    let notes: [Note]
    let onOpenNote: (Note) -> Void

    @State private var route: DayRouteGeometry

    init(samples: [LocationSample], notes: [Note], onOpenNote: @escaping (Note) -> Void) {
        self.samples = samples
        self.notes = notes
        self.onOpenNote = onOpenNote
        _route = State(
            initialValue: DayRouteGeometry(
                samples: samples,
                additionalCoordinates: notes.compactMap(\.mapLocation).map(\.coordinate)
            )
        )
    }

    private var theme: WisprThemeKind { AppSettings.shared.theme }

    private var mapInk: Color {
        switch theme {
        case .standard: Color(red: 0.78, green: 0.80, blue: 0.84)
        case .legacy: .white
        }
    }

    private var mapBase: Color {
        switch theme {
        case .standard: Color(red: 0.16, green: 0.16, blue: 0.18)
        case .legacy: .black
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                mapBase

                DayMapSnapshot(region: route.region)
                    .saturation(0)
                    .contrast(1.28)
                    .colorMultiply(mapInk)
                    .opacity(0.95)

                mapBase.opacity(0.05)

                RouteSilhouette(coordinates: route.coordinates, region: route.region)
                    .stroke(
                        mapInk.opacity(0.58),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
                    )
                    .blur(radius: 7)

                RouteSilhouette(coordinates: route.coordinates, region: route.region)
                    .stroke(
                        mapInk.opacity(0.92),
                        style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round)
                    )

                if let coordinate = route.coordinates.last {
                    LocationMapDot(ink: mapInk, base: mapBase)
                        .position(project(coordinate, in: proxy.size))
                        .allowsHitTesting(false)
                }

                ForEach(notesWithLocations) { note in
                    if let coordinate = note.mapLocation?.coordinate {
                        Button {
                            onOpenNote(note)
                        } label: {
                            Image(systemName: note.mapSymbol ?? "note.text")
                                .font(.wispr(13, weight: .semibold))
                                .foregroundStyle(mapBase)
                                .frame(width: 34, height: 34)
                                .background(mapInk.opacity(0.94), in: Circle())
                                .overlay {
                                    Circle().stroke(mapBase.opacity(0.55), lineWidth: 1)
                                }
                                .shadow(color: mapInk.opacity(0.45), radius: 8)
                        }
                        .buttonStyle(.plain)
                        .position(annotationPosition(for: note, at: coordinate, in: proxy.size))
                        .accessibilityLabel("Open \(note.summaryLine)")
                    }
                }
            }
        }
        .mask {
            GeometryReader { proxy in
                RadialGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.68),
                        .init(color: .white.opacity(0.55), location: 0.84),
                        .init(color: .clear, location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: min(proxy.size.width, proxy.size.height) / 2
                )
            }
        }
        .overlay {
            Circle()
                .stroke(mapInk.opacity(0.08), lineWidth: 1)
                .blur(radius: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: mapInk.opacity(0.12), radius: 18)
        .task(id: routeRequestID) {
            if let cached = DayRouteCache.shared.route(for: routeRequestID) {
                route = cached
                return
            }

            let resolved = await DayRouteGeometry.roadAligned(
                samples: samples,
                additionalCoordinates: notesWithLocations.compactMap(\.mapLocation).map(\.coordinate)
            )
            guard !Task.isCancelled else { return }
            DayRouteCache.shared.insert(resolved, for: routeRequestID)
            route = resolved
        }
    }

    private func project(_ coordinate: CLLocationCoordinate2D, in size: CGSize) -> CGPoint {
        let latitudeDelta = max(route.region.span.latitudeDelta, 0.000_001)
        let longitudeDelta = max(route.region.span.longitudeDelta, 0.000_001)
        let minimumLatitude = route.region.center.latitude - latitudeDelta / 2
        let minimumLongitude = route.region.center.longitude - longitudeDelta / 2

        return CGPoint(
            x: ((coordinate.longitude - minimumLongitude) / longitudeDelta) * size.width,
            y: (1 - (coordinate.latitude - minimumLatitude) / latitudeDelta) * size.height
        )
    }

    private func annotationPosition(
        for note: Note,
        at coordinate: CLLocationCoordinate2D,
        in size: CGSize
    ) -> CGPoint {
        let base = project(coordinate, in: size)
        guard let index = notesWithLocations.firstIndex(where: { $0.id == note.id }), index > 0 else {
            return base
        }
        let angle = Double(index) * 2.399_963
        let radius = CGFloat(20 + min(index, 3) * 6)
        return CGPoint(
            x: base.x + cos(angle) * radius,
            y: base.y + sin(angle) * radius
        )
    }

    private var routeRequestID: String {
        var components = [String(samples.count)]
        if let first = samples.first, let last = samples.last {
            components.append(contentsOf: [
                first.latitude.formatted(.number.precision(.fractionLength(5))),
                first.longitude.formatted(.number.precision(.fractionLength(5))),
                last.latitude.formatted(.number.precision(.fractionLength(5))),
                last.longitude.formatted(.number.precision(.fractionLength(5))),
                last.timestamp.timeIntervalSinceReferenceDate.formatted(.number.precision(.fractionLength(0)))
            ])
        }
        for note in notesWithLocations {
            guard let location = note.mapLocation else { continue }
            components.append(note.id.uuidString)
            components.append(location.latitude.formatted(.number.precision(.fractionLength(5))))
            components.append(location.longitude.formatted(.number.precision(.fractionLength(5))))
        }
        return components.joined(separator: ":")
    }

    private var notesWithLocations: [Note] {
        notes.filter { $0.mapLocation != nil }
    }
}

// MARK: - Map rendering

private struct DayRouteGeometry {
    let coordinates: [CLLocationCoordinate2D]
    let region: MKCoordinateRegion

    init(samples: [LocationSample], additionalCoordinates: [CLLocationCoordinate2D] = []) {
        self.init(
            coordinates: samples.map(\.coordinate),
            additionalCoordinates: additionalCoordinates
        )
    }

    init(
        coordinates: [CLLocationCoordinate2D],
        additionalCoordinates: [CLLocationCoordinate2D] = []
    ) {
        self.coordinates = coordinates

        let framingCoordinates = coordinates + additionalCoordinates
        let latitudes = framingCoordinates.map(\.latitude)
        let longitudes = framingCoordinates.map(\.longitude)
        let minimumLatitude = latitudes.min() ?? 0
        let maximumLatitude = latitudes.max() ?? 0
        let minimumLongitude = longitudes.min() ?? 0
        let maximumLongitude = longitudes.max() ?? 0

        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minimumLatitude + maximumLatitude) / 2,
                longitude: (minimumLongitude + maximumLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maximumLatitude - minimumLatitude) * 2.2, 0.012),
                longitudeDelta: max((maximumLongitude - minimumLongitude) * 2.2, 0.012)
            )
        )
    }

    /// Significant-change monitoring deliberately leaves wide gaps. Ask
    /// MapKit for road geometry only across those gaps; already-dense trails
    /// keep their recorded shape and require no routing work.
    static func roadAligned(
        samples: [LocationSample],
        additionalCoordinates: [CLLocationCoordinate2D]
    ) async -> DayRouteGeometry {
        guard let first = samples.first else {
            return DayRouteGeometry(samples: samples, additionalCoordinates: additionalCoordinates)
        }

        var coordinates = [first.coordinate]
        var routingRequests = 0

        for (start, end) in zip(samples, samples.dropFirst()) {
            guard !Task.isCancelled else { break }
            let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))

            if distance >= 2_000,
               distance <= 350_000,
               routingRequests < 8,
               let roadCoordinates = await roadCoordinates(from: start.coordinate, to: end.coordinate) {
                coordinates.append(contentsOf: roadCoordinates.dropFirst())
                routingRequests += 1
            } else {
                coordinates.append(end.coordinate)
            }
        }

        return DayRouteGeometry(
            coordinates: coordinates,
            additionalCoordinates: additionalCoordinates
        )
    }

    private static func roadCoordinates(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(
            location: CLLocation(latitude: source.latitude, longitude: source.longitude),
            address: nil
        )
        request.destination = MKMapItem(
            location: CLLocation(latitude: destination.latitude, longitude: destination.longitude),
            address: nil
        )
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        guard let polyline = try? await MKDirections(request: request).calculate().routes.first?.polyline else {
            return nil
        }
        var coordinates = Array(
            repeating: CLLocationCoordinate2D(),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }
}

@MainActor
private final class DayRouteCache {
    static let shared = DayRouteCache()

    private var routes: [String: DayRouteGeometry] = [:]
    private var order: [String] = []

    func route(for key: String) -> DayRouteGeometry? {
        routes[key]
    }

    func insert(_ route: DayRouteGeometry, for key: String) {
        routes[key] = route
        order.removeAll { $0 == key }
        order.append(key)

        if order.count > 12 {
            routes.removeValue(forKey: order.removeFirst())
        }
    }
}

private struct DayMapSnapshot: View {
    let region: MKCoordinateRegion

    @State private var snapshot: MKMapSnapshotter.Snapshot?

    var body: some View {
        ZStack {
            // A concrete surface keeps this view alive while MapKit renders.
            // An empty conditional can collapse before its task returns.
            Color.clear

            if let snapshot {
                snapshotImage(snapshot)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()
        .task(id: requestID) {
            if let cached = DayMapSnapshotCache.shared.snapshot(for: requestID) {
                snapshot = cached
                return
            }

            guard let rendered = await makeSnapshot(), !Task.isCancelled else { return }
            DayMapSnapshotCache.shared.insert(rendered, for: requestID)
            snapshot = rendered
        }
    }

    @ViewBuilder
    private func snapshotImage(_ snapshot: MKMapSnapshotter.Snapshot) -> Image {
        #if canImport(UIKit)
        Image(uiImage: snapshot.image)
        #elseif canImport(AppKit)
        Image(nsImage: snapshot.image)
        #endif
    }

    private var requestID: String {
        [
            region.center.latitude,
            region.center.longitude,
            region.span.latitudeDelta,
            region.span.longitudeDelta
        ]
        .map { $0.formatted(.number.precision(.fractionLength(6))) }
        .joined(separator: ":")
    }

    private func makeSnapshot() async -> MKMapSnapshotter.Snapshot? {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: 768, height: 768)

        let configuration = MKStandardMapConfiguration(
            elevationStyle: .flat,
            emphasisStyle: .muted
        )
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        options.preferredConfiguration = configuration

        #if canImport(UIKit)
        options.scale = 2
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        #elseif canImport(AppKit)
        options.appearance = NSAppearance(named: .darkAqua)
        #endif

        let snapshotter = MKMapSnapshotter(options: options)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                snapshotter.start { snapshot, _ in
                    continuation.resume(returning: snapshot)
                }
            }
        } onCancel: {
            snapshotter.cancel()
        }
    }
}

@MainActor
private final class DayMapSnapshotCache {
    static let shared = DayMapSnapshotCache()

    private let cache: NSCache<NSString, MKMapSnapshotter.Snapshot>

    private init() {
        cache = NSCache()
        cache.countLimit = 12
    }

    func snapshot(for key: String) -> MKMapSnapshotter.Snapshot? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ snapshot: MKMapSnapshotter.Snapshot, for key: String) {
        cache.setObject(snapshot, forKey: key as NSString)
    }
}

private struct LocationMapDot: View {
    let ink: Color
    let base: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(base.opacity(0.92))
                .frame(width: 22, height: 22)
                .overlay { Circle().stroke(ink.opacity(0.62), lineWidth: 1) }
                .shadow(color: ink.opacity(0.35), radius: 8)

            Circle()
                .fill(ink)
                .frame(width: 6, height: 6)
        }
    }
}

private struct RouteSilhouette: Shape {
    let coordinates: [CLLocationCoordinate2D]
    let region: MKCoordinateRegion

    func path(in rect: CGRect) -> Path {
        guard !coordinates.isEmpty else { return Path() }

        let latitudeRange = max(region.span.latitudeDelta, 0.000_001)
        let longitudeRange = max(region.span.longitudeDelta, 0.000_001)
        let minimumLatitude = region.center.latitude - latitudeRange / 2
        let minimumLongitude = region.center.longitude - longitudeRange / 2

        func point(for coordinate: CLLocationCoordinate2D) -> CGPoint {
            let normalizedX = (coordinate.longitude - minimumLongitude) / longitudeRange
            let normalizedY = (coordinate.latitude - minimumLatitude) / latitudeRange
            return CGPoint(
                x: rect.minX + normalizedX * rect.width,
                y: rect.maxY - normalizedY * rect.height
            )
        }

        var path = Path()
        path.move(to: point(for: coordinates[0]))
        for coordinate in coordinates.dropFirst() {
            path.addLine(to: point(for: coordinate))
        }

        if coordinates.count == 1 {
            let center = point(for: coordinates[0])
            path.addEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
        }
        return path
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
        HStack(spacing: 6) {
            Text(createdCaption)

            if note.location != nil {
                Image(systemName: "location.fill")
                    .accessibilityLabel("Location attached")
            }
        }
            .font(.wispr(11).italic())
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
                .font(.wispr(20))
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
                .font(.wispr(17, role: .note))
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
            .font(.wispr(17, role: .note))
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
                                .font(.wispr(22, weight: .semibold))
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
                    .font(.wispr(17, role: .note))
                    .foregroundStyle(isChecked ? Color.white.opacity(0.45) : Color.white.opacity(0.7))

                Text(block.text)
                    .font(.wispr(17, role: .note))
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
        heading.font = .wispr(22, weight: .semibold)

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

#if DEBUG
#Preview("Several notes") {
    AppSettings.preview()

    return DayView()
        .environment(NoteStore.previewSeeded())
        .environment(LocationHistory())
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
        .environment(LocationHistory())
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
        .environment(LocationHistory())
        .preferredColorScheme(.dark)
}

#Preview("Legacy theme") {
    AppSettings.preview(theme: .legacy)

    return DayView()
        .environment(NoteStore.previewSeeded())
        .environment(LocationHistory())
        .preferredColorScheme(.dark)
}
#endif
