import MapKit
import SwiftUI

/// Gives a note a time: either a span, which makes it a calendar event, or a
/// single time it is due by.
///
/// Events can be all day, and they can run past the day they start. The day
/// handed back with the schedule is the day the note should be stored on — the
/// event's first day, or the note's current day when the time is cleared or it
/// is only due by then.
struct NoteScheduleSheet: View {
    let note: Note
    let day: Date
    /// `schedule` is `nil` when the time is being cleared.
    let onSave: (NoteSchedule?, Date) -> Void

    private enum Kind: Hashable, CaseIterable {
        case event
        case due

        var title: String {
            switch self {
            case .event: "Event"
            case .due: "Due by"
            }
        }
    }

    @State private var kind: Kind
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var due: Date
    @State private var eventLocation: String
    @State private var isResolvingLocation = false
    /// Set while snapping between all-day and timed, so that snap isn't also
    /// treated as the user dragging the start along.
    @State private var isAdjustingTimes = false

    @Environment(\.dismiss) private var dismiss

    /// Opens on the note's current time, or on sensible defaults: the next hour
    /// for an event, and the end of the day for something due.
    init(note: Note, day: Date, onSave: @escaping (NoteSchedule?, Date) -> Void) {
        self.note = note
        self.day = day
        self.onSave = onSave

        let schedule = note.schedule
        let defaultStart = Self.nextHour(on: day)
        let isEvent = schedule?.isEvent == true

        _kind = State(initialValue: schedule?.isEvent == false ? .due : .event)
        _isAllDay = State(initialValue: schedule?.isAllDay == true)
        _start = State(initialValue: isEvent ? schedule?.start(on: day) ?? defaultStart : defaultStart)
        _end = State(
            initialValue: isEvent
                ? schedule?.editorEnd(on: day) ?? defaultStart.addingTimeInterval(AppSettings.shared.eventLength)
                : defaultStart.addingTimeInterval(AppSettings.shared.eventLength)
        )
        _due = State(
            initialValue: schedule?.isEvent == false
                ? (schedule?.start(on: day) ?? Self.latestDue(on: day))
                : Self.latestDue(on: day)
        )
        _eventLocation = State(initialValue: schedule?.eventLocation ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(DayFormat.dateSubtitle(for: day))
                        .font(.wispr(13))
                        .foregroundStyle(Color.wisprSecondaryText)

                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch kind {
                    case .event: eventTimes
                    case .due: dueTime
                    }

                    if note.schedule != nil {
                        Button(role: .destructive) {
                            onSave(nil, day)
                            dismiss()
                        } label: {
                            Label("Remove time", systemImage: "clock.badge.xmark")
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .wisprCardBackground()
                    }

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WisprBackground())
            .navigationTitle("Set time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Set") {
                        Task { await confirm() }
                    }
                        .fontWeight(.semibold)
                        .disabled(isResolvingLocation)
                }
            }
        }
        .tint(Color.wisprInk)
        .presentationDetents([.medium, .large])
        .wisprSheetEdge()
        .preferredColorScheme(.dark)
    }

    // MARK: - Times

    private var eventTimes: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                allDayRow

                separator

                timeRow("Starts", selection: startSelection, components: eventComponents)

                separator

                timeRow(
                    "Ends",
                    selection: endSelection,
                    components: eventComponents,
                    in: endLowerBound...endUpperBound
                )
            }
            .wisprCardBackground()
            .onChange(of: isAllDay) { _, allDay in
                isAdjustingTimes = true
                let calendar = Calendar.current
                if allDay {
                    start = calendar.startOfDay(for: start)
                    let endDay = calendar.startOfDay(for: end)
                    end = endDay < start ? start : endDay
                } else {
                    let endDay = calendar.startOfDay(for: end)
                    start = NoteSchedule.date(atMinute: 9 * 60, on: start)
                    if calendar.isDate(start, inSameDayAs: endDay) {
                        end = start.addingTimeInterval(AppSettings.shared.eventLength)
                    } else {
                        end = NoteSchedule.date(atMinute: 17 * 60, on: endDay)
                    }
                }
                isAdjustingTimes = false
            }

            locationRow
                .wisprCardBackground()

            caption(durationCaption)
        }
    }

    private var dueTime: some View {
        VStack(alignment: .leading, spacing: 8) {
            timeRow(
                "Due by",
                selection: $due,
                components: .hourAndMinute,
                in: startOfDay...Self.latestDue(on: day)
            )
            .wisprCardBackground()

            caption("A note can be due any time up to 9:00 PM.")
        }
    }

    private var allDayRow: some View {
        HStack {
            Text("All day")
                .font(.wispr(17))
                .foregroundStyle(Color.wisprInk)
                .accessibilityHidden(true)

            Spacer()

            Toggle("All day", isOn: $isAllDay)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.wisprSeparator)
            .frame(height: 1)
            .padding(.leading, 16)
    }

    private var locationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(Color.wisprSecondaryText)

            TextField("Add location", text: $eventLocation)
                .font(.wispr(17))
                .foregroundStyle(Color.wisprInk)
                .submitLabel(.done)

            if !eventLocation.isEmpty {
                Button {
                    eventLocation = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.wisprSecondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear event location")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.wispr(13))
            .foregroundStyle(Color.wisprSecondaryText)
            .padding(.horizontal, 4)
    }

    private func timeRow(
        _ title: String,
        selection: Binding<Date>,
        components: DatePickerComponents,
        in range: ClosedRange<Date>? = nil
    ) -> some View {
        HStack {
            Text(title)
                .font(.wispr(17))
                .foregroundStyle(Color.wisprInk)

            Spacer(minLength: 12)

            if let range {
                DatePicker(title, selection: selection, in: range, displayedComponents: components)
                    .labelsHidden()
            } else {
                DatePicker(title, selection: selection, displayedComponents: components)
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    /// Dragging the start along keeps the event the same length.
    private var startSelection: Binding<Date> {
        Binding(
            get: { start },
            set: { newValue in
                let oldValue = start
                start = newValue
                guard !isAdjustingTimes else { return }
                var shifted = end.addingTimeInterval(newValue.timeIntervalSince(oldValue))
                if shifted < newValue {
                    shifted = isAllDay ? newValue : newValue.addingTimeInterval(60)
                }
                end = shifted
            }
        )
    }

    /// The picker refuses a selection outside its range, so the end never reads
    /// as earlier than the start for the frame in which the start moves.
    private var endSelection: Binding<Date> {
        Binding(
            get: { max(end, endLowerBound) },
            set: { end = max($0, endLowerBound) }
        )
    }

    private var eventComponents: DatePickerComponents {
        isAllDay ? .date : [.date, .hourAndMinute]
    }

    private var durationCaption: String {
        if isAllDay {
            let days = spanDays
            return days == 1 ? "Lasts 1 day" : "Lasts \(days) days"
        }
        let seconds = max(end.timeIntervalSince(start), 60)
        return "Lasts \(Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide)))"
    }

    private var spanDays: Int {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: max(end, start))
        return max(0, calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0) + 1
    }

    // MARK: - Bounds

    private var startOfDay: Date { Calendar.current.startOfDay(for: day) }

    private var endLowerBound: Date {
        isAllDay ? Calendar.current.startOfDay(for: start) : start
    }

    private var endUpperBound: Date {
        Calendar.current.date(byAdding: .year, value: 2, to: start) ?? start.addingTimeInterval(86_400 * 365)
    }

    private static func latestDue(on day: Date) -> Date {
        NoteSchedule.date(atMinute: NoteSchedule.latestDueMinute, on: day)
    }

    /// The top of the next hour, or the last hour of the day if it is nearly over.
    private static func nextHour(on day: Date) -> Date {
        let calendar = Calendar.current
        let reference = calendar.isDateInToday(day) ? Date.now : calendar.startOfDay(for: day)
        let hour = calendar.component(.hour, from: reference)
        return NoteSchedule.date(atMinute: min(hour + 1, 23) * 60, on: day)
    }

    // MARK: - Saving

    private func confirm() async {
        let calendar = Calendar.current
        isResolvingLocation = true
        let eventCoordinate = kind == .event ? await resolvedEventCoordinate() : nil
        defer { isResolvingLocation = false }

        switch kind {
        case .event:
            let startDay = calendar.startOfDay(for: start)
            if isAllDay {
                let last = calendar.startOfDay(for: max(end, start))
                let offset = max(0, calendar.dateComponents([.day], from: startDay, to: last).day ?? 0)
                onSave(
                    NoteSchedule(
                        startMinute: 0,
                        endDayOffset: offset,
                        isAllDay: true,
                        eventLocation: eventLocation,
                        eventLatitude: eventCoordinate?.latitude,
                        eventLongitude: eventCoordinate?.longitude
                    ),
                    startDay
                )
            } else {
                let endDay = calendar.startOfDay(for: max(end, start))
                var offset = max(0, calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0)
                let startMinute = NoteSchedule.minute(of: start)
                var endMinute = NoteSchedule.minute(of: end)
                if offset == 0 {
                    endMinute = max(endMinute, startMinute + 1)
                    if endMinute >= 24 * 60 {
                        endMinute = 0
                        offset = 1
                    }
                }
                onSave(
                    NoteSchedule(
                        startMinute: startMinute,
                        endMinute: endMinute,
                        endDayOffset: offset,
                        eventLocation: eventLocation,
                        eventLatitude: eventCoordinate?.latitude,
                        eventLongitude: eventCoordinate?.longitude
                    ),
                    startDay
                )
            }

        case .due:
            let minute = min(NoteSchedule.minute(of: due), NoteSchedule.latestDueMinute)
            onSave(NoteSchedule(startMinute: minute), day)
        }

        dismiss()
    }

    private func resolvedEventCoordinate() async -> CLLocationCoordinate2D? {
        let location = eventLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { return nil }

        if location == note.schedule?.eventLocation,
           let latitude = note.schedule?.eventLatitude,
           let longitude = note.schedule?.eventLongitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        let request = MKLocalSearch.Request(naturalLanguageQuery: location)
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        return response.mapItems.first?.location.coordinate
    }
}

// MARK: - Schedule label

/// A note's time, shown on its card.
struct NoteScheduleLabel: View {
    let schedule: NoteSchedule
    let day: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(schedule.summary(on: day), systemImage: schedule.isEvent ? "calendar" : "clock")
                .font(.wispr(13, weight: .medium))

            if let location = schedule.eventLocation, schedule.isEvent {
                Label(location, systemImage: "mappin")
                    .font(.wispr(12, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color.wisprInk.opacity(0.75))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.wisprInk.opacity(0.08))
        .clipShape(Capsule())
    }
}

#if DEBUG
#Preview("New event") {
    NoteScheduleSheet(
        note: Note(blocks: [NoteBlock(text: "Dentist")]),
        day: .now
    ) { _, _ in }
}

#Preview("All-day event") {
    NoteScheduleSheet(
        note: Note(
            blocks: [NoteBlock(text: "Trip")],
            schedule: NoteSchedule(startMinute: 0, endDayOffset: 2, isAllDay: true)
        ),
        day: .now
    ) { _, _ in }
}

#Preview("Existing due time") {
    NoteScheduleSheet(
        note: Note(
            blocks: [NoteBlock(text: "Send the invoice")],
            schedule: NoteSchedule(startMinute: 17 * 60, endMinute: nil)
        ),
        day: .now
    ) { _, _ in }
}
#endif
