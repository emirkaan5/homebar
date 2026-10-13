import SwiftUI
import Core

/// Sign-in with a SmartRent resident account, in the panel itself.
struct SignInView: View {
    let store: HomeStore

    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        email.contains("@") && !password.isEmpty && !store.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "house.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.bottom, 6)
                Text("Sign in to SmartRent")
                    .font(.system(size: 17, weight: .bold))
                Text("Use the email and password of your resident account.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                MonoField(title: "Email", symbol: "envelope", isFocused: focus == .email) {
                    TextField("Email", text: $email, prompt: Text("you@example.com"))
                        .textContentType(.username)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                }
                MonoField(title: "Password", symbol: "lock", isFocused: focus == .password) {
                    SecureField("Password", text: $password, prompt: Text("Password"))
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                }
            }
            .disabled(store.isBusy)

            Button(action: submit) {
                HStack(spacing: 8) {
                    if store.isBusy {
                        ProgressView().controlSize(.small).tint(.secondary)
                    }
                    Text(store.isBusy ? "Signing In…" : "Sign In")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MonoButtonStyle(isFilled: true, isWide: true))
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)

            VStack(alignment: .leading, spacing: 3) {
                Label("Your password goes only to SmartRent. HomeBar keeps only the session, in your Keychain.",
                      systemImage: "checkmark.shield")
                Text("Works with SmartRent accounts. Not affiliated with SmartRent.")
                    .padding(.leading, 20)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { focus = email.isEmpty ? .email : .password }
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await store.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password) }
    }
}

/// The second step, when the account uses two-factor authentication.
struct TwoFactorView: View {
    let store: HomeStore

    @State private var code = ""
    @FocusState private var isFocused: Bool

    private var digits: String { code.filter(\.isNumber) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.bottom, 6)
                Text("Enter your code")
                    .font(.system(size: 17, weight: .bold))
                Text("SmartRent sent a verification code to your phone or email.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            MonoField(title: "Code", symbol: "number", isFocused: isFocused) {
                TextField("Code", text: $code, prompt: Text("123456"))
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .tracking(4)
                    .focused($isFocused)
                    .onSubmit(submit)
            }
            .disabled(store.isBusy)

            HStack(spacing: 8) {
                Button("Back") { Task { await store.signOut() } }
                    .buttonStyle(MonoButtonStyle(isFilled: false, isWide: true))
                Button(action: submit) {
                    HStack(spacing: 8) {
                        if store.isBusy {
                            ProgressView().controlSize(.small).tint(.secondary)
                        }
                        Text(store.isBusy ? "Checking…" : "Continue")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MonoButtonStyle(isFilled: true, isWide: true))
                .keyboardShortcut(.defaultAction)
                .disabled(digits.count < 4 || store.isBusy)
            }
        }
        .onAppear { isFocused = true }
    }

    private func submit() {
        guard digits.count >= 4, !store.isBusy else { return }
        Task { await store.submitTwoFactor(code: digits) }
    }
}

/// A text field in the black-and-white style: a quiet fill, an icon, and a
/// border that turns solid while the field has focus.
private struct MonoField<Field: View>: View {
    let title: String
    let symbol: String
    let isFocused: Bool
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                .frame(width: 16)
            field
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .labelsHidden()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isFocused ? Color.primary.opacity(0.7) : Palette.hairline, lineWidth: isFocused ? 1.2 : 0.5)
        )
        .animation(Motion.press, value: isFocused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
