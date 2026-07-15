import Foundation
import os.log

#if os(iOS)
import ActivityKit
#endif

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "LiveActivity"
    )

    private init() {}

    func refresh(with connectionStates: [ConnectionState]) {
        #if os(iOS)
        guard #available(iOS 16.1, *) else { return }

        requestedTarget = TerminalLiveActivityPolicy.snapshot(for: connectionStates)
            .map(ReconciliationTarget.active) ?? .end
        guard reconciliationTask == nil else { return }

        reconciliationTask = Task { [weak self] in
            await self?.reconcileRequestedSnapshots()
        }
        #endif
    }

    #if os(iOS)
    @available(iOS 16.1, *)
    private enum ReconciliationTarget: Equatable {
        case end
        case active(TerminalLiveActivitySnapshot)
    }

    @available(iOS 16.1, *)
    private var requestedTarget: ReconciliationTarget?

    @available(iOS 16.1, *)
    private var reconciliationTask: Task<Void, Never>?

    @available(iOS 16.1, *)
    private var reconciledTarget: ReconciliationTarget?

    @available(iOS 16.1, *)
    private func reconcileRequestedSnapshots() async {
        while let target = requestedTarget {
            requestedTarget = nil
            await reconcileActivity(toward: target)
        }
        reconciliationTask = nil
    }

    @available(iOS 16.1, *)
    private func reconcileActivity(toward target: ReconciliationTarget) async {
        let activities = Activity<VVTermActivityAttributes>.activities
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await end(activities)
            reconciledTarget = .end
            return
        }

        guard case .active(let snapshot) = target else {
            await end(activities)
            reconciledTarget = .end
            return
        }

        let contentState = VVTermActivityAttributes.ContentState(
            status: activityStatus(for: snapshot.status),
            activeCount: snapshot.activeCount
        )

        if let activity = activities.first {
            for duplicate in activities.dropFirst() {
                await duplicate.end(dismissalPolicy: .immediate)
            }
            guard reconciledTarget != target || activities.count > 1 else {
                return
            }
            await activity.update(using: contentState)
            reconciledTarget = target
            return
        }

        do {
            let attributes = VVTermActivityAttributes(appName: "VVTerm")
            _ = try Activity.request(
                attributes: attributes,
                contentState: contentState,
                pushType: nil
            )
            reconciledTarget = target
        } catch {
            reconciledTarget = nil
            logger.error("Failed to start Live Activity: \(String(describing: error))")
        }
    }

    @available(iOS 16.1, *)
    private func end(_ activities: [Activity<VVTermActivityAttributes>]) async {
        for activity in activities {
            await activity.end(dismissalPolicy: .immediate)
        }
    }

    private func activityStatus(
        for status: TerminalLiveActivitySnapshot.Status
    ) -> VVTermLiveActivityStatus {
        switch status {
        case .connected:
            return .connected
        case .connecting:
            return .connecting
        case .reconnecting:
            return .reconnecting
        }
    }
    #endif
}
