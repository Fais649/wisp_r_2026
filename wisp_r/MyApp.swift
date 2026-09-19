import SwiftUI

@main struct MyApp: App {
    @State private var store = NoteStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
