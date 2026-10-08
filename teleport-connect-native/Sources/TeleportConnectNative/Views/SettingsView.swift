import SwiftUI

/// A small preferences sheet — Cmd+, or "..." > Preferences. Not part of the real Electron app
/// (it doesn't need this; it always uses the system browser), added per request.
///
/// The "From Connect's config" section mirrors web/packages/teleterm/src/services/config/
/// appConfigSchema.ts — the real app_config.json schema — using the same key names/defaults,
/// limited to the subset that maps onto something this app can actually act on (see
/// AppConfig.swift's doc comment for what's out of scope and why).
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preferences").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    model.showSettings = false
                } label: {
                    Image(systemName: "xmark").foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.space[4])
            .padding(.bottom, 0)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space[3]) {
                    section("Browser for SSO Handoff") {
                        Text("Used by \"Open in Browser\" when a sign-in flow needs more than the in-app window can do (passkeys, device pairing).")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                        Picker("", selection: Binding(
                            get: { model.browserChoice },
                            set: { model.setBrowserChoice($0) }
                        )) {
                            ForEach(BrowserChoice.allCases) { choice in
                                Text(choice.label).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Toggle("Open the browser automatically for MFA (use your passkey there)", isOn: Binding(
                            get: { model.preferBrowserMFA },
                            set: { model.setPreferBrowserMFA($0) }
                        ))
                        .font(.system(size: 12))
                    }

                    Divider()

                    section("Login with tsh") {
                        Text("The \"Log in with tsh\" button runs `tsh login --user=… --mfa-mode=…` in a terminal tab, so MFA can use your browser passkey (iCloud Keychain, 1Password, phone) instead of a security key.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                        configRow("Login name") {
                            TextField("e.g. paul@geekvoice.net", text: Binding(
                                get: { model.tshLoginUser },
                                set: { model.setTshLogin(user: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        }
                        configRow("Auth method (--mfa-mode)") {
                            Picker("", selection: Binding(
                                get: { model.tshMFAMode },
                                set: { model.setTshLogin(mfaMode: $0) }
                            )) {
                                Text("Browser (passkey)").tag("browser")
                                Text("Security key").tag("cross-platform")
                                Text("Touch ID").tag("platform")
                                Text("Authenticator code").tag("otp")
                                Text("SSO").tag("sso")
                                Text("Automatic").tag("auto")
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }
                    }

                    Divider()

                    section("From Connect's Config (app_config.json)") {
                        configRow("theme") {
                            Picker("", selection: configBinding(\.theme)) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 200)
                        }

                        configRow("terminal.fontFamily") {
                            TextField("", text: configBinding(\.terminalFontFamily))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }

                        configRow("terminal.fontSize") {
                            Stepper(
                                "\(model.appConfig.terminalFontSize)",
                                value: configBinding(\.terminalFontSize),
                                in: 8...36
                            )
                            .frame(width: 100)
                        }

                        configRow("terminal.copyOnSelect") {
                            Toggle("", isOn: configBinding(\.terminalCopyOnSelect)).labelsHidden()
                        }

                        configRow("ssh.forwardAgent") {
                            Toggle("", isOn: configBinding(\.sshForwardAgent)).labelsHidden()
                        }

                        configRow("ssh.noResume") {
                            Toggle("", isOn: configBinding(\.sshNoResume)).labelsHidden()
                        }

                        configRow("sshAgent.addKeysToAgent", note: "Needs a restart to take effect.") {
                            Picker("", selection: configBinding(\.sshAgentAddKeysToAgent)) {
                                Text("auto").tag("auto")
                                Text("no").tag("no")
                                Text("yes").tag("yes")
                                Text("only").tag("only")
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }

                        configRow("hardwareKeyAgent.enabled", note: "Needs a restart to take effect.") {
                            Toggle("", isOn: configBinding(\.hardwareKeyAgentEnabled)).labelsHidden()
                        }
                    }

                    Divider()

                    section("Custom Icons") {
                        Text("Right-click any resource's icon to set one. Listed here by the resource name it applies to.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)

                        if model.customIcons.isEmpty {
                            Text("None set yet").font(.system(size: 12)).foregroundStyle(Theme.textDisabled)
                                .padding(.top, Theme.space[1])
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(model.customIcons.keys.sorted(), id: \.self) { name in
                                    HStack {
                                        ResourceIconImage(name: "application", customFilePath: model.customIcons[name])
                                            .frame(width: 20, height: 20)
                                        Text(name).font(Theme.uiFont)
                                        Spacer()
                                        Button("Remove") { model.removeCustomIcon(forResourceName: name) }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(Theme.interactiveDanger)
                                            .font(.system(size: 11))
                                    }
                                    .padding(.vertical, Theme.space[1])
                                }
                            }
                        }
                    }
                }
                .padding(Theme.space[4])
                .padding(.top, 0)
            }
            .frame(maxHeight: 480)
        }
        .frame(width: 460)
        .background(Theme.levelElevated)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.space[1]) {
            Text(title).font(Theme.uiFontMedium)
            content()
        }
    }

    private func configRow<Content: View>(_ key: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(key).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textMain)
                if let note {
                    Text(note).font(.system(size: 10)).foregroundStyle(Theme.textDisabled)
                }
            }
            Spacer()
            content()
        }
    }

    private func configBinding<Value>(_ keyPath: WritableKeyPath<AppConfig, Value>) -> Binding<Value> {
        Binding(
            get: { model.appConfig[keyPath: keyPath] },
            set: { newValue in
                model.appConfig[keyPath: keyPath] = newValue
                model.saveAppConfig()
            }
        )
    }

}
