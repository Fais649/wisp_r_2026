import SwiftUI

@main struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = NoteStore()
    @State private var locationHistory = LocationHistory()
    @State private var timelines = TimelineStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(locationHistory)
                .environment(timelines)
                .task { locationHistory.resumeIfNeeded() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.applyPendingWidgetActions()
                        store.syncCalendar()
                        locationHistory.resumeIfNeeded()
                    }
                }
        }
    }
}
