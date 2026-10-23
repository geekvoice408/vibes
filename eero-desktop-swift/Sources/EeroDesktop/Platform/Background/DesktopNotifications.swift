#if os(macOS)
import AppKit
import Foundation
import UserNotifications
import EeroCore

/// Holds the per-process notification state the Windows `MainWindow` kept in fields
/// (`notificationTimer`, `pollingNotifications`, `notificationJournal`). Toasts/balloon tips
/// become UserNotifications banners; the tray icon itself is provided by the app's `MenuBarExtra`.
@MainActor
final class DesktopNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DesktopNotifier()

    fileprivate var timer: Task<Void, Never>?
    fileprivate var polling = false
    fileprivate var journal: NotificationJournal?
    fileprivate var authorizationRequested = false

    /// UserNotifications aborts in a process without a bundle identifier (e.g. `swift run`), so every call is guarded.
    var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    static var journalURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EeroDesktop", isDirectory: true).appendingPathComponent("notifications-state.dat")
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        center.delegate = self
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default:
            authorizationRequested = true
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// Port of `NotifyIcon.ShowBalloonTip` (title capped at 63 and body at 240 characters, as on Windows).
    func post(title: String, body: String, identifier: String = UUID().uuidString) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(63))
        content.body = String(body.prefix(240))
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { _ in }
    }

    // Show banners while the app is frontmost too, like Windows balloon tips.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // Clicking a notification restores the window (`BalloonTipClicked` → `RestoreWindow`).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain { window.makeKeyAndOrderFront(nil); break }
        }
    }
}

extension AppModel {
    /// Port of `ConfigureDesktopNotifications`: starts or stops the one-minute notification poll
    /// according to the saved preferences. Call after sign-in and whenever preferences change.
    func configureDesktopNotifications() {
        let notifier = DesktopNotifier.shared
        if UiPreferences.notifications && !preview {
            if notifier.timer == nil {
                notifier.timer = Task { [weak self] in
                    _ = await notifier.requestAuthorization()
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                        if Task.isCancelled { break }
                        guard let self else { break }
                        await self.pollNotifications()
                    }
                }
            }
        } else {
            notifier.timer?.cancel()
            notifier.timer = nil
        }
    }

    /// Port of `SignInAttention`: tells the user that alerts stopped until they sign in again.
    func signInAttention() {
        DesktopNotifier.shared.post(title: "eero Desktop needs sign-in",
                                    body: "Open eero Desktop from the menu bar to restore network alerts.",
                                    identifier: "eero-sign-in")
    }

    /// Port of `PollNotifications`: reads each network's notification history and shows a banner for
    /// entries not seen before (the journal suppresses the first, seeding observation).
    func pollNotifications() async {
        let notifier = DesktopNotifier.shared
        guard !notifier.polling, !busy, await api.signedIn, let networkURL, !networkURL.isEmpty, UiPreferences.notifications else { return }
        notifier.polling = true
        defer { notifier.polling = false }
        // `notificationEpoch` on Windows: signing out or switching account clears `account`, which changes the owner.
        let owner = account.first("id", "user_id", "email", "phone")
        func current() async -> Bool { await api.signedIn && account.first("id", "user_id", "email", "phone") == owner }
        do {
            if notifier.journal == nil { notifier.journal = NotificationJournal(fileURL: DesktopNotifier.journalURL) }
            guard let journal = notifier.journal else { return }
            let targets: [JSON] = UiPreferences.allNetworks ? networkList : [JSON.obj(("url", networkURL), ("name", network.s("name")))]
            for target in targets {
                if !UiPreferences.notifications { return }
                if !(await current()) { return }
                let url = target.s("url")
                if url.isEmpty { continue }
                let data: JSON
                do { data = try await api.send("GET", url.trimmingSuffix("/") + "/notifications_history?limit=50") }
                catch let e as ApiError { if e.sessionExpired { throw e }; continue }
                if !(await current()) { return }
                let fresh = try journal.observe(owner, url, Self.notificationEntries(data))
                guard let latest = fresh.last, UiPreferences.notifications else { continue }
                let title = fresh.count == 1 ? (latest.s("title").nilIfEmpty ?? "eero network notification") : "\(fresh.count) eero network updates"
                let body = (target.s("name").nilIfEmpty ?? "Your network") + ": " + (latest.s("body").nilIfEmpty ?? "Open eero Desktop to view the update.")
                notifier.post(title: title, body: body)
            }
            try journal.save()
        } catch let e as ApiError where e.sessionExpired {
            await api.forget(); clearData(); screen = .login(verify: false)
            setNotice("Sign in again to restore network alerts.", error: true)
            signInAttention()
        } catch {
            // Background polling never interrupts the user (the Windows client ignores other failures too).
        }
    }

    /// Port of `Entries(data, "notifications", "items")`.
    static func notificationEntries(_ data: JSON) -> [JSON] {
        let direct = data.list
        if !direct.isEmpty { return direct }
        for name in ["notifications", "items"] { let a = data[name].list; if !a.isEmpty { return a } }
        return []
    }
}
#endif
