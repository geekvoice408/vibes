#if os(macOS)
import Foundation
import ServiceManagement
import EeroCore

/// Port of `WindowsStartupStore` + `StartupRegistration`: the Windows Run registry key becomes the
/// app's own login item registered through `SMAppService.mainApp` (macOS 13+). There is no command
/// line to build: macOS launches the bundle itself, so `StartupRegistration.Command` has no equivalent.
enum LoginItem {
    /// True when the app is registered to open at login (approved or awaiting approval in System Settings).
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// True when the user still has to approve the login item in System Settings > General > Login Items.
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ on: Bool) throws {
        let service = SMAppService.mainApp
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            throw EeroError.operation("macOS could not " + (on ? "add" : "remove") + " eero Desktop " + (on ? "to" : "from")
                + " your login items (" + error.localizedDescription + "). Check System Settings > General > Login Items.")
        }
    }

    /// Port of `StartupRegistration.Apply`: change the login item, then save preferences; if saving fails,
    /// restore the previous login item state and rethrow.
    static func apply(_ enabled: Bool, savePreferences: () throws -> Void) throws {
        let previous = isEnabled
        try setEnabled(enabled)
        do { try savePreferences() }
        catch { try? setEnabled(previous); throw error }
    }

    /// Opens System Settings at Login Items so the user can approve the registration.
    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
#endif
