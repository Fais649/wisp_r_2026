import SwiftUI

/// Gives a note a time on its day: either a span, which makes it a calendar
/// event, or a single time it is due by.
struct NoteScheduleSheet: View {
    let note: Note
    let day: Date
    /// `nil` clears the note's time.
    let onSave: (NoteSchedule?) -> Void

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
    @State private var start: Date
    @State private var end: Date
    @State private var due: Date

    @Environment(\.dismiss) private var dismiss

    /// Opens on the note's current time, or on sensible defaults: the next hour
    /// for an event, and the end of the day for something due.
    init(note: Note, day: Date, onSave: @escaping (NoteSchedule?) -> Void) {
        self.note = note
        self.day = day
        self.onSave = onSave

        let schedule = note.schedule
        let defaultStart = Self.nextHour(on: day)

        _kind = State(initialValue: schedule?.isEvent == false ? .due : .event)
        _start = State(initialValue: schedule?.start(on: day) ?? defaultStart)
        _end = State(
            initialValue: schedule?.end(on: day)
                ?? defaultStart.addingTimeInterval(3600)
        )
        _due = State(
            initialValue: schedule?.isEvent == false
                ? (schedule?.start(on: day) ?? Self.latestDue(on: day))
                : Self.latestDue(on: day)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(DayFormat.dateSubtitle(for: day))
                        .font(.system(size: 13))
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
                            onSave(nil)
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
                    Button("Set", action: confirm)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(.white)
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    // MARK: - Times

    private var eventTimes: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                timeRow("Starts", selection: $start)

                Rectangle()
                    .fill(Color.wisprSeparator)
                    .frame(height: 1)
                    .padding(.leading, 16)

                timeRow("Ends", selection: $end, in: start...endOfDay)
            }
            .wisprCardBackground()
            // Dragging the start along keeps the event the same length; its
            // range then stops the end landing before the start.
            .onChange(of: start) { oldValue, newValue in
                end = end.addingTimeInterval(newValue.timeIntervalSince(oldValue))
            }

            caption(durationCaption)
        }
    }

    private var dueTime: some View {
        VStack(alignment: .leading, spacing: 8) {
            timeRow("Due by", selection: $due, in: startOfDay...Self.latestDue(on: day))
                .wisprCardBackground()

            caption("A note can be due any time up to 9:00 PM.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.wisprSecondaryText)
            .padding(.horizontal, 4)
    }

    private func timeRow(
        _ title: String,
        selection: Binding<Date>,
        in range: ClosedRange<Date>? = nil
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(.white)

            Spacer()

            if let range {
                DatePicker(title, selection: selection, in: range, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            } else {
                DatePicker(title, selection: selection, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var durationCaption: String {
        let minutes = max(NoteSchedule.minute(of: end) - NoteSchedule.minute(of: start), 0)
        return "Lasts \(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide)))"
    }

    // MARK: - Bounds

    private var startOfDay: Date { Calendar.current.startOfDay(for: day) }

    /// One minute short of midnight, so an event can run to the end of the day.
    private var endOfDay: Date {
        NoteSchedule.date(atMinute: 24 * 60 - 1, on: day)
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

    private func confirm() {
        switch kind {
        case .event:
            let startMinute = NoteSchedule.minute(of: start)
            // At least a minute long, so it always reads as a span.
            let endMinute = max(NoteSchedule.minute(of: end), startMinute + 1)
            onSave(NoteSchedule(startMinute: startMinute, endMinute: endMinute))

        case .due:
            let minute = min(NoteSchedule.minute(of: due), NoteSchedule.latestDueMinute)
            onSave(NoteSchedule(startMinute: minute, endMinute: nil))
        }

        dismiss()
    }
}

// MARK: - Schedule label

/// A note's time, shown on its card.
struct NoteScheduleLabel: View {
    let schedule: NoteSchedule
    let day: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: schedule.isEvent ? "calendar" : "clock")
                .font(.system(size: 12, weight: .medium))

            Text(schedule.summary(on: day))
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(Color.white.opacity(0.75))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }
}

#Preview("New event") {
    NoteScheduleSheet(
        note: Note(blocks: [NoteBlock(text: "Dentist")]),
        day: .now
    ) { _ in }
}

#Preview("Existing due time") {
    NoteScheduleSheet(
        note: Note(
            blocks: [NoteBlock(text: "Send the invoice")],
            schedule: NoteSchedule(startMinute: 17 * 60, endMinute: nil)
        ),
        day: .now
    ) { _ in }
}
