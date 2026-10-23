import Foundation

/// Validation and consent handling for eero account creation (the non-UI parts of `RegistrationFeatures.cs`).
public enum RegistrationContracts {
    public static let legalURL = "https://www.eero.com/legal"
    public static let defaultCountry = "US"
    public static let countryTitle = "Create an eero account"
    public static let countryPrompt = "Use this only if you do not already have an eero account. Phone/SMS verification is required."
    public static let detailsTitle = "Account details and consent"
    public static let detailsPrompt = "The displayed consent text comes from eero. Required consents must be explicitly accepted; optional consents start unchecked. Review eero's terms at https://www.eero.com/legal before continuing."
    public static let legalLinkLabel = "Review eero terms & privacy"
    public static let legalConsentLabel = "I have reviewed and agree to eero's terms and privacy policy"
    public static let rememberLabel = "Remember this Mac account"
    public static let confirmation = "Create a new eero account with these details and request a verification code?"
    public static let startedNotice = "Account creation started. Enter the verification code sent to your phone."
    /// Seconds before a new verification code may be requested.
    public static let resendDelay: TimeInterval = 60

    /// Two-letter country code, upper-cased.
    public static func country(_ input: String?) throws -> String {
        let country = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            throw EeroError.argument("Enter a two-letter country code, such as US or CA.")
        }
        return country
    }

    public static func email(_ input: String?) throws -> String {
        let email = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else {
            throw EeroError.argument("Enter a valid email address.")
        }
        return email
    }

    /// Consent agreements with a usable key, from the `consents/account` response.
    public static func agreements(_ consents: JSON) -> [JSON] { consents.list }

    /// Checkbox label for an agreement: eero's localized text, or a readable form of its key.
    public static func consentLabel(_ agreement: JSON) -> String {
        agreement.s("localized_consent").nilIfEmpty ?? humanize(agreement.s("name"))
    }

    /// Readable label for an API key (port of `MainWindow.Human`).
    public static func humanize(_ key: String) -> String {
        let special = ["ip": "IP address", "mac": "MAC address", "ssid": "Wifi name", "up_mbps": "Upload (Mbps)", "down_mbps": "Download (Mbps)",
                       "ipv6_upstream": "IPv6", "led_on": "Status light", "sqm": "Optimize for conferencing and gaming"]
        if let s = special[key] { return s }
        let spaced = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            if w.isEmpty || (w == w.uppercased() && w != w.lowercased()) { return w }
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Builds the `consents` object for `register/verify`. `accepted` returns the checkbox state for an agreement name;
    /// `legalAccepted` is the generic terms checkbox shown when eero lists no agreements.
    public static func consentChoices(_ agreements: [JSON], accepted: (String) -> Bool, legalAccepted: Bool) throws -> JSON {
        var choices: [String: JSON] = [:]
        for agreement in agreements {
            let key = agreement.s("name")
            if key.isEmpty { continue }
            let consent = accepted(key)
            if agreement.b("requires_consent") && !consent {
                throw EeroError.argument("A required consent has not been accepted. Review the agreement before continuing.")
            }
            choices[key] = .bool(consent)
        }
        if agreements.isEmpty && !legalAccepted {
            throw EeroError.argument("Review and accept eero's terms and privacy policy before creating an account.")
        }
        return .object(choices)
    }

    /// Validates the account details form and returns the values to send to `EeroAPI.beginRegistration`.
    public static func details(name: String, email: String, phone: String) throws -> (name: String, email: String, phone: String) {
        try Validation.validateName(name)
        let address = try self.email(email)
        return (name.trimmingCharacters(in: .whitespacesAndNewlines), address, try PhoneInput.normalize(phone))
    }
}
