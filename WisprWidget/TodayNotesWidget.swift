import SwiftUI
import WidgetKit

private enum WidgetBridge {
    static let appGroup = "group.com.punksys.wispr"
    static let filename = "TodayWidgetSnapshot.json"
    static let kind = "TodayNotesWidget"
}

private struct WidgetSnapshot: Decodable {
    let notesByDay: [String: [WidgetNote]]
}

private struct WidgetNote: Decodable, Identifiable {
    let id: UUID
    let text: String
    let schedule: String?
    let imageCount: Int
    let voiceMemoCount: Int
}

private struct TodayNotesEntry: TimelineEntry {
    let date: Date
    let notes: [WidgetNote]
}

private struct TodayNotesProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayNotesEntry {
        TodayNotesEntry(date: .now, notes: Self.previewNotes)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayNotesEntry) -> Void) {
        completion(
            TodayNotesEntry(
                date: .now,
                notes: context.isPreview ? Self.previewNotes : Self.loadNotes(for: .now)
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayNotesEntry>) -> Void) {
        let now = Date.now
        let entry = TodayNotesEntry(date: now, notes: Self.loadNotes(for: now))
        completion(Timeline(entries: [entry], policy: .after(Self.nextMidnight(after: now))))
    }

    private static func loadNotes(for date: Date) -> [WidgetNote] {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetBridge.appGroup
        ),
        let data = try? Data(contentsOf: container.appending(path: WidgetBridge.filename)),
        let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return [] }

        return snapshot.notesByDay[dayKey(for: date)] ?? []
    }

    private static func dayKey(for day: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    private static func nextMidnight(after date: Date) -> Date {
        let start = Calendar.current.startOfDay(for: date)
        return (Calendar.current.date(byAdding: .day, value: 1, to: start) ?? date)
            .addingTimeInterval(5)
    }

    static let previewNotes = [
        WidgetNote(
            id: UUID(),
            text: "Sketch the Today widget\n○  Test long notes on a small phone",
            schedule: "Due by 11:30 AM",
            imageCount: 2,
            voiceMemoCount: 0
        ),
        WidgetNote(
            id: UUID(),
            text: "Dinner ideas for the weekend",
            schedule: nil,
            imageCount: 0,
            voiceMemoCount: 1
        ),
        WidgetNote(
            id: UUID(),
            text: "✓  Send the updated build",
            schedule: nil,
            imageCount: 0,
            voiceMemoCount: 0
        )
    ]
}

private struct TodayNotesWidgetView: View {
    let entry: TodayNotesEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if entry.notes.isEmpty {
                emptyState
            } else {
                ViewThatFits(in: .vertical) {
                    noteList(limit: 8)
                    noteList(limit: 7)
                    noteList(limit: 6)
                    noteList(limit: 5)
                    noteList(limit: 4)
                    noteList(limit: 3)
                    noteList(limit: 2)
                    noteList(limit: 1)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(18)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.27, green: 0.27, blue: 0.28),
                    Color(red: 0.19, green: 0.185, blue: 0.195)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .widgetURL(URL(string: "wispr://today"))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 9) {
                WidgetLogo()
                    .frame(width: 18, height: 18)

                Text("Today")
                    .font(.system(size: 22, weight: .semibold))
            }

            Spacer()

            Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Text("Nothing written down yet")
                .font(.system(size: 17, weight: .medium))
            Text("Open Wispr to add a note for today.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func noteList(limit: Int) -> some View {
        let shown = Array(entry.notes.prefix(limit))
        let overflow = max(0, entry.notes.count - shown.count)

        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, note in
                if index > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.09))
                        .frame(height: 1)
                }

                noteRow(note)
            }

            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
    }

    private func noteRow(_ note: WidgetNote) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(note.text)
                .font(.system(size: 15, weight: .regular))
                .lineSpacing(2)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if note.schedule != nil || note.imageCount > 0 || note.voiceMemoCount > 0 {
                HStack(spacing: 12) {
                    if let schedule = note.schedule {
                        Label(schedule, systemImage: "clock")
                    }
                    if note.imageCount > 0 {
                        Label("\(note.imageCount)", systemImage: "photo")
                    }
                    if note.voiceMemoCount > 0 {
                        Label("\(note.voiceMemoCount)", systemImage: "waveform")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.46))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct WidgetLogo: View {
    var body: some View {
        GeometryReader { proxy in
            let cell = proxy.size.width * 0.42
            let gap = proxy.size.width - cell * 2

            ZStack(alignment: .topLeading) {
                square(cell)
                square(cell).offset(x: cell + gap)
                square(cell).offset(y: cell + gap)
            }
        }
    }

    private func square(_ size: CGFloat) -> some View {
        Rectangle()
            .fill(.white)
            .frame(width: size, height: size)
    }
}

struct TodayNotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBridge.kind, provider: TodayNotesProvider()) { entry in
            TodayNotesWidgetView(entry: entry)
        }
        .configurationDisplayName("Today’s Notes")
        .description("See what you wrote down for today.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct WisprWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayNotesWidget()
    }
}

#Preview("Mixed notes", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(date: .now, notes: TodayNotesProvider.previewNotes)
}

#Preview("Empty", as: .systemLarge) {
    TodayNotesWidget()
} timeline: {
    TodayNotesEntry(date: .now, notes: [])
}
