import Foundation

/// Shared name and wifi credential validators (port of `MainWindow.ValidateName`, `ValidateSsid`, `ValidatePassword`).
public enum Validation {
    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Names (profiles, devices, schedules, account) must have 1–100 characters after trimming.
    public static func validateName(_ s: String?) throws {
        guard let s, !trimmed(s).isEmpty, trimmed(s).utf16.count <= 100 else {
            throw EeroError.argument("Enter a name between 1 and 100 characters.")
        }
    }

    /// Wifi network names must be 1–32 UTF-8 bytes after trimming.
    public static func validateSsid(_ s: String?) throws {
        guard let s, !trimmed(s).isEmpty, trimmed(s).utf8.count <= 32 else {
            throw EeroError.argument("Wifi names must contain between 1 and 32 UTF-8 bytes.")
        }
    }

    /// Wifi passwords must be 8–63 printable ASCII characters.
    public static func validatePassword(_ s: String?) throws {
        let u = Array((s ?? "").utf16)
        if u.count < 8 || u.count > 63 || u.contains(where: { $0 < 32 || $0 > 126 }) {
            throw EeroError.argument("Use a wifi password with 8–63 printable ASCII characters.")
        }
    }
}
