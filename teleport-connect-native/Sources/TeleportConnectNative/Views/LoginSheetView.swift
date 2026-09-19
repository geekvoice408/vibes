import SwiftUI

/// Mirrors ClusterConnect/ClusterLogin/ClusterLogin.tsx + FormLogin: a header with a close
/// button, an optional Passwordless row, an "Or" divider, full-width SSO provider rows with
/// their brand icon, and/or a local username/password form.
struct LoginSheetView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space[3]) {
            switch model.loginState {
            case .idle:
                EmptyView()

            case .loadingProviders:
                centered {
                    ProgressView()
                    Text("Loading sign-in options…").font(Theme.uiFontSmall).foregroundStyle(Theme.textMuted)
                }

            case .choosingProvider(let clusterURI, let providers, let localAuthEnabled, let allowPasswordless):
                header(clusterURI: clusterURI)

                if allowPasswordless {
                    Button {
                        model.loginWithPasswordless(clusterURI: clusterURI)
                    } label: {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundStyle(Theme.textMain)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Passwordless").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textMain)
                                Text("Follow the prompts").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            Image(systemName: "arrow.right").foregroundStyle(Theme.textMuted)
                        }
                        .padding(Theme.space[2])
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiiMedium)
                            .strokeBorder(Theme.buttonBorder, lineWidth: 1)
                    )

                    if !providers.isEmpty || localAuthEnabled {
                        orDivider
                    }
                }

                ForEach(providers) { provider in
                    ssoProviderRow(provider) {
                        Task { await model.loginWithSSO(clusterURI: clusterURI, provider: provider) }
                    }
                }

                if localAuthEnabled {
                    if !providers.isEmpty && !allowPasswordless {
                        orDivider
                    }
                    localLoginForm(clusterURI: clusterURI)
                }

                Button("Back") { model.cancelLogin() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.space[1])

            case .passwordless:
                passwordlessView

            case .waitingForBrowser:
                if let url = model.ssoBrowserURL {
                    VStack(spacing: 0) {
                        HStack {
                            Text((model.ssoBrowserCurrentURL ?? url).host ?? "Sign in")
                                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                            Spacer()
                            Button("Open in Browser") { model.openSSOInSystemBrowser() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.brand)
                                .help("If this provider needs something the in-app window can't do (passkeys, phone/Bluetooth pairing), finish signing in in your real browser instead.")
                            Button("Cancel") { model.cancelLogin() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.textMuted)
                        }
                        .padding(Theme.space[2])
                        Divider()
                        SSOBrowserView(
                            url: url,
                            onError: { model.statusMessage = $0 },
                            onNavigate: { model.ssoBrowserCurrentURL = $0 }
                        )
                        .frame(minWidth: 640, minHeight: 520)
                    }
                } else {
                    centered {
                        ProgressView()
                        Text("Opening sign-in window…")
                            .font(Theme.uiFontSmall)
                            .foregroundStyle(Theme.textMuted)
                        Button("Cancel") { model.cancelLogin() }
                    }
                }

            case .syncing:
                centered {
                    ProgressView()
                    Text("Syncing cluster…").font(Theme.uiFontSmall).foregroundStyle(Theme.textMuted)
                }

            case .failed(let message):
                centered {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.interactiveDanger)
                    Text("Login failed").font(Theme.uiFontMedium)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                    Button("Close") { model.cancelLogin() }
                }
            }
        }
        .padding(isShowingBrowser ? 0 : Theme.space[4])
        .frame(width: isShowingBrowser ? nil : 420)
        .background(Theme.levelElevated)
    }

    private var isShowingBrowser: Bool {
        if case .waitingForBrowser = model.loginState, model.ssoBrowserURL != nil {
            return true
        }
        return false
    }

    @ViewBuilder
    private var passwordlessView: some View {
        switch model.passwordlessState {
        case .waitingForTap:
            centered {
                Image(systemName: "hand.tap").font(.title).foregroundStyle(Theme.brand)
                Text("Tap your security key").font(Theme.uiFontMedium)
                Text("Follow the prompts from your browser or device.")
                    .font(Theme.uiFontSmall)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                Button("Cancel") { model.cancelLogin() }
            }

        case .waitingForRetap:
            centered {
                Image(systemName: "hand.tap.fill").font(.title).foregroundStyle(Theme.brand)
                Text("Tap your security key again to confirm").font(Theme.uiFontMedium)
                    .multilineTextAlignment(.center)
                Button("Cancel") { model.cancelLogin() }
            }

        case .enteringPIN:
            VStack(alignment: .leading, spacing: Theme.space[2]) {
                Text("Enter your security key PIN").font(Theme.uiFontMedium)
                SecureField("PIN", text: Binding(
                    get: { model.passwordlessPIN },
                    set: { model.passwordlessPIN = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submitPasswordlessPIN() }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelLogin() }
                    Button("Continue") { model.submitPasswordlessPIN() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                        .disabled(model.passwordlessPIN.isEmpty)
                }
            }

        case .choosingCredential(let usernames):
            VStack(alignment: .leading, spacing: Theme.space[2]) {
                Text("Choose an account").font(Theme.uiFontMedium)
                ForEach(Array(usernames.enumerated()), id: \.offset) { index, username in
                    Button {
                        model.selectPasswordlessCredential(index: index)
                    } label: {
                        Text(username).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelLogin() }
                }
            }
        }
    }

    private func header(clusterURI: String) -> some View {
        HStack {
            (Text("Log in to ") + Text(clusterURI.replacingOccurrences(of: "/clusters/", with: "")).bold())
                .font(.system(size: 17))
                .foregroundStyle(Theme.textMain)
            Spacer()
            Button {
                model.cancelLogin()
            } label: {
                Image(systemName: "xmark").foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
    }

    private var orDivider: some View {
        HStack(spacing: Theme.space[2]) {
            Rectangle().fill(Theme.spotBackground2).frame(height: 1)
            Text("Or").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            Rectangle().fill(Theme.spotBackground2).frame(height: 1)
        }
    }

    private func ssoProviderRow(_ provider: AuthProviderRow, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Spacer()
                if let iconName = GuessAppIcon.forAuthProvider(displayName: provider.displayName, type: provider.type) {
                    ResourceIconImage(name: iconName, fallbackSymbol: "key.fill", fallbackTint: Theme.textMain)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "key.fill").foregroundStyle(Theme.textMain)
                }
                Text(provider.displayName).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textMain)
                Spacer()
            }
            .padding(Theme.space[2])
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.spotBackground0)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiiMedium))
    }

    @ViewBuilder
    private func centered<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: Theme.space[2]) {
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private func localLoginForm(clusterURI: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.space[2]) {
            TextField("Username", text: Binding(
                get: { model.loginUsername },
                set: { model.loginUsername = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            SecureField("Password", text: Binding(
                get: { model.loginPassword },
                set: { model.loginPassword = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            TextField("2FA code (if required)", text: Binding(
                get: { model.loginOTP },
                set: { model.loginOTP = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            Button("Log in") {
                Task { await model.loginWithLocalCredentials(clusterURI: clusterURI) }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .disabled(model.loginUsername.isEmpty || model.loginPassword.isEmpty)
        }
    }
}
