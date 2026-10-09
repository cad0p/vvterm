// SPDX-License-Identifier: MIT
//
//  LatchRecordingCoordinators.swift
//  VVTermTests
//
//  Host-side wrappers around the package coordinators that expose the
//  dismissal latch the view-wiring tests await. The package's
//  `isDismissalLatched` is internal to `TeleportAuth`, so the host records the
//  view's `latchDismissal()` call at the protocol boundary instead, and the
//  wrapper forwards everything else to the real coordinator.
//
//  See:
//    - VVTermTests/Features/Teleport/TeleportBootstrapViewWiringTests.swift
//    - VVTermTests/Features/Teleport/TeleportLoginDismissalWiringTests.swift
//

#if DEBUG
import Combine
import Foundation
import TeleportCore
import TeleportAuth

@MainActor
final class LatchRecordingLoginCoordinator: ObservableObject, TeleportLoginCoordinating {
    let inner: TeleportLoginCoordinator
    private(set) var isDismissalLatched = false

    init(inner: TeleportLoginCoordinator) {
        self.inner = inner
    }

    var state: TeleportLoginState { inner.state }
    var objectWillChange: ObservableObjectPublisher { inner.objectWillChange }

    func begin(cluster: TeleportCluster) async { await inner.begin(cluster: cluster) }
    func cancel() async { await inner.cancel() }

    func latchDismissal() {
        isDismissalLatched = true
        inner.latchDismissal()
    }
}

@MainActor
final class LatchRecordingBootstrapCoordinator: ObservableObject, TeleportBootstrapCoordinating {
    let inner: TeleportBootstrapCoordinator
    private(set) var isDismissalLatched = false

    init(inner: TeleportBootstrapCoordinator) {
        self.inner = inner
    }

    var state: TeleportBootstrapState { inner.state }
    var lastBootstrapResult: TeleportBootstrapCoordinator.BootstrapResult? { inner.lastBootstrapResult }
    var objectWillChange: ObservableObjectPublisher { inner.objectWillChange }

    func begin(cluster: TeleportCluster) async { await inner.begin(cluster: cluster) }
    func cancel() async { await inner.cancel() }
    func retry() async { await inner.retry() }

    func latchDismissal() {
        isDismissalLatched = true
        inner.latchDismissal()
    }
}
#endif
