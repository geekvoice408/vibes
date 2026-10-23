#if os(macOS)
import AppKit
import SwiftUI
import EeroCore

/// Account creation (port of the UI part of `RegistrationFeatures.cs`). The login screen calls
/// `model.beginRegistration()`; the two forms open in a sheet window on the main window, and a
/// successful start switches the login screen to code verification (`ShowLogin(true)`).
extension AppModel {
    /// Port of `BeginRegistrationUi`.
    func beginRegistration() {
        RegistrationPresenter.shared.show(model: self)
    }
}

@MainActor
final class RegistrationPresenter {
    static let shared = RegistrationPresenter()
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let controller = NSHostingController(rootView: RegistrationFlowView(model: model) { [weak self] in self?.close() })
        let w = NSWindow(contentViewController: controller)
        w.title = RegistrationContracts.countryTitle
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 560, height: 560))
        w.minSize = NSSize(width: 480, height: 320)
        w.isReleasedWhenClosed = false
        window = w
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            parent.beginSheet(w) { [weak self] _ in self?.window = nil }
        } else {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.window = nil }
            }
            w.center()
            w.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard let w = window else { return }
        if let parent = w.sheetParent { parent.endSheet(w) } else { w.close() }
        window = nil
    }
}

@MainActor
struct RegistrationFlowView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void

    private enum Step: Equatable { case country, details(country: String, agreements: [JSON]) }
    @ViewState private var step: Step = .country
    /// Set by a successful first step; the form's close then moves on instead of closing the window.
    @ViewState private var next: Step? = nil
    var body: some View {
        Group {
            switch step {
            case .country:
                NetEditSheet(request: countryRequest, model: model, onClose: advance).id("country")
            case .details(let country, let agreements):
                NetEditSheet(request: detailsRequest(country, agreements), model: model, onClose: advance).id("details")
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private func advance() {
        if let n = next { next = nil; step = n } else { close() }
    }

    /// First form: the account's country, used to fetch eero's consent agreements.
    private var countryRequest: NetEditRequest {
        NetEditRequest(title: RegistrationContracts.countryTitle,
                       fields: [NetField("country", "Two-letter country code", RegistrationContracts.defaultCountry)],
                       submit: "Continue", description: RegistrationContracts.countryPrompt) { v in
            let country = try RegistrationContracts.country(v["country"])
            let consents = try await model.api.registrationConsents(country: country)
            next = .details(country: country, agreements: RegistrationContracts.agreements(consents))
        }
    }

    /// Port of `RegistrationForm`.
    private func detailsRequest(_ country: String, _ agreements: [JSON]) -> NetEditRequest {
        var fields: [NetField] = [
            NetField("name", "Your name"),
            NetField("email", "Email address"),
            NetField("phone", "Phone number with country code"),
            .bool("remember", RegistrationContracts.rememberLabel, true),
            .link(RegistrationContracts.legalLinkLabel, RegistrationContracts.legalURL),
        ]
        for agreement in agreements {
            let key = agreement.s("name")
            if key.isEmpty { continue }
            fields.append(.bool("consent:" + key, RegistrationContracts.consentLabel(agreement), false))
        }
        if agreements.isEmpty { fields.append(.bool("legal", RegistrationContracts.legalConsentLabel, false)) }
        return NetEditRequest(title: RegistrationContracts.detailsTitle, fields: fields, submit: "Create account",
                              description: RegistrationContracts.detailsPrompt) { v in
            try Validation.validateName(v["name"])
            let email = try RegistrationContracts.email(v["email"])
            let choices = try RegistrationContracts.consentChoices(agreements, accepted: { v.flag("consent:" + $0) }, legalAccepted: v.flag("legal"))
            guard await v.confirm(RegistrationContracts.confirmation) else { return }
            await model.api.setRemember(v.flag("remember"))
            try await model.api.beginRegistration(name: v["name"].netTrimmed, email: email, phone: try PhoneInput.normalize(v["phone"]))
            model.registrationCountry = country
            model.registrationConsents = choices
            model.resendAfter = Date().addingTimeInterval(RegistrationContracts.resendDelay)
            model.screen = .login(verify: true)
            model.setNotice(RegistrationContracts.startedNotice)
        }
    }
}
#endif
