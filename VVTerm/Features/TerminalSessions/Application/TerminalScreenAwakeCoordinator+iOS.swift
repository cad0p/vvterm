#if os(iOS)
import Combine
import Foundation
import UIKit

/// Aggregates visible terminal routes because the iOS idle timer is shared by
/// every VVTerm window in the process.
@MainActor
final class TerminalScreenAwakeCoordinator: ObservableObject {
    private var requestingRouteIDs: Set<UUID> = []
    private let setIdleTimerDisabled: @MainActor (Bool) -> Void

    convenience init() {
        self.init {
            UIApplication.shared.isIdleTimerDisabled = $0
        }
    }

    init(setIdleTimerDisabled: @escaping @MainActor (Bool) -> Void) {
        self.setIdleTimerDisabled = setIdleTimerDisabled
    }

    nonisolated static func shouldRequest(
        preferenceEnabled: Bool,
        routeVisible: Bool,
        terminalSelected: Bool,
        sceneIsInBackground: Bool
    ) -> Bool {
        preferenceEnabled
            && routeVisible
            && terminalSelected
            && !sceneIsInBackground
    }

    func update(isRequested: Bool, for routeID: UUID) {
        let wasIdleTimerDisabled = !requestingRouteIDs.isEmpty

        if isRequested {
            requestingRouteIDs.insert(routeID)
        } else {
            requestingRouteIDs.remove(routeID)
        }

        let shouldDisableIdleTimer = !requestingRouteIDs.isEmpty
        guard shouldDisableIdleTimer != wasIdleTimerDisabled else { return }
        setIdleTimerDisabled(shouldDisableIdleTimer)
    }
}
#endif
