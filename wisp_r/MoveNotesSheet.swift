import SwiftUI

/// Picks the day a note, or a batch of selected notes, should move to. What is
/// already on the chosen day is listed underneath the calendar, so a day is
/// never moved into blind.
struct MoveNotesSheet: View {
    let noteCount: Int
    let onMove: (Date) -> Void

    /// Notes being moved, so they aren't also listed as already being there.
    private let movingIDs: Set<UUID>

    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var destination: Date

    init(
        noteCount: Int,
        startingFrom day: Date,
        moving movingIDs: Set<UUID> = [],
        onMove: @escaping (Date) -> Void
    ) {
        self.noteCount = noteCount
        self.movingIDs = movingIDs
        self.onMove = onMove
        _destination = State(initialValue: day)
    }

    private var chosenDay: Date { Calendar.current.startOfDay(for: destination) }

    private var notesOnChosenDay: [Note] {
        store.notes(on: chosenDay).filter { !movingIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DatePicker(
                        "Move to",
                        selection: $destination,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .tint(Color.wisprInk)

                    dayPreview
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WisprBackground())
            .navigationTitle(Text("Move ^[\(noteCount) note](inflect: true)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Move") {
                        onMove(chosenDay)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .wisprSheetEdge()
        .preferredColorScheme(.dark)
    }

    // MARK: - What is already there

    private var dayPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DayFormat.relativeTitle(for: chosenDay))
                    .font(.wispr(17, weight: .semibold))
                    .foregroundStyle(Color.wisprInk)

                Text(DayFormat.dateSubtitle(for: chosenDay))
                    .font(.wispr(13))
                    .foregroundStyle(Color.wisprSecondaryText)
            }

            if notesOnChosenDay.isEmpty {
                Text("Nothing on this day yet.")
                    .font(.wispr(15))
                    .foregroundStyle(Color.wisprSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(notesOnChosenDay.enumerated(), id: \.element.id) { index, note in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.wisprSeparator)
                                .frame(height: 1)
                                .padding(.leading, 42)
                        }

                        NoteSummaryRow(
                            note: note,
                            day: store.storedDay(of: note.id) ?? chosenDay
                        )
                    }
                }
                .wisprCardBackground()
            }
        }
        .padding(.horizontal, 8)
        .animation(.snappy, value: chosenDay)
    }
}

// MARK: - Summary row

/// One note reduced to a line, for listing a day without drawing its cards.
struct NoteSummaryRow: View {
    let note: Note
    let day: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: note.previewSymbol)
                .font(.wispr(14))
                .foregroundStyle(Color.wisprInk.opacity(0.55))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(note.summaryLine)
                    .font(.wispr(15))
                    .foregroundStyle(Color.wisprInk)
                    .lineLimit(1)

                if let schedule = note.schedule {
                    Text(schedule.summary(on: day))
                        .font(.wispr(12))
                        .foregroundStyle(Color.wisprSecondaryText)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

#if DEBUG
#Preview {
    MoveNotesSheet(noteCount: 3, startingFrom: .now) { _ in }
        .environment(NoteStore.previewSeeded())
}
#endif
