import SwiftUI

/// Shared frame for the setup and unlock screens.
private struct LockScreenLayout<Content: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title2.bold())
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            .frame(maxWidth: 440)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 320, minHeight: 420)
    }
}

/// Red line for the latest error, if any.
private struct ErrorLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let message = model.errorMessage {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Two password fields plus the rule that gates the button.
private struct NewPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String

    static func problem(password: String, confirmation: String) -> String? {
        if password.count < AppModel.minimumPasswordLength {
            return "Use at least \(AppModel.minimumPasswordLength) characters."
        }
        if password != confirmation {
            return "The two passwords don't match."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 10) {
            SecureField("Password", text: $password)
            SecureField("Password again", text: $confirmation)
            if !password.isEmpty, let problem = Self.problem(password: password, confirmation: confirmation) {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var confirmation = ""

    private var canContinue: Bool {
        NewPasswordFields.problem(password: password, confirmation: confirmation) == nil && !model.isWorking
    }

    var body: some View {
        LockScreenLayout(
            systemImage: "lock.shield",
            title: "Set up Private Notes",
            message: "Choose a password. It encrypts everything in this app. If you forget it, the only way back in is the recovery phrase shown on the next screen."
        ) {
            NewPasswordFields(password: $password, confirmation: $confirmation)
            ErrorLine()
            Button {
                Task { await model.createVault(password: password) }
            } label: {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Create Vault")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue)
        }
    }
}

struct RecoveryPhraseView: View {
    @Environment(AppModel.self) private var model
    let words: [String]
    @State private var confirmed = false

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        LockScreenLayout(
            systemImage: "key.horizontal",
            title: "Write down your recovery phrase",
            message: "These 24 words, in this order, unlock your notes if you forget your password. They are shown only this once and are not stored anywhere. Write them on paper and keep it somewhere safe."
        ) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 6) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                        Text(word)
                    }
                    .font(.body.monospaced())
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            Toggle("I have written down all 24 words", isOn: $confirmed)
            Button("Continue") {
                model.finishSetup()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!confirmed)
        }
    }
}

struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var usingRecoveryPhrase = false
    @State private var phraseText = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        if usingRecoveryPhrase {
            recoveryForm
        } else {
            passwordForm
        }
    }

    private var passwordForm: some View {
        LockScreenLayout(
            systemImage: "lock.fill",
            title: "Private Notes is locked",
            message: "Enter your password to unlock."
        ) {
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
                .onSubmit(unlock)
            ErrorLine()
            Button(action: unlock) {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Unlock")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || model.isWorking)

            if model.canUnlockWithBiometrics, let name = model.biometryName {
                Button {
                    Task { await model.unlockWithBiometrics() }
                } label: {
                    Label("Unlock with \(name)", systemImage: name == "Touch ID" ? "touchid" : "faceid")
                }
                .disabled(model.isWorking)
            }

            Button("Forgot password? Use recovery phrase") {
                model.errorMessage = nil
                usingRecoveryPhrase = true
            }
            .buttonStyle(.borderless)
        }
        .onAppear { passwordFocused = true }
        .task {
            // Offer Touch ID / Face ID straight away, once, when the app opens.
            if model.shouldAutoPromptBiometrics {
                model.shouldAutoPromptBiometrics = false
                await model.unlockWithBiometrics()
            }
        }
    }

    private var recoveryForm: some View {
        LockScreenLayout(
            systemImage: "key.horizontal",
            title: "Unlock with recovery phrase",
            message: "Type your 24 words in order, separated by spaces. You'll set a new password next."
        ) {
            TextEditor(text: $phraseText)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .frame(height: 120)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            ErrorLine()
            Button("Unlock") {
                Task {
                    await model.unlock(recoveryPhraseText: phraseText)
                    if model.errorMessage == nil { phraseText = "" }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(phraseText.isEmpty || model.isWorking)

            Button("Back to password") {
                model.errorMessage = nil
                phraseText = ""
                usingRecoveryPhrase = false
            }
            .buttonStyle(.borderless)
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let entered = password
        Task {
            await model.unlock(password: entered)
            password = ""
        }
    }
}

struct NewPasswordView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var confirmation = ""

    private var canContinue: Bool {
        NewPasswordFields.problem(password: password, confirmation: confirmation) == nil && !model.isWorking
    }

    var body: some View {
        LockScreenLayout(
            systemImage: "lock.rotation",
            title: "Set a new password",
            message: "Your recovery phrase worked. Choose a new password; the old one stops working. Your recovery phrase stays the same."
        ) {
            NewPasswordFields(password: $password, confirmation: $confirmation)
            ErrorLine()
            Button {
                Task { await model.setNewPassword(password) }
            } label: {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Set Password")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue)

            Button("Cancel and lock") {
                model.lock()
            }
            .buttonStyle(.borderless)
        }
    }
}
