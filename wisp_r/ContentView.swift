import SwiftUI
import Playgrounds

/// Everywhere the menu leads. Shared so a moment's timeline can push a day of
/// its own.
enum WisprScreen: Hashable {
    /// A day in the day view; `nil` means today.
    case day(Date?)
    case moment(Moment)
    case settings
}

struct ContentView: View {
    /// Starts on the day view; the back button reveals the menu behind it.
    @State private var path: [WisprScreen] = [.day(nil)]

    /// Set when the widget's plus is tapped, so today opens straight into a
    /// blank note. A fresh value each time, so asking twice works twice.
    @State private var newNoteRequest: UUID?

    var body: some View {
        NavigationStack(path: $path) {
            menu
                .navigationDestination(for: WisprScreen.self) { screen in
                    switch screen {
                    case .day(let day):
                        DayView(
                            initialDay: day,
                            backTitle: backTitle(forDayAfter: screen),
                            newNoteRequest: $newNoteRequest
                        )

                    case .moment(let moment):
                        MomentTimelineView(moment: moment)

                    case .settings:
                        SettingsView()
                    }
                }
        }
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            guard url.scheme == "wispr" else { return }

            switch url.host {
            case "today":
                path = [.day(nil)]

            case "new":
                path = [.day(nil)]
                newNoteRequest = UUID()

            default:
                break
            }
        }
    }

    /// A day pushed from a moment's timeline goes back to that timeline, so the
    /// back button names it rather than the menu.
    private func backTitle(forDayAfter screen: WisprScreen) -> String {
        guard let index = path.firstIndex(of: screen), index > 0,
              case .moment(let moment) = path[index - 1]
        else { return AppSettings.shared.displayTitle }

        return moment.title
    }

    private var menu: some View {
        ZStack {
            WisprBackground()

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

                SectionHeader(title: "TIMELINES", trailingTitle: "ALL")
                    .padding(.top, 44)

                CardGroup {
                    TimelineRow(title: "Friends", color: .timelineFriends)
                    TimelineRow(title: "Programming", color: .timelineProgramming)
                    TimelineRow(title: "Trips", color: .timelineTrips)
                    TimelineRow(title: "Funny", color: .timelineFunny, showsChevron: false)
                }
                .padding(.top, 13)

                NavigationLink(value: WisprScreen.settings) {
                    MenuRow(title: "Settings", icon: "gearshape.fill")
                }
                .buttonStyle(.plain)
                .padding(.top, 58)

                Spacer(minLength: 0)
            }
            .padding(.top, 20)
        }
    }

    /// A moments row, opening that moment's timeline.
    private func momentRow(_ moment: Moment) -> some View {
        NavigationLink(value: WisprScreen.moment(moment)) {
            MenuRow(title: moment.title, icon: moment.icon)
        }
        .buttonStyle(.plain)
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
                .foregroundStyle(.white)
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
            .fill(.white)
            .frame(width: size, height: size)
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    var trailingTitle: String?

    var body: some View {
        HStack {
            Text(title)
                .kerning(0.6)
            Spacer()
            if let trailingTitle {
                Text(trailingTitle)
                    .kerning(0.6)
            }
        }
        .font(.wispr(12, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.42))
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
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: icon)
                .font(.wispr(17, weight: iconWeight))
                .foregroundStyle(.white)
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
    let title: String
    let color: Color
    var showsChevron: Bool = true

    var body: some View {
        HStack {
            Text(title)
                .font(.wispr(18))
                .foregroundStyle(.white)
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.wispr(16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 43)
        .background(color)
    }
}

// MARK: - Palette

private extension Color {
    static let timelineFriends = Color(red: 0.42, green: 0.23, blue: 0.28)
    static let timelineProgramming = Color(red: 0.44, green: 0.39, blue: 0.27)
    static let timelineTrips = Color(red: 0.32, green: 0.31, blue: 0.46)
    static let timelineFunny = Color(red: 0.42, green: 0.23, blue: 0.27)
}

#if DEBUG
#Preview {
    AppSettings.preview()

    return ContentView()
        .environment(NoteStore(persistsToDisk: false))
        .environment(LocationHistory())
}

#Playground {
    _ = 1 + 2
}

#Preview("Legacy theme") {
    AppSettings.preview(theme: .legacy)

    return ContentView()
        .environment(NoteStore(persistsToDisk: false))
        .environment(LocationHistory())
}
#endif
