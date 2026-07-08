#if os(macOS)
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var lastForegroundSyncAt: Date = .distantPast
    private let foregroundSyncMinimumInterval: TimeInterval = 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await CloudKitManager.shared.subscribeToChanges()
        }
        NSApplication.shared.registerForRemoteNotifications()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard SyncSettings.isEnabled else { return }

        let now = Date()
        guard now.timeIntervalSince(lastForegroundSyncAt) >= foregroundSyncMinimumInterval else { return }
        lastForegroundSyncAt = now

        Task {
            await ServerManager.shared.loadData()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        Task { @MainActor in
            AppLockManager.shared.lockIfNeededForBackground()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            TerminalTabManager.shared.disconnectAll()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard SyncSettings.isEnabled else { return }
        Task {
            await ServerManager.shared.loadData()
        }
    }
}
#endif
