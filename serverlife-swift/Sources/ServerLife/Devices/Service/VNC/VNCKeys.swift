import AppKit

/// macOS key codes and characters → X11 keysyms, which is what RFB key events
/// carry.
enum VNCKeys {
    static let backspace: UInt32 = 0xff08, tab: UInt32 = 0xff09, returnKey: UInt32 = 0xff0d
    static let escape: UInt32 = 0xff1b, delete: UInt32 = 0xffff
    static let home: UInt32 = 0xff50, left: UInt32 = 0xff51, up: UInt32 = 0xff52, right: UInt32 = 0xff53
    static let down: UInt32 = 0xff54, pageUp: UInt32 = 0xff55, pageDown: UInt32 = 0xff56, end: UInt32 = 0xff57
    static let insert: UInt32 = 0xff63
    static let shiftL: UInt32 = 0xffe1, shiftR: UInt32 = 0xffe2, controlL: UInt32 = 0xffe3, controlR: UInt32 = 0xffe4
    static let capsLock: UInt32 = 0xffe5, altL: UInt32 = 0xffe9, altR: UInt32 = 0xffea
    static let superL: UInt32 = 0xffeb, superR: UInt32 = 0xffec

    /// Keys whose meaning does not depend on the layout, by virtual key code.
    static let byKeyCode: [UInt16: UInt32] = [
        0x24: returnKey, 0x4C: 0xff8d /* KP_Enter */, 0x30: tab, 0x33: backspace, 0x35: escape,
        0x75: delete, 0x73: home, 0x77: end, 0x74: pageUp, 0x79: pageDown,
        0x7B: left, 0x7C: right, 0x7D: down, 0x7E: up, 0x72: insert /* Help sits where Insert is */,
        0x7A: 0xffbe, 0x78: 0xffbf, 0x63: 0xffc0, 0x76: 0xffc1, 0x60: 0xffc2, 0x61: 0xffc3, // F1–F6
        0x62: 0xffc4, 0x64: 0xffc5, 0x65: 0xffc6, 0x6D: 0xffc7, 0x67: 0xffc8, 0x6F: 0xffc9, // F7–F12
        0x69: 0xffca, 0x6B: 0xffcb, 0x71: 0xffcc, 0x6A: 0xffcd, 0x40: 0xffce, 0x4F: 0xffcf, 0x50: 0xffd0, // F13–F19
        0x52: 0xffb0, 0x53: 0xffb1, 0x54: 0xffb2, 0x55: 0xffb3, 0x56: 0xffb4,                // KP_0–4
        0x57: 0xffb5, 0x58: 0xffb6, 0x59: 0xffb7, 0x5B: 0xffb8, 0x5C: 0xffb9,                // KP_5–9
        0x41: 0xffae, 0x43: 0xffaa, 0x45: 0xffab, 0x4E: 0xffad, 0x4B: 0xffaf, 0x51: 0xffbd,  // KP . * + - / =
        0x47: 0xff7f, // Clear → Num_Lock
    ]

    /// Modifier keys, by key code, with the device-dependent flag bit that
    /// says whether that particular key is down.
    static let modifiers: [UInt16: (keysym: UInt32, mask: UInt)] = [
        0x38: (shiftL, 0x0002), 0x3C: (shiftR, 0x0004),
        0x3B: (controlL, 0x0001), 0x3E: (controlR, 0x2000),
        0x3A: (altL, 0x0020), 0x3D: (altR, 0x0040),
        0x37: (superL, 0x0008), 0x36: (superR, 0x0010),
    ]

    static let capsLockKeyCode: UInt16 = 0x39

    /// A character as a keysym: Latin-1 maps to itself, anything else is
    /// 0x01000000 + the code point (the Unicode keysym range every current
    /// server understands).
    static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
        let v = scalar.value
        switch v {
        case 0x08: return backspace
        case 0x09: return tab
        case 0x0d, 0x03: return returnKey
        case 0x1b: return escape
        case 0x7f: return backspace
        case 0x20...0x7e, 0xa0...0xff: return v
        default: return v < 0x20 ? v + 0x60 : 0x0100_0000 + v
        }
    }

    /// The keysym for a key event, or nil when it produces nothing to send
    /// (a dead key mid-composition).
    static func keysym(for event: NSEvent) -> UInt32? {
        if let k = byKeyCode[event.keyCode] { return k }
        let flags = event.modifierFlags
        // With Control or Command held, the key itself (the server applies
        // the modifier); otherwise what the layout produced, so Option
        // characters and shifted symbols arrive as typed.
        let chars = (flags.contains(.control) || flags.contains(.command))
            ? event.charactersIgnoringModifiers : event.characters
        guard let s = chars, let scalar = s.unicodeScalars.first else { return nil }
        if (0xF700...0xF8FF).contains(scalar.value) { return nil }  // function-key private use area
        return keysym(for: scalar)
    }
}
