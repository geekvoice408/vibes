#if os(macOS)
import SwiftUI
import EeroCore

/// Sign-in and verification screens (port of `MainWindow.ShowLogin`).
///
/// The alternative sign-in buttons call `beginRegistration()`, `websiteSignIn()`, `providerSignIn()`
/// and `amazonSignIn()`, which are implemented as `AppModel` extensions by the registration and
/// sign-in feature files.
@MainActor
struct LoginView: View {
    @ObservedObject var model: AppModel
    let verify: Bool

    /// Remembers the chosen sign-in method between screens for this launch (`formatPhone`).
    private static var lastUsedPhone = true

    @ViewState private var usePhone = LoginView.lastUsedPhone
    @ViewState private var identifier = ""
    @ViewState private var remember = true
    @ViewState private var code = ""

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                intro
                    .frame(width: g.size.width * 0.38)
                    .frame(maxHeight: .infinity)
                    .background(Palette.rail)
                    .overlay(alignment: .trailing) { Rectangle().fill(Palette.edge).frame(width: 1) }
                ScrollView {
                    form
                        .frame(maxWidth: 410, alignment: .leading)
                        .padding(36)
                        .frame(maxWidth: .infinity, minHeight: g.size.height)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Palette.page)
    }

    // MARK: Intro column

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("eero").font(.system(size: 66, weight: .light)).foregroundStyle(Palette.text)
            Text("Desktop for Mac").font(.system(size: 13)).foregroundStyle(Palette.muted)
            Spacer().frame(height: 42)
            Image(systemName: "wifi").font(.system(size: 76)).foregroundStyle(Palette.legacy("#274CDB"))
                .padding(.bottom, 36)
            Text("Your wifi.\nFrom your desktop.").font(.system(size: 30, weight: .semibold)).foregroundStyle(Palette.text)
            Text("A clear view of your network, devices, and profiles.").font(.system(size: 15)).foregroundStyle(Palette.muted)
            Text("Independent desktop client\nNot affiliated with Amazon or eero.").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(48)
    }

    // MARK: Form column

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verify ? "Check your messages" : "Welcome home")
                .font(.system(size: 32, weight: .semibold)).foregroundStyle(Palette.text)
            Text(verify ? "Enter the verification code sent to your eero account. Keep this window open while you get it."
                        : "Sign in with the email address or phone number linked to your eero account.")
                .font(.system(size: 15)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: 18)

            Group {
                if verify { verification } else { signIn }
            }
            .disabled(model.busy)

            Text(model.notice).font(.system(size: 13))
                .foregroundStyle(model.noticeIsError ? Palette.error : Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                .accessibilityAddTraits(.updatesFrequently)

            VStack(alignment: .leading, spacing: 8) {
                Button("Check connection") {
                    model.perform {
                        try await model.api.checkConnection()
                        model.setNotice("Connected to eero securely. You can request your verification code.")
                    }
                }
                if !verify {
                    Button("Create an eero account") { if !model.busy { model.beginRegistration() } }
                    Button("Sign in on eero's website") { if !model.busy { WebFlows.shared.remember = remember; model.websiteSignIn() } }
                    Button("Sign in through an internet provider") { if !model.busy { WebFlows.shared.remember = remember; model.providerSignIn() } }
                    Button("Sign in with Amazon") { if !model.busy { WebFlows.shared.remember = remember; model.amazonSignIn() } }
                }
            }
            .disabled(model.busy)

            Text("Uses eero’s cloud service. An internet connection is required.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 8)
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in using").font(.system(size: 13, weight: .semibold))
            Picker("Sign in using", selection: $usePhone) {
                Text("Phone number").tag(true)
                Text("Email address").tag(false)
            }
            .labelsHidden()
            .onChange(of: usePhone) { _, phone in
                LoginView.lastUsedPhone = phone
                formatNumber()
            }

            Text(usePhone ? "Phone number" : "Email address").font(.system(size: 13, weight: .semibold))
            TextField("", text: $identifier)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Email or phone number")
                .onChange(of: identifier) { _, value in
                    if value.count > 254 { identifier = String(value.prefix(254)); return }
                    formatNumber()
                }
            Text(usePhone ? "10 digits automatically use +1 (US/Canada). For other countries, include + and the country code."
                          : "Use the email address linked to your eero account.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)

            Toggle("Remember me on this Mac", isOn: $remember)

            Button { sendCode() } label: {
                Text("Send verification code").frame(maxWidth: .infinity)
            }
            .buttonStyle(.accent)
            .keyboardShortcut(.defaultAction) // Return in the field activates it, like the Enter key handler
            .padding(.top, 6).padding(.bottom, 20)

            Text("Your session is encrypted in your macOS Keychain when Remember me is enabled.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private var verification: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verification code").font(.system(size: 13, weight: .semibold))
            TextField("", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 28))
                .textContentType(.oneTimeCode)
                .accessibilityLabel("Verification code")
                .onChange(of: code) { _, value in if value.count > 12 { code = String(value.prefix(12)) } }

            Button { verifyCode() } label: {
                Text("Verify and sign in").frame(maxWidth: .infinity)
            }
            .buttonStyle(.accent)
            .keyboardShortcut(.defaultAction) // Return in the field activates it, like the Enter key handler

            HStack {
                Button("Resend code") { resendCode() }
                Button("Use a different account") {
                    if model.busy { return }
                    Task { await model.api.cancelLogin() }
                    model.screen = .login(verify: false)
                }
            }
        }
    }

    // MARK: Actions

    /// Formats complete phone numbers as they are typed (`PhoneInput.FormatForDisplay`).
    /// SwiftUI text fields keep the insertion point at the end, so `PreserveCaret` is not needed.
    private func formatNumber() {
        guard usePhone else { return }
        let after = PhoneInput.formatForDisplay(identifier)
        if after != identifier { identifier = after }
    }

    private func sendCode() {
        let usePhone = usePhone, typed = identifier, remember = remember
        model.perform {
            var id = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if usePhone {
                id = try PhoneInput.normalize(id)
                formatNumber()
            } else if id.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
                throw EeroError.argument("Enter the email address linked to your eero account.")
            }
            await model.api.setRemember(remember)
            try await model.api.beginLogin(id)
            model.resendAfter = Date().addingTimeInterval(60)
            model.screen = .login(verify: true)
            model.setNotice("Code requested. Check your email or text messages.")
        }
    }

    private func verifyCode() {
        let entered = code.trimmingCharacters(in: .whitespacesAndNewlines)
        model.perform {
            if entered.range(of: "^[0-9]{4,10}$", options: .regularExpression) == nil {
                throw EeroError.argument("Enter the numeric code from your email or text message.")
            }
            if await model.api.isRegistering {
                try await model.api.verifyRegistration(code: entered, country: model.registrationCountry, consents: model.registrationConsents)
            } else {
                try await model.api.verify(entered)
            }
            code = ""
            model.screen = .shell
            try await model.loadAccount()
            model.setNotice(model.pageStatus)
        }
    }

    private func resendCode() {
        model.perform {
            let wait = Int((model.resendAfter.timeIntervalSinceNow).rounded(.up))
            if wait > 0 { throw EeroError.operation("You can request another code in \(wait) seconds.") }
            try await model.api.resend()
            model.resendAfter = Date().addingTimeInterval(60)
            model.setNotice("Another code has been requested.")
        }
    }
}
#endif
