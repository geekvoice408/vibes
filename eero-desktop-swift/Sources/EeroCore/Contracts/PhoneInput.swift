import Foundation

/// Phone-number normalisation and as-you-type formatting for sign-in (port of `PhoneInput`).
public enum PhoneInput {
    private static func isDigit(_ u: UInt16) -> Bool { u >= 48 && u <= 57 }

    /// Normalises to E.164 (`+` and up to 15 digits). Ten-digit numbers are treated as US/Canada.
    public static func normalize(_ input: String?) throws -> String {
        let text = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^\+?[0-9\s().-]+$"#, options: .regularExpression) != nil else {
            throw EeroError.argument("Enter a phone number, or choose Email address to sign in with email.")
        }
        var digits = String(text.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.map(Character.init))
        let international = text.hasPrefix("+")
        if !international {
            if digits.count == 10 { digits = "1" + digits }
            else if digits.count != 11 || !digits.hasPrefix("1") {
                throw EeroError.argument("Enter a 10-digit US/Canada number, or include + and your country code.")
            }
        }
        if digits.count < 8 || digits.count > 15 || digits.hasPrefix("0") {
            throw EeroError.argument("Enter a complete phone number with a valid country code (up to 15 digits).")
        }
        if digits.hasPrefix("1") && digits.count != 11 {
            throw EeroError.argument("US/Canada numbers need 10 digits after +1.")
        }
        return "+" + digits
    }

    /// Formats complete numbers only, so backspacing and partially typed numbers stay editable.
    public static func formatForDisplay(_ input: String?) -> String {
        guard let normalized = try? normalize(input) else { return input ?? "" }
        if normalized.hasPrefix("+1") && normalized.count == 12 {
            let d = Array(normalized)
            return "+1 (" + String(d[2..<5]) + ") " + String(d[5..<8]) + "-" + String(d[8..<12])
        }
        return normalized
    }

    /// Maps a caret position (UTF-16 offset) in `before` to the equivalent position in the reformatted `after`,
    /// keeping the same number of digits after the caret.
    public static func preserveCaret(_ before: String, _ caret: Int, _ after: String) -> Int {
        let b = Array(before.utf16), a = Array(after.utf16)
        var following = b[min(max(caret, 0), b.count)...].filter(isDigit).count
        if following == 0 { return a.count }
        for i in stride(from: a.count - 1, through: 0, by: -1) where isDigit(a[i]) {
            following -= 1
            if following == 0 { return i }
        }
        return 0
    }
}
