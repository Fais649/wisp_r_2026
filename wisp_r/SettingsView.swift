import EventKit
import SwiftUI

/// Everything about the app the person using it gets to choose: what it calls
/// itself, which calendar it writes to, how long a new event runs, and how the
/// whole thing looks.
struct SettingsView: View {
    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Bindable private var settings = AppSettings.shared

    @State private var calendars: [EKCalendar] = []
    @State private var hasCalendarAccess = true

    var body: some View {
        ZStack {
            WisprBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSection(title: "TITLE")

                    SettingsGroup {
                        titleField
                    }

                    SettingsSection(title: "THEME")
                        .padding(.top, 34)

                    SettingsGroup {
                        ForEach(Array(WisprThemeKind.allCases.enumerated()), id: \.element) { index, theme in
                            if index > 0 { SettingsDivider() }
                            themeRow(theme)
                        }
                    }

                    SettingsSection(title: "TEXT SIZE")
                        .padding(.top, 34)

                    SettingsGroup {
                        sizeRow("Headers", selection: $settings.headerTextSize)
                        SettingsDivider()
                        sizeRow("Editor", selection: $settings.editorTextSize)
                        SettingsDivider()
                        sizeRow("Notes", selection: $settings.noteTextSize)
                    }

                    SettingsSection(title: "WIDGET TEXT SIZE")
                        .padding(.top, 34)

                    SettingsGroup {
                        sizeRow("Header", selection: $settings.widgetHeaderTextSize)
                        SettingsDivider()
                        sizeRow("Note list", selection: $settings.widgetNoteTextSize)
                        SettingsDivider()
                        sizeRow("Opened note", selection: $settings.widgetFocusTextSize)
                    }

                    caption("An opened note starts out larger, so its checklist is easy to tap.")

                    SettingsSection(title: "EVENTS")
                        .padding(.top, 34)

                    SettingsGroup {
                        eventLengthRow
                    }

                    SettingsSection(title: "CALENDAR")
                        .padding(.top, 34)

                    SettingsGroup {
                        calendarRow(title: "System default", isSelected: settings.calendarID == nil) {
                            choose(nil)
                        }

                        ForEach(calendars, id: \.calendarIdentifier) { calendar in
                            SettingsDivider()
                            calendarRow(
                                title: calendar.title,
                                color: Color(cgColor: calendar.cgColor),
                                isSelected: settings.calendarID == calendar.calendarIdentifier
                            ) {
                                choose(calendar.calendarIdentifier)
                            }
                        }
                    }

                    caption(calendarCaption)

                    Spacer(minLength: 40)
                }
                .padding(.top, 8)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar
        }
        .task { await loadCalendars() }
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
                    Text(settings.displayTitle)
                        .font(.wispr(17))
                }
                .foregroundStyle(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Settings")
                .font(.wispr(17, weight: .medium))
                .foregroundStyle(.white)

            Spacer()

            // Balances the back button so the title sits in the middle.
            Color.clear
                .frame(width: 72, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.wispr(12))
            .foregroundStyle(Color.wisprSecondaryText)
            .padding(.horizontal, 40)
            .padding(.top, 10)
    }

    // MARK: - Title

    private var titleField: some View {
        HStack(spacing: 12) {
            TextField(AppSettings.fallbackTitle, text: $settings.title)
                .font(.wispr(18))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)

            if settings.title != AppSettings.fallbackTitle {
                Button("Reset") {
                    settings.title = AppSettings.fallbackTitle
                }
                .font(.wispr(13))
                .foregroundStyle(Color.wisprSecondaryText)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: - Theme

    private func themeRow(_ theme: WisprThemeKind) -> some View {
        Button {
            withAnimation(.snappy) { settings.theme = theme }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(theme.title)
                        .font(.wispr(18))
                        .foregroundStyle(.white)

                    Text(theme.blurb)
                        .font(.wispr(12))
                        .foregroundStyle(Color.wisprSecondaryText)
                }

                Spacer(minLength: 12)

                checkmark(isOn: settings.theme == theme)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(settings.theme == theme ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Text size

    private func sizeRow(_ title: String, selection: Binding<WisprTextSize>) -> some View {
        pickerRow(title, value: selection.wrappedValue.title) {
            Picker(title, selection: selection) {
                ForEach(WisprTextSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
        }
    }

    /// A row that names a setting and opens its choices from the right.
    private func pickerRow<Choices: View>(
        _ title: String,
        value: String,
        @ViewBuilder choices: () -> Choices
    ) -> some View {
        HStack {
            Text(title)
                .font(.wispr(18))
                .foregroundStyle(.white)

            Spacer(minLength: 12)

            Menu {
                choices()
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.wispr(16))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.wispr(11, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: - Events

    private var eventLengthRow: some View {
        pickerRow("Default length", value: settings.eventMinutes.eventLengthTitle) {
            Picker("Default length", selection: $settings.eventMinutes) {
                ForEach(AppSettings.eventLengths, id: \.self) { minutes in
                    Text(minutes.eventLengthTitle).tag(minutes)
                }
            }
        }
    }

    // MARK: - Calendar

    private func calendarRow(
        title: String,
        color: Color? = nil,
        isSelected: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Button {
            select()
        } label: {
            HStack(spacing: 12) {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 10, height: 10)
                }

                Text(title)
                    .font(.wispr(17))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 12)

                checkmark(isOn: isSelected)
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var calendarCaption: String {
        guard hasCalendarAccess else {
            return "Wispr needs calendar access to list your calendars. Allow it in the Settings app."
        }
        return "Events written here go to this calendar, and its events come back as notes."
    }

    private func choose(_ identifier: String?) {
        settings.calendarID = identifier
        // The notes now belong to a different calendar; read it straight away.
        store.syncCalendar()
    }

    private func loadCalendars() async {
        let eventStore = EKEventStore()

        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            break
        case .notDetermined:
            guard (try? await eventStore.requestFullAccessToEvents()) == true else {
                hasCalendarAccess = false
                return
            }
        default:
            hasCalendarAccess = false
            return
        }

        hasCalendarAccess = true
        calendars = eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Bits

    @ViewBuilder
    private func checkmark(isOn: Bool) -> some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.wispr(17))
            .foregroundStyle(isOn ? .white : Color.white.opacity(0.3))
    }
}

// MARK: - Rows

private struct SettingsSection: View {
    let title: String

    var body: some View {
        Text(title)
            .kerning(0.6)
            .font(.wispr(12, weight: .medium))
            .foregroundStyle(Color.wisprSecondaryText)
            .padding(.horizontal, 40)
            .padding(.bottom, 12)
    }
}

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .wisprCardBackground()
        .padding(.horizontal, 20)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.wisprSeparator)
            .frame(height: 1)
            .padding(.leading, 20)
    }
}

#Preview("Default theme") {
    AppSettings.preview()

    return NavigationStack {
        SettingsView()
            .environment(NoteStore(persistsToDisk: false))
    }
    .preferredColorScheme(.dark)
}

#Preview("Legacy theme") {
    AppSettings.preview(theme: .legacy)

    return NavigationStack {
        SettingsView()
            .environment(NoteStore(persistsToDisk: false))
    }
    .preferredColorScheme(.dark)
}
