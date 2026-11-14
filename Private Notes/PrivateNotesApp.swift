import SwiftUI

@main
struct PrivateNotesApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                model.flushPendingSaves()
            }
        }
    }
}
