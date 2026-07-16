#if os(iOS)
import UIKit

enum AppSceneLifecyclePolicy {
    static func shouldSuspendTerminals(
        connectedSceneStates: [UIScene.ActivationState]
    ) -> Bool {
        !connectedSceneStates.contains { state in
            switch state {
            case .foregroundActive, .foregroundInactive:
                true
            case .background, .unattached:
                false
            @unknown default:
                true
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    private var lastForegroundSyncAt: Date = .distantPast
    private let foregroundSyncMinimumInterval: TimeInterval = 20

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task {
            await CloudKitManager.shared.subscribeToChanges()
        }
        application.registerForRemoteNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidBecomeActive(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidEnterBackground(_:)),
            name: UIScene.didEnterBackgroundNotification,
            object: nil
        )

        return true
    }

    @objc
    private func sceneDidBecomeActive(_ notification: Notification) {
        guard notificationBelongsToConnectedApplicationScene(notification) else { return }
        TerminalTabManager.shared.noteForegroundActivation()

        guard SyncSettings.isEnabled else { return }

        let now = Date()
        guard now.timeIntervalSince(lastForegroundSyncAt) >= foregroundSyncMinimumInterval else { return }
        lastForegroundSyncAt = now

        Task {
            await ServerManager.shared.loadData()
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard SyncSettings.isEnabled else {
            completionHandler(.noData)
            return
        }

        Task {
            await ServerManager.shared.loadData()
            completionHandler(.newData)
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            TerminalTabManager.shared.disconnectAll()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    @objc
    private func sceneDidEnterBackground(_ notification: Notification) {
        guard notificationBelongsToConnectedApplicationScene(notification) else { return }
        let sceneStates = UIApplication.shared.connectedScenes.map(\.activationState)
        handleSceneDidEnterBackground(
            connectedSceneStates: sceneStates,
            lock: { AppLockManager.shared.lockIfNeededForBackground() },
            suspendTerminals: { TerminalTabManager.shared.beginBackgroundSuspension() }
        )
    }

    func handleSceneDidEnterBackground(
        connectedSceneStates: [UIScene.ActivationState],
        lock: () -> Void,
        suspendTerminals: () -> Void
    ) {
        guard AppSceneLifecyclePolicy.shouldSuspendTerminals(
            connectedSceneStates: connectedSceneStates
        ) else { return }

        lock()
        suspendTerminals()
    }

    private func notificationBelongsToConnectedApplicationScene(
        _ notification: Notification
    ) -> Bool {
        guard let notifyingScene = notification.object as? UIScene else { return false }
        return UIApplication.shared.connectedScenes.contains { $0 === notifyingScene }
    }
}
#endif
