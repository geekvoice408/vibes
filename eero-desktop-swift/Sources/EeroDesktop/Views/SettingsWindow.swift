#if os(macOS)
import SwiftUI
import EeroCore

/// Routes owned by the desktop shell itself: "Settings/Appearance" (port of `AppearancePage`) and the
/// development-only "Theme preview" (port of `ThemePreviewPage`). Register in `FeatureAreas.all`.
enum AppearanceArea: FeatureArea {
    static let appearance = "Settings/Appearance"
    static let themePreview = "Theme preview"

    static func handles(_ route: String) -> Bool { route == appearance || route == themePreview }
    static func load(_ route: String, model: AppModel) async throws -> JSON? { nil }
    static func view(_ route: String, model: AppModel) -> AnyView {
        route == themePreview ? AnyView(ThemePreviewView(model: model)) : AnyView(AppearanceView())
    }
}

/// The app's Settings window (⌘,): appearance and startup preferences.
@MainActor
struct SettingsWindow: View {
    var body: some View {
        TabView {
            ScrollView { AppearanceView(showsSubtitle: false).padding(24) }
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            StartupSettingsView()
                .padding(24)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 460)
        .background(Palette.page)
    }
}

/// Theme choice with light and dark samples (port of `AppearancePage`).
@MainActor
struct AppearanceView: View {
    @ObservedObject private var preferences = UiPreferences.shared
    var showsSubtitle = true

    init(showsSubtitle: Bool = true) { self.showsSubtitle = showsSubtitle }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSubtitle { Subtitle("Choose how eero Desktop looks on this Mac.") }
            Card {
                SectionHeader("App theme")
                Text("Use your macOS preference, or choose a light or dark appearance.")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
                Picker("App theme", selection: Binding(get: { preferences.effectiveTheme },
                                                      set: { preferences.theme = $0 })) {
                    Text("Use macOS setting").tag("System").accessibilityLabel("System theme")
                    Text("Light").tag("Light").accessibilityLabel("Light theme")
                    Text("Dark").tag("Dark").accessibilityLabel("Dark theme")
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .padding(.top, 16).padding(.bottom, 10)
            }
            HStack(spacing: 20) {
                ThemeSample(dark: false)
                ThemeSample(dark: true)
            }
        }
    }
}

/// A fixed-colour miniature of the app in one appearance.
private struct ThemeSample: View {
    let dark: Bool
    var body: some View {
        let ink = dark ? Color.white : Palette.fixed(0x191970) // MidnightBlue
        VStack(alignment: .leading, spacing: 0) {
            Text("eero").font(.system(size: 25, weight: .light)).foregroundStyle(ink)
            Text(dark ? "Dark appearance" : "Light appearance").font(.system(size: 12))
                .foregroundStyle(Palette.fixed(dark ? 0xB2B3BD : 0x646879))
                .padding(.top, 2).padding(.bottom, 12)
            HStack(spacing: 8) {
                tile("Internet", bar: 65, ink: ink)
                tile("Devices", bar: 24, ink: ink)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180, alignment: .topLeading)
        .background(Palette.fixed(dark ? 0x202022 : 0xEEEEF1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tile(_ title: String, bar: CGFloat, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(ink)
            RoundedRectangle(cornerRadius: 3).fill(Palette.fixed(dark ? 0x82AAFF : 0x0057FF)).frame(width: bar, height: 6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fixed(dark ? 0x272729 : 0xFFFFFF), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.fixed(dark ? 0x3D3D42 : 0xE1E1E5), lineWidth: 1))
    }
}

/// Start-at-login and keep-running options (the startup half of the Windows notifications editor).
@MainActor
private struct StartupSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var preferences = UiPreferences.shared
    @ViewState private var message = ""
    @ViewState private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Startup")
            Toggle("Open eero Desktop when I log in to this Mac", isOn: Binding(
                get: { preferences.startAtLogin },
                set: { setStartAtLogin($0) }))
            Toggle("Keep running in the menu bar when the window closes", isOn: Binding(
                get: { preferences.background },
                set: { value in
                    if model.preview { report("Preview mode does not change macOS startup or your preferences.", failed: true); return }
                    preferences.background = value || preferences.startAtLogin
                }))
            .disabled(preferences.startAtLogin)
            Text("Startup is optional and starts disabled. Remember your eero session to restore it automatically. Quitting from the menu bar stops alerts until the next launch.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if LoginItem.requiresApproval {
                Text("Approve eero Desktop in System Settings > General > Login Items to finish enabling startup.")
                    .font(.system(size: 12)).foregroundStyle(Palette.warning)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(failed ? Palette.error : Palette.muted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setStartAtLogin(_ on: Bool) {
        if model.preview { report("Preview mode does not change macOS startup or your preferences.", failed: true); return }
        let oldStartup = preferences.startAtLogin, oldBackground = preferences.background
        do {
            try LoginItem.setEnabled(on)
            preferences.startAtLogin = on
            preferences.background = preferences.background || on
            report("Startup preferences saved.", failed: false)
        } catch {
            preferences.startAtLogin = oldStartup
            preferences.background = oldBackground
            report(userMessage(error), failed: true)
        }
    }

    private func report(_ text: String, failed: Bool) { message = text; self.failed = failed }
}
#endif
