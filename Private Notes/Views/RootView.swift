import SwiftUI

/// Shows setup, the unlock screen, or the notes, depending on the vault's state.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            #if os(iOS)
            // What the app switcher shows instead of note content.
            .overlay {
                if scenePhase != .active {
                    PrivacyCover()
                }
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
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

/// Plain cover drawn over everything while the app is not frontmost on iPhone and iPad.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Private Notes")
                    .font(.title2.bold())
            }
        }
    }
}
