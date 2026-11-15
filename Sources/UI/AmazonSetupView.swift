import SwiftUI
import WebKit
import Core

/// Connects Amazon's smart plugs. Amazon's own page does the signing in, inside the
/// panel, so HomeBar never handles the password or the one-time code. When the page
/// is done, the app takes the session it left behind and reads the plugs with it.
struct AmazonSetupView: View {
    let account: any AccountSetup & AccessoryProvider
    let onFinish: (_ connected: Bool) -> Void

    private enum Step: Equatable {
        case signIn
        case checking
        case connected(Int)
        case failed(String)
    }

    @State private var step: Step = .signIn
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Amazon Plugs").font(.system(size: 17, weight: .bold))
                Spacer()
                if case .connected = step {} else {
                    Button("Cancel") { onFinish(false) }
                        .buttonStyle(PressableStyle())
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            switch step {
            case .signIn:
                signIn
            case .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking the session with Amazon…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            case .connected(let count):
                connected(count)
            case .failed(let summary):
                failed(summary)
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.unlocked)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.snappy, value: step)
    }

    // MARK: Steps

    @ViewBuilder
    private var signIn: some View {
        if let page = account.signInPage {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to Amazon below. The page belongs to Amazon, so HomeBar never sees your password. Use the account that your plug is set up with.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SignInPage(page: page, sessionPage: account.sessionPage) { cookies in
                    Task { await finish(cookies: cookies) }
                }
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5))
            }
        } else {
            // A build with no sign-in page, such as the demo.
            VStack(alignment: .leading, spacing: 12) {
                Text("This build has no Amazon sign-in page. Connect the demo plugs instead.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect Demo Plugs") { Task { await finish(cookies: nil) } }
                    .buttonStyle(MonoButtonStyle(isFilled: true, isWide: true))
            }
        }
    }

    private func connected(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(sentence(for: count), systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") { onFinish(true) }
                .buttonStyle(MonoButtonStyle(isFilled: true, isWide: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private func failed(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                message = nil
                step = .signIn
            }
            .buttonStyle(MonoButtonStyle(isFilled: true, isWide: true))
        }
    }

    private func sentence(for count: Int) -> String {
        switch count {
        case 0: "Amazon is connected, but this account has no plugs yet. Set the plug up in the Alexa app first."
        case 1: "Amazon is connected. The plug is in the panel now."
        default: "Amazon is connected. \(count) plugs are in the panel now."
        }
    }

    // MARK: Actions

    /// Takes the session the page produced and checks that Amazon answers with it.
    private func finish(cookies: [String: String]?) async {
        step = .checking
        message = nil
        do {
            if let cookies {
                try await account.connect(cookies: cookies)
            } else {
                await account.connectDemo()
            }
            let plugs = try await account.devices().filter { $0.kind == .plug }
            Haptics.bump()
            step = .connected(plugs.count)
        } catch {
            message = error.localizedDescription
            step = .failed("HomeBar could not read your Amazon plugs.")
        }
    }
}

/// Amazon's sign-in page in the panel, and the session it leaves behind.
///
/// The page signs the person in, so the app is never told when that is done. It
/// watches the cookies instead: once the session cookie appears, it opens the page
/// that Amazon hands its API session over to, then reports every cookie.
private struct SignInPage: NSViewRepresentable {
    let page: URL
    let sessionPage: URL?
    let onSession: ([String: String]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, sessionPage: sessionPage, onSession: onSession)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The session goes to the Keychain, so the page has no reason to keep cookies.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: page))
        context.coordinator.start(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let page: URL
        private let sessionPage: URL?
        private let onSession: ([String: String]) -> Void
        private weak var webView: WKWebView?
        private var timer: Timer?
        /// True once the session page has been asked for, so the visit happens once.
        private var didAskForSessionPage = false
        private var didFinish = false

        init(page: URL, sessionPage: URL?, onSession: @escaping ([String: String]) -> Void) {
            self.page = page
            self.sessionPage = sessionPage
            self.onSession = onSession
        }

        func start(_ webView: WKWebView) {
            self.webView = webView
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.lookForSession() }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        // MARK: Cookies

        /// The sign-in happens inside the page, so the cookies are watched for it.
        private func lookForSession() {
            guard !didFinish, !didAskForSessionPage, let webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                Task { @MainActor [weak self] in
                    guard let self, !self.didFinish, !self.didAskForSessionPage else { return }
                    guard cookies.contains(where: { ["session-id", "session-token", "at-main"].contains($0.name) }) else {
                        return
                    }
                    self.didAskForSessionPage = true
                    if let sessionPage = self.sessionPage {
                        self.webView?.load(URLRequest(url: sessionPage))
                    } else {
                        self.collect()
                    }
                }
            }
        }

        /// Every cookie the two pages left, ready for the API. The API talks to the
        /// Alexa address, so where two domains use the same cookie name the more
        /// exact domain wins.
        private func collect() {
            guard !didFinish, let webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                Task { @MainActor [weak self] in
                    guard let self, !self.didFinish else { return }
                    self.didFinish = true
                    self.stop()
                    var values: [String: String] = [:]
                    let amazon = cookies.filter { $0.domain.contains("amazon.") }
                    for cookie in amazon.sorted(by: { $0.domain.count < $1.domain.count }) {
                        values[cookie.name] = cookie.value
                    }
                    self.onSession(values)
                }
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Coming back from the session page: its cookies are set by then.
            if didAskForSessionPage, !didFinish, webView.url?.host?.contains("amazon.") == true {
                collect()
            }
        }
    }
}
