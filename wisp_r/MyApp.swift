import SwiftUI

@main struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = NoteStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.applyPendingWidgetActions()
                        store.syncCalendar()
                    }
                }
        }
    }
}
