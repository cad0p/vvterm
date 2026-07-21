#if os(iOS)
import UIKit

enum AppSceneLifecyclePolicy {
    static func shouldHandleBackgroundTransition(
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
    private var eternalTerminalLifecycleTask: Task<Void, Never>?

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
            selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification,
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

        queueEternalTerminalResume()

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
        handleApplicationWillTerminate()
    }

    @discardableResult
    func handleApplicationWillTerminate() -> Bool {
        TerminalTabManager.shared.beginApplicationTermination()
        return LiveActivityManager.shared.endForApplicationTermination()
    }

    @objc
    private func sceneWillDeactivate(_ notification: Notification) {
        guard let notifyingScene = notification.object as? UIScene,
              notificationBelongsToConnectedApplicationScene(notification) else { return }
        let otherSceneStates = UIApplication.shared.connectedScenes.compactMap { scene in
            scene === notifyingScene ? nil : scene.activationState
        }
        handleSceneWillDeactivate(connectedOtherSceneStates: otherSceneStates) {
            queueEternalTerminalBackgroundPreparation()
        }
    }

    func handleSceneWillDeactivate(
        connectedOtherSceneStates: [UIScene.ActivationState],
        prepare: () -> Void
    ) {
        guard AppSceneLifecyclePolicy.shouldHandleBackgroundTransition(
            connectedSceneStates: connectedOtherSceneStates
        ) else { return }
        prepare()
    }

    @objc
    private func sceneDidEnterBackground(_ notification: Notification) {
        guard notificationBelongsToConnectedApplicationScene(notification) else { return }
        let sceneStates = UIApplication.shared.connectedScenes.map(\.activationState)
        handleSceneDidEnterBackground(
            connectedSceneStates: sceneStates,
            lock: { AppLockManager.shared.lockIfNeededForBackground() }
        )
        guard AppSceneLifecyclePolicy.shouldHandleBackgroundTransition(
            connectedSceneStates: sceneStates
        ) else { return }

        let taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "Save ET Session")
        queueEternalTerminalBackgroundPreparation {
            if taskIdentifier != .invalid {
                UIApplication.shared.endBackgroundTask(taskIdentifier)
            }
        }
    }

    func handleSceneDidEnterBackground(
        connectedSceneStates: [UIScene.ActivationState],
        lock: () -> Void
    ) {
        guard AppSceneLifecyclePolicy.shouldHandleBackgroundTransition(
            connectedSceneStates: connectedSceneStates
        ) else { return }

        lock()
    }

    private func notificationBelongsToConnectedApplicationScene(
        _ notification: Notification
    ) -> Bool {
        guard let notifyingScene = notification.object as? UIScene else { return false }
        return UIApplication.shared.connectedScenes.contains { $0 === notifyingScene }
    }

    private func queueEternalTerminalBackgroundPreparation(
        completion: @escaping @MainActor () -> Void = {}
    ) {
        let previousTask = eternalTerminalLifecycleTask
        eternalTerminalLifecycleTask = Task { @MainActor in
            await previousTask?.value
            await TerminalTabManager.shared.prepareEternalTerminalSessionsForApplicationBackground()
            completion()
        }
    }

    private func queueEternalTerminalResume() {
        let previousTask = eternalTerminalLifecycleTask
        eternalTerminalLifecycleTask = Task { @MainActor in
            await previousTask?.value
            await TerminalTabManager.shared.resumeEternalTerminalSessionsFromApplicationBackground()
        }
    }
}
#endif
