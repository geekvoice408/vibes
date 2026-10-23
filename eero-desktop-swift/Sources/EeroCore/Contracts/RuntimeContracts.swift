import Foundation

/// Request builders for invitations, automatic setup and network creation (port of `RuntimeContracts`).
public enum RuntimeContracts {
    public static func serial(_ value: String?) throws -> String {
        let serial = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !CoreBPattern.matches(serial, "[A-Za-z0-9-]{8,40}") { throw EeroError.argument("Enter the serial number printed on the eero or accessory.") }
        return serial
    }

    public static func adminInvite() -> JSON { JSON.obj(("invite_role", "admin")) }

    public static func invitationResponse(_ inviteId: String, _ accept: Bool) throws -> JSON {
        JSON.obj(("invite_id", try ExtendedContracts.identifier(inviteId)), ("accept", accept))
    }

    public static let autoSetupModes = ["OFF", "ZTS", "LTS", "DEFAULT"]

    public static func autoSetup(_ mode: String) throws -> JSON {
        if !autoSetupModes.contains(mode) { throw EeroError.argument("Choose a supported automatic setup mode.") }
        return JSON.obj(("mode", mode))
    }

    public static func createNetwork(_ name: String, _ password: String, _ timezone: String?, _ consents: [String: JSON]) throws -> JSON {
        try Validation.validateSsid(name); try Validation.validatePassword(password)
        guard let timezone, CoreBPattern.matches(timezone, "[A-Za-z_+-]+(?:/[A-Za-z_0-9+-]+){0,3}") else {
            throw EeroError.argument("Enter an IANA timezone such as America/Chicago or Europe/London.")
        }
        return JSON.obj(
            ("name", name.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("password", password),
            ("timezone", JSON.obj(("value", timezone))),
            ("settings", JSON.obj(("consents", JSON.object(consents)), ("enabled_simple_setup_vendors", JSON.array([])))))
    }

    // Forwarders kept for callers that use the Windows `MainWindow` validators through RuntimeContracts.
    public static func validateName(_ s: String?) throws { try Validation.validateName(s) }
    public static func validateSsid(_ s: String?) throws { try Validation.validateSsid(s) }
    public static func validatePassword(_ s: String?) throws { try Validation.validatePassword(s) }
}
