import SwiftUI

/// Shows setup, the unlock screen, or the notes, depending on the vault's state.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .needsSetup:
            SetupView()
        case .showingRecoveryPhrase(let words):
            RecoveryPhraseView(words: words)
        case .locked:
            UnlockView()
        case .mustSetNewPassword:
            NewPasswordView()
        case .unlocked:
            MainView()
        }
    }
}
