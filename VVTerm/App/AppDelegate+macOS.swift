#if os(macOS)
import AppKit
import os.log

class AppDelegate: NSObject, NSApplicationDelegate {
    private var lastForegroundSyncAt: Date = .distantPast
    private let foregroundSyncMinimumInterval: TimeInterval = 20
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm",
        category: "Lifecycle"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await CloudKitManager.shared.subscribeToChanges()
        }
        NSApplication.shared.registerForRemoteNotifications()

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        logger.info("Application became active")
        guard SyncSettings.isEnabled else { return }

        let now = Date()
        guard now.timeIntervalSince(lastForegroundSyncAt) >= foregroundSyncMinimumInterval else { return }
        lastForegroundSyncAt = now

        Task {
            await ServerManager.shared.loadData()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        logger.info("Application resigned active")
        Task { @MainActor in
            AppLockManager.shared.lockIfNeededForBackground()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        let cleanupTask = TerminalTabManager.shared.beginApplicationTermination()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await cleanupTask.value
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

    @objc private func workspaceWillSleep(_ notification: Notification) {
        logger.info("Workspace will sleep")
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        logger.info("Workspace did wake")
    }

    @objc private func screensDidSleep(_ notification: Notification) {
        logger.info("Screens did sleep")
    }

    @objc private func screensDidWake(_ notification: Notification) {
        logger.info("Screens did wake")
    }
}
#endif
