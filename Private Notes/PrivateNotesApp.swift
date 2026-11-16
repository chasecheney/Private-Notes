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
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Copy Without Formatting") {
                    EditorCommands.copyWithoutFormatting()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                model.noteActivity()
            case .background:
                #if os(iOS)
                // Leaving the app on iPhone and iPad locks the vault.
                model.lock()
                #else
                model.flushPendingSaves()
                #endif
            default:
                model.flushPendingSaves()
            }
        }
    }
}
