// SPDX-License-Identifier: MIT
//
//  TerminalKeyboardCoordinatorObserverTeardownTests.swift
//  VVTermTests
//
//  #308 runtime regression: a `TerminalKeyboardCoordinator` released without any
//  explicit cleanup path must still remove its five `keyboardObservers` tokens
//  from NotificationCenter.
//
//  WHY THIS IS NOT GREEN BY CONSTRUCTION: the coordinator exists only as
//  `TerminalTabManager.shared`'s stored `let`, so no caller invokes teardown;
//  its `nonisolated deinit` is the only lifetime event. NotificationCenter
//  strongly retains a block-based observer's token until `removeObserver` is
//  called, and the registration blocks capture `[weak self]`, so the
//  coordinator deallocates while the tokens survive — exactly what this test
//  observes through weak boxes. Before the #308 fix the token assertions fail
//  while the coordinator assertion passes.
//
//  RESIDUAL (stated, not hidden): this is a simulator runtime observation, not
//  a device one, and it does not exercise the pending-task cancel (no task is
//  scheduled here; the source pin covers that half).
//

#if os(iOS)
import Foundation
import Testing

@testable import VVTerm

/// `.serialized` so no parallel suite's keyboard notification can interleave a
/// queued `DispatchQueue.main.async` block into the assertion window.
@Suite(.serialized)
@MainActor
struct TerminalKeyboardCoordinatorObserverTeardownTests {

    /// A weak box so the test can observe the token's lifetime without
    /// becoming the strong owner that keeps it alive.
    private final class WeakBox {
        weak var value: AnyObject?

        init(_ value: AnyObject? = nil) {
            self.value = value
        }
    }

    @Test
    func coordinatorReleasedWithoutCleanupRemovesEveryKeyboardObserver() {
        let weakCoordinator = WeakBox()
        let tokenBoxes: [WeakBox] = autoreleasepool {
            let coordinator = TerminalKeyboardCoordinator(lifecycleLoggingEnabled: false)
            weakCoordinator.value = coordinator
            let boxes = Self.mirroredKeyboardObservers(of: coordinator)

            // Positive controls, count first: an empty or renamed Mirror must
            // fail here, not pass the death assertions vacuously below.
            // `withExtendedLifetime` because Swift only guarantees a local's
            // lifetime to its last use: `mirroredKeyboardObservers(of:)` is the
            // coordinator's last syntactic use, so under optimized ARC it could
            // deallocate (and correctly remove the tokens) before these controls
            // run, false-redding them. Latent today (tests run Debug); pinned so
            // it cannot become real.
            withExtendedLifetime(coordinator) {
                #expect(boxes.count == 5, "the Mirror must find all five registrations")
                for (index, box) in boxes.enumerated() {
                    #expect(box.value != nil, "keyboardObservers[\(index)] must be alive inside the construction scope")
                }
                #expect(weakCoordinator.value != nil, "the coordinator must still be alive inside the construction scope")
            }
            return boxes
        }

        // The only strong reference went out of scope with the pool. The deinit
        // is synchronous, so no run-loop pump is needed: the coordinator and all
        // five tokens must be gone immediately.
        #expect(weakCoordinator.value == nil, "the coordinator must deallocate once its last reference is dropped (its deinit must run)")
        for (index, box) in tokenBoxes.enumerated() {
            #expect(box.value == nil, "the coordinator's deinit must remove keyboardObservers[\(index)]; a surviving token is the #308 leak")
        }
    }

    // MARK: - Helpers

    /// Reads the private `keyboardObservers` array into weak boxes. The
    /// `Mirror` and the unwrapped array are locals of this call and die with
    /// its frame, so the returned boxes are the only surviving handles and they
    /// are weak.
    private static func mirroredKeyboardObservers(of coordinator: TerminalKeyboardCoordinator) -> [WeakBox] {
        let mirror = Mirror(reflecting: coordinator)
        guard let child = mirror.children.first(where: { $0.label == "keyboardObservers" }),
              let tokens = child.value as? [NSObjectProtocol] else {
            return []
        }
        return tokens.map { token in
            let box = WeakBox()
            box.value = token
            return box
        }
    }
}
#endif
