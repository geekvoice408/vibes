import SwiftUI
import AppKit

/// Real `NSTextField`/`NSSecureTextField` pair (not SwiftUI's `TextField`/`SecureField`) so we
/// can wire up what Apple's "Meet Password AutoFill for your Mac app" (WWDC20) session
/// describes: `contentType` on each field plus a `nextKeyView` link between them is what makes
/// AppKit show the key/chevron AutoFill accessory and treat the two as one credential pair.
/// SwiftUI's own field types don't expose `nextKeyView`, so the accessory either doesn't show
/// on the username field or shows without being linked to the password field.
struct NativeCredentialFieldsView: NSViewRepresentable {
    @Binding var username: String
    @Binding var password: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSStackView {
        let usernameField = NSTextField(string: username)
        usernameField.placeholderString = "Username"
        usernameField.contentType = .username
        usernameField.bezelStyle = .roundedBezel
        usernameField.delegate = context.coordinator

        let passwordField = NSSecureTextField(string: password)
        passwordField.placeholderString = "Password"
        passwordField.contentType = .password
        passwordField.bezelStyle = .roundedBezel
        passwordField.delegate = context.coordinator

        usernameField.nextKeyView = passwordField

        let stack = NSStackView(views: [usernameField, passwordField])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = Theme.space[2]
        stack.distribution = .fill

        context.coordinator.usernameField = usernameField
        context.coordinator.passwordField = passwordField
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        if let field = context.coordinator.usernameField, field.stringValue != username {
            field.stringValue = username
        }
        if let field = context.coordinator.passwordField, field.stringValue != password {
            field.stringValue = password
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(username: $username, password: $password, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var usernameField: NSTextField?
        weak var passwordField: NSTextField?
        let username: Binding<String>
        let password: Binding<String>
        let onSubmit: () -> Void

        init(username: Binding<String>, password: Binding<String>, onSubmit: @escaping () -> Void) {
            self.username = username
            self.password = password
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if field === usernameField {
                username.wrappedValue = field.stringValue
            } else if field === passwordField {
                password.wrappedValue = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit()
            return true
        }
    }
}
