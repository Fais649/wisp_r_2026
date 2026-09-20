import Foundation
import SwiftUI
#if os(iOS)
import WidgetKit
#endif

/// Everything the settings screen can change, written to `UserDefaults` as it
/// changes.
///
/// One shared copy rather than a value passed through the environment, so the
/// styling helpers in ``WisprTheme`` can reach the theme from anywhere. Reads
/// made while a view's body runs are still observed, so changing a setting
/// redraws the app.
@Observable
final class AppSettings {
    /// Replaceable only so previews can stand a throwaway copy in its place.
    static var shared = AppSettings()

    /// What the app calls itself when the title has been left empty.
    static let fallbackTitle = "Wispr"

    /// Settings live in the group container rather than the app's own defaults,
    /// so the widget can be dressed in the same theme.
    static let appGroup = "group.com.punksys.wispr"

    /// The lengths a new event can be given, in minutes.
    static let eventLengths = [15, 30, 45, 60, 90, 120, 180]

    /// What the app calls itself in its own header.
    var title: String {
        didSet { defaults.set(title, forKey: Key.title) }
    }

    var theme: WisprThemeKind {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
            // The widget reads the same key, but only when it is asked to draw.
            #if os(iOS)
            WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetSnapshotPublisher.widgetKind)
            #endif
        }
    }

    /// The calendar events are written to. `nil` follows whichever calendar the
    /// system has set as the default.
    var calendarID: String? {
        didSet {
            if let calendarID {
                defaults.set(calendarID, forKey: Key.calendarID)
            } else {
                defaults.removeObject(forKey: Key.calendarID)
            }
        }
    }

    /// How long an event lasts when it is first given a time.
    var eventMinutes: Int {
        didSet { defaults.set(eventMinutes, forKey: Key.eventMinutes) }
    }

    /// Whether the app records an on-device trail for each day.
    var locationTrackingEnabled: Bool {
        didSet { defaults.set(locationTrackingEnabled, forKey: Key.locationTrackingEnabled) }
    }

    /// Whether notes with saved locations appear as callouts around the day map.
    var mapNoteIconsEnabled: Bool {
        didSet { defaults.set(mapNoteIconsEnabled, forKey: Key.mapNoteIconsEnabled) }
    }

    /// What a tap on a note in the widget does.
    var widgetNoteTap: WidgetNoteTap {
        didSet {
            defaults.set(widgetNoteTap.rawValue, forKey: Key.widgetNoteTap)
            #if os(iOS)
            WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetSnapshotPublisher.widgetKind)
            #endif
        }
    }

    // MARK: Text sizes

    var headerTextSize: WisprTextSize {
        didSet { defaults.set(headerTextSize.rawValue, forKey: Key.headerTextSize) }
    }

    var noteTextSize: WisprTextSize {
        didSet { defaults.set(noteTextSize.rawValue, forKey: Key.noteTextSize) }
    }

    var widgetHeaderTextSize: WisprTextSize {
        didSet { save(widgetHeaderTextSize, forKey: Key.widgetHeaderTextSize) }
    }

    /// The day's notes as the widget lists them.
    var widgetNoteTextSize: WisprTextSize {
        didSet { save(widgetNoteTextSize, forKey: Key.widgetNoteTextSize) }
    }

    /// A note opened inside the widget. Set larger to begin with, since that is
    /// where checklist items are crossed off with a thumb.
    var widgetFocusTextSize: WisprTextSize {
        didSet { save(widgetFocusTextSize, forKey: Key.widgetFocusTextSize) }
    }

    func textSize(for role: WisprTextRole) -> WisprTextSize {
        switch role {
        case .interface: .standard
        case .header: headerTextSize
        case .editor, .note: noteTextSize
        }
    }


    /// The title as it should be drawn: never blank.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.fallbackTitle : trimmed
    }

    var eventLength: TimeInterval { TimeInterval(eventMinutes * 60) }

    private let defaults: UserDefaults

    /// Pass a throwaway `UserDefaults` for previews so they don't write over
    /// real settings.
    init(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? UserDefaults(suiteName: Self.appGroup) ?? .standard
        self.defaults = defaults
        title = defaults.string(forKey: Key.title) ?? Self.fallbackTitle
        theme = WisprThemeKind(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .standard
        calendarID = defaults.string(forKey: Key.calendarID)

        let minutes = defaults.integer(forKey: Key.eventMinutes)
        eventMinutes = Self.eventLengths.contains(minutes) ? minutes : 60
        locationTrackingEnabled = defaults.bool(forKey: Key.locationTrackingEnabled)
        mapNoteIconsEnabled = defaults.object(forKey: Key.mapNoteIconsEnabled) as? Bool ?? true
        widgetNoteTap = WidgetNoteTap(rawValue: defaults.string(forKey: Key.widgetNoteTap) ?? "")
            ?? .openInApp

        headerTextSize = Self.textSize(in: defaults, forKey: Key.headerTextSize)
        noteTextSize = Self.textSize(in: defaults, forKey: Key.noteTextSize)
        widgetHeaderTextSize = Self.textSize(in: defaults, forKey: Key.widgetHeaderTextSize)
        widgetNoteTextSize = Self.textSize(in: defaults, forKey: Key.widgetNoteTextSize)
        widgetFocusTextSize = Self.textSize(
            in: defaults,
            forKey: Key.widgetFocusTextSize,
            default: .large
        )
    }

    private static func textSize(
        in defaults: UserDefaults,
        forKey key: String,
        default fallback: WisprTextSize = .standard
    ) -> WisprTextSize {
        WisprTextSize(rawValue: defaults.string(forKey: key) ?? "") ?? fallback
    }

    /// A widget setting: stored, then the widget asked to draw itself again.
    private func save(_ size: WisprTextSize, forKey key: String) {
        defaults.set(size.rawValue, forKey: key)
        #if os(iOS)
        WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetSnapshotPublisher.widgetKind)
        #endif
    }

    private enum Key {
        static let title = "appTitle"
        static let theme = "theme"
        static let calendarID = "defaultCalendarID"
        static let eventMinutes = "defaultEventMinutes"
        static let locationTrackingEnabled = "locationTrackingEnabled"
        static let mapNoteIconsEnabled = "mapNoteIconsEnabled"
        static let widgetNoteTap = "widgetNoteTap"
        static let headerTextSize = "headerTextSize"
        static let noteTextSize = "noteTextSize"
        static let widgetHeaderTextSize = "widgetHeaderTextSize"
        static let widgetNoteTextSize = "widgetNoteTextSize"
        static let widgetFocusTextSize = "widgetFocusTextSize"
    }
}

#if DEBUG
extension AppSettings {
    /// Points the styling helpers at a throwaway copy, so rendering a preview
    /// doesn't write over the settings on the device.
    @discardableResult
    static func preview(theme: WisprThemeKind = .standard) -> AppSettings {
        let suite = "com.punksys.wispr.previews"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)

        let settings = AppSettings(defaults: defaults)
        settings.theme = theme
        shared = settings
        return settings
    }
}
#endif

/// What happens when a note is tapped in the widget.
enum WidgetNoteTap: String, CaseIterable, Identifiable, Sendable {
    /// Opens the app on that note, ready to edit.
    case openInApp
    /// Opens the note inside the widget, without leaving the Home Screen.
    case focusInWidget

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openInApp: "Opens in the app"
        case .focusInWidget: "Opens in the widget"
        }
    }
}

/// "1 hour", "45 minutes" — how a default event length reads.
extension Int {
    var eventLengthTitle: String {
        Duration.seconds(self * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .wide)
        )
    }
}
