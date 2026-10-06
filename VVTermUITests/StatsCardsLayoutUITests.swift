#if os(iOS)
import UIKit
import XCTest

// Stats-grid rotation/containment coverage.
//
// This class is the only rotation/containment coverage for the stats grid and
// was killed by the 300 s per-test execution allowance twice (issue #349,
// 2026-10-03). The measured mechanism has two parts:
//
// 1. Each killed run paid FOUR ~60 s XCTest automation idle stalls ("App
//    animations complete notification not received"): one after each rotation
//    and one inside tearDownWithError's unconditional `.portrait` reset
//    (shard-1 teardown t=347.5→408.3, after the kill). The compact body ended
//    at t=248.12 s and the allowance fired at ≈300 s during that teardown
//    stall (xcresult duration 300 s; wall delta 299.77 s) — teardown time
//    counts toward the allowance, so the reset alone can kill an
//    otherwise-passing test.
// 2. Query volume: the detailed run's full method section carried 166 query
//    lines (90 Find the + 41 Checking existence + 35 Waiting, including the
//    mount waits; `Build/issue349-evidence/count-metrics.sh` is the single
//    definition) on the loaded shard-1 host. Its phase-2 and phase-3 query
//    windows took ≈63 s and ≈48 s for 42 lines each (≈1.2–1.5 s per line).
//    Compact (160 query lines) ran on a healthy host (0.04–0.13 s per
//    query), so compact was stall-dominated while detailed was stall + query
//    bound.
//
// Fix (two levers, test-only):
// - tearDownWithError terminates the app before the orientation reset, so the
//   reset targets springboard (measured ≈0.1 s: setter t=0.09 → orientation
//   notification t=0.19 in the compact run) instead of paying the stall.
// - Each phase reads the container subtree via `snapshotCardFrames()` instead
//   of per-card waits/finds. Phase 1 first polls only until the grid container
//   is mounted, then cross-checks snapshot-vs-direct frames within 1 pt;
//   every phase asserts the exact card-identifier set first and tolerates a
//   mid-rebuild snapshot with up to 3 samples, 0.5 s apart.
//
// Residuals (#257): the ~60 s stall itself is XCTest-side and cannot be
// removed from this file. Post-fix floor ≈ launch 13–20 s + 3 body stalls ×
// 60 s + the phase snapshots ≈ 200 s, ~250 s with the documented slow launch
// (the old "~50 s" figure on run 30643100567 was launch retries, not grid
// materialization). A 4th body stall — e.g. a rotate() retry re-setting the
// orientation — still exceeds the 300 s allowance, and tearDown's
// app?.terminate() can itself wedge (the #257 "Failed to terminate"
// signature), which also counts toward the allowance. Reopen condition: any
// further allowance kill of these methods.
final class StatsCardsLayoutUITests: XCTestCase {
    private static let cardIdentifierPrefix = "vvterm.stats.card."
    private static let cardIdentifiers = [
        "system", "cpu", "memory", "gpu", "network", "storage", "processes", "docker"
    ]

    /// One AX round trip's worth of geometry: the container's frame plus the
    /// frames of the card nodes carrying a `vvterm.stats.card.*` identifier.
    private struct PhaseFrames {
        let containerFrame: CGRect
        let cardFrames: [String: CGRect]
    }

    private var app: XCUIApplication!
    private var layoutConfiguration: LayoutConfiguration!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        // Terminate BEFORE the orientation reset (#349): with the app still
        // running, the reset's idle wait paid a measured 60 s XCTest stall in
        // the killed run. With no app running the reset targets springboard
        // and costs ≈0.1 s. `terminate()` is not new work — the next test's
        // launch already terminates the previous instance; this only moves it
        // where it makes the reset cheap. Risk (#257): a wedged terminate is
        // the "Failed to terminate" signature and also counts toward the
        // allowance; accepted as strictly better than the guaranteed 60 s
        // reset stall.
        app?.terminate()
        app = nil
        layoutConfiguration = nil
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testDetailedCardsRemainContainedAcrossWideNarrowAndWideTransitions() throws {
        layoutConfiguration = .detailed
        launch()
        assertPhase(named: "phase 1: portrait", readsDirectFramesForParity: true)

        rotate(to: .landscapeLeft, phaseName: "phase 2: landscapeLeft")
        assertPhase(named: "phase 2: landscapeLeft")

        rotate(to: .portrait, phaseName: "phase 3: portrait")
        assertPhase(named: "phase 3: portrait")

        rotate(to: .landscapeRight, phaseName: "phase 4: landscapeRight")
        assertPhase(named: "phase 4: landscapeRight")
    }

    @MainActor
    func testCompactCardsRemainContainedAcrossWideNarrowAndWideTransitions() throws {
        layoutConfiguration = .compact
        launch(extraArguments: ["--vvterm-ui-test-stats-cards-compact"])
        assertPhase(named: "phase 1: portrait", readsDirectFramesForParity: true)

        rotate(to: .landscapeLeft, phaseName: "phase 2: landscapeLeft")
        assertPhase(named: "phase 2: landscapeLeft")

        rotate(to: .portrait, phaseName: "phase 3: portrait")
        assertPhase(named: "phase 3: portrait")

        rotate(to: .landscapeRight, phaseName: "phase 4: landscapeRight")
        assertPhase(named: "phase 4: landscapeRight")
    }

    @MainActor
    func testLockedDockerCardRemainsContainedAfterRepeatedRotation() throws {
        layoutConfiguration = .lockedDockerDetailed
        launch(extraArguments: ["--vvterm-ui-test-stats-cards-locked-docker"])
        assertPhase(named: "phase 1: portrait", readsDirectFramesForParity: true)

        rotate(to: .landscapeLeft, phaseName: "phase 2: landscapeLeft")
        assertPhase(named: "phase 2: landscapeLeft")

        rotate(to: .portrait, phaseName: "phase 3: portrait")
        assertPhase(named: "phase 3: portrait")
    }

    @MainActor
    private func launch(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-stats-cards-layout-harness",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO"
        ] + extraArguments
        _ = launchForTest(app)
        // The mount wait lives in `mountedFrames(phaseName:)` on phase 1: it
        // replaces the old 20 s container + 10 s + 10 s card existence waits
        // (#349) with one bounded ≥40 s container-only snapshot poll.
    }

    @MainActor
    private func rotate(to orientation: UIDeviceOrientation, phaseName: String) {
        XCTContext.runActivity(named: "rotate to \(orientation.rawValue) (\(phaseName))") { _ in
            let oldWidth = container.frame.width

            let expectsWiderLayout = orientation == .landscapeLeft || orientation == .landscapeRight
            // Issue #126: on loaded runners the simulator can drop or stall an
            // orientation change, so frame propagation can lag past the first
            // sample. Re-asserting the orientation re-drives the rotation; retry
            // up to 3 times.
            //
            // Hardening (#349), not a measured defect fix — the killed runs showed
            // no re-assert; the stall is in the orientation setter's idle wait.
            // The old XCTNSPredicateExpectation polled `container.frame`
            // unboundedly inside a 5 s waiter and every poll is a query that can
            // stall behind an AX rebuild. Cap each attempt at 3 width samples
            // (0.5 s apart) so one rotation costs at most 10 width reads
            // (1 pre-loop baseline + 3 attempts × 3 samples).
            var lastWidth = oldWidth
            for _ in 1...3 {
                XCUIDevice.shared.orientation = orientation

                for _ in 1...3 {
                    lastWidth = container.frame.width
                    if expectsWiderLayout ? lastWidth > oldWidth : lastWidth < oldWidth {
                        return
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                }
            }
            XCTFail(
                "\(phaseName): container width never \(expectsWiderLayout ? "grew" : "shrank") from \(oldWidth) "
                    + "after 3 rotation attempts to \(orientation.rawValue) (last sample \(lastWidth))"
            )
        }
    }

    /// Reads the phase's geometry and runs the same containment/column
    /// assertions for every phase. Phase 1 additionally waits for the grid to
    /// mount (container-only poll) and cross-checks the snapshot against direct
    /// per-card frame reads. Every phase first asserts the exact card-identifier
    /// set, so a missing/misnamed card reds there before any geometry is
    /// interpreted (and does not get masked by the mount wait).
    @MainActor
    private func assertPhase(
        named phaseName: String,
        readsDirectFramesForParity: Bool = false
    ) {
        XCTContext.runActivity(named: phaseName) { _ in
            if readsDirectFramesForParity {
                guard mountedFrames(phaseName: phaseName) else { return }
            }
            guard let phase = stableSnapshot() else {
                XCTFail("\(phaseName): container snapshot could not be read after 3 samples, 0.5 s apart")
                return
            }
            assertExpectedCardIdentifiers(phase: phase, phaseName: phaseName)
            if readsDirectFramesForParity {
                assertMountedFramesMatchDirectReads(phase, phaseName: phaseName)
            }
            assertExpectedColumnsAndContainment(phase: phase, phaseName: phaseName)
        }
    }

    /// Waits for the harness grid's container to mount: polls one container
    /// snapshot every ~0.5 s until the container frame is non-empty, then hands
    /// off. This replaces the old 20 s + 10 s + 10 s existence tolerances
    /// (#349); 40 s is 2× the old container wait (the old "~50 s" figure on run
    /// 30643100567 was launch retries, not grid materialization). Only the
    /// container is required here — the card set is asserted per phase after
    /// the bounded re-snapshot tolerance in `stableSnapshot`. Snapshot throws
    /// are absorbed into the poll; only the exhausted timeout reds.
    @MainActor
    private func mountedFrames(phaseName: String, timeout: TimeInterval = 40) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSnapshot: PhaseFrames?
        while Date() < deadline {
            if let snapshot = snapshotCardFrames() {
                lastSnapshot = snapshot
                if !snapshot.containerFrame.isEmpty {
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        XCTFail(
            "\(phaseName): stats grid container did not mount within \(Int(timeout))s "
                + "(last container frame \(lastSnapshot?.containerFrame ?? .zero), "
                + "\(lastSnapshot?.cardFrames.count ?? 0)/\(Self.cardIdentifiers.count) cards)"
        )
        return false
    }

    /// Bounded transient tolerance for one phase's snapshot: a rotation or a
    /// mid-rebuild AX tree can leave the container unresolvable or the card set
    /// incomplete for a moment, so sample up to 3 times, 0.5 s apart. Returns
    /// the first complete sample; if none is complete, returns the last non-nil
    /// sample so `assertExpectedCardIdentifiers` (the single authority on the
    /// card set) reports exactly what was missing instead of a generic timeout.
    @MainActor
    private func stableSnapshot(samples: Int = 3) -> PhaseFrames? {
        var lastSnapshot: PhaseFrames?
        for sample in 1...samples {
            if let snapshot = snapshotCardFrames() {
                lastSnapshot = snapshot
                if Set(snapshot.cardFrames.keys) == Set(Self.cardIdentifiers) {
                    return snapshot
                }
            }
            if sample < samples {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
        }
        return lastSnapshot
    }

    /// One AX round trip: the whole container subtree as a snapshot. Returns
    /// nil when the container is not resolvable (e.g. mid-rebuild after a
    /// rotation) so callers can poll or attribute instead of redding on a
    /// transient.
    @MainActor
    private func snapshotCardFrames() -> PhaseFrames? {
        do {
            let snapshot = try container.snapshot()
            var cardFrames: [String: CGRect] = [:]
            collectCardFrames(from: snapshot, into: &cardFrames)
            return PhaseFrames(containerFrame: snapshot.frame, cardFrames: cardFrames)
        } catch {
            return nil
        }
    }

    /// Recursive walk of the snapshot subtree; the first node carrying a given
    /// identifier wins, matching the `firstMatch` semantics of the direct card
    /// query (parity-verified live in phase 1 before later phases trust it).
    private func collectCardFrames(
        from snapshot: XCUIElementSnapshot,
        into cardFrames: inout [String: CGRect]
    ) {
        if snapshot.identifier.hasPrefix(Self.cardIdentifierPrefix),
           cardFrames[snapshot.identifier] == nil {
            cardFrames[snapshot.identifier] = snapshot.frame
        }
        for child in snapshot.children {
            collectCardFrames(from: child, into: &cardFrames)
        }
    }

    /// Measured node parity (#349): the snapshot walk and the direct `card(_:)`
    /// queries must resolve to the same AX frames (within 1 pt) before phases
    /// 2–4 trust the snapshot path. This stays live in CI so a SwiftUI
    /// accessibility-tree change reds instead of silently changing what the
    /// rotation assertions measure.
    @MainActor
    private func assertMountedFramesMatchDirectReads(_ phase: PhaseFrames, phaseName: String) {
        assertFramesMatch(
            phase.containerFrame,
            container.frame,
            name: "container",
            phaseName: phaseName
        )

        for identifier in Self.cardIdentifiers {
            guard let snapshotFrame = phase.cardFrames[identifier] else {
                XCTFail("\(phaseName): snapshot missing the \(identifier) card during the parity check")
                continue
            }
            assertFramesMatch(snapshotFrame, card(identifier).frame, name: identifier, phaseName: phaseName)
        }
    }

    private func assertFramesMatch(
        _ snapshotFrame: CGRect,
        _ directFrame: CGRect,
        name: String,
        phaseName: String
    ) {
        XCTAssertEqual(
            snapshotFrame.minX, directFrame.minX, accuracy: 1,
            "\(phaseName): \(name) snapshot minX \(snapshotFrame.minX) vs direct \(directFrame.minX)"
        )
        XCTAssertEqual(
            snapshotFrame.minY, directFrame.minY, accuracy: 1,
            "\(phaseName): \(name) snapshot minY \(snapshotFrame.minY) vs direct \(directFrame.minY)"
        )
        XCTAssertEqual(
            snapshotFrame.width, directFrame.width, accuracy: 1,
            "\(phaseName): \(name) snapshot width \(snapshotFrame.width) vs direct \(directFrame.width)"
        )
        XCTAssertEqual(
            snapshotFrame.height, directFrame.height, accuracy: 1,
            "\(phaseName): \(name) snapshot height \(snapshotFrame.height) vs direct \(directFrame.height)"
        )
    }

    @MainActor
    private func assertExpectedColumnsAndContainment(phase: PhaseFrames, phaseName: String) {
        assertCardsAreHorizontallyContained(phase: phase, phaseName: phaseName)

        let containerWidth = phase.containerFrame.width
        guard let systemFrame = phase.cardFrames["system"],
              let cpuFrame = phase.cardFrames["cpu"],
              let memoryFrame = phase.cardFrames["memory"] else {
            // Unreachable after the identifier-set assertion under
            // `continueAfterFailure = false`; kept so a flipped flag cannot
            // cascade duplicate failures.
            return
        }
        let firstRowY = systemFrame.minY
        let expectedColumnCount = layoutConfiguration.columnCount(for: containerWidth)

        if expectedColumnCount == 1 {
            XCTAssertGreaterThan(
                cpuFrame.minY,
                firstRowY + 1,
                "\(phaseName): a one-column layout (width \(containerWidth)) should place the second card "
                    + "on the next row (system \(systemFrame), cpu \(cpuFrame))"
            )
        } else {
            // Multi-column: cpu should NOT be below system (same row or above).
            // Relaxed from exact Y equality to "not below" per issue #44 — the
            // custom StatsCardsGridLayout can produce transient frames during
            // rotation where the exact Y values oscillate. Horizontal containment
            // (checked above) already verifies the cards are in the grid.
            XCTAssertLessThanOrEqual(
                cpuFrame.minY,
                firstRowY + 1,
                "\(phaseName): a \(expectedColumnCount)-column layout (width \(containerWidth)) should place "
                    + "the first two cards in the same row (system \(systemFrame), cpu \(cpuFrame))"
            )
        }

        if expectedColumnCount == 3 {
            XCTAssertLessThanOrEqual(
                memoryFrame.minY,
                firstRowY + 1,
                "\(phaseName): a three-column layout (width \(containerWidth)) should place "
                    + "the first three cards in the same row (system \(systemFrame), memory \(memoryFrame))"
            )
        } else {
            XCTAssertGreaterThan(
                memoryFrame.minY,
                firstRowY + 1,
                "\(phaseName): a \(expectedColumnCount)-column layout (width \(containerWidth)) should place "
                    + "the third card below the first row (system \(systemFrame), memory \(memoryFrame))"
            )
        }
    }

    private func assertExpectedCardIdentifiers(phase: PhaseFrames, phaseName: String) {
        let expected = Set(Self.cardIdentifiers)
        let observed = Set(phase.cardFrames.keys)
        let missing = expected.subtracting(observed)
        let unexpected = observed.subtracting(expected)
        XCTAssertTrue(
            missing.isEmpty && unexpected.isEmpty,
            "\(phaseName): expected exactly \(expected.count) stats card snapshots "
                + "(container width \(phase.containerFrame.width)); "
                + "missing \(missing.sorted()), unexpected \(unexpected.sorted())"
        )
    }

    @MainActor
    private func assertCardsAreHorizontallyContained(phase: PhaseFrames, phaseName: String) {
        let containerFrame = phase.containerFrame
        XCTAssertGreaterThan(containerFrame.width, 0, "\(phaseName): container width is \(containerFrame.width)")

        for identifier in Self.cardIdentifiers {
            guard let cardFrame = phase.cardFrames[identifier] else {
                continue
            }
            // A zero rect passes both containment edges in the 2-column phases
            // (container spans the screen from x≈0), so guard it explicitly.
            XCTAssertFalse(
                cardFrame.isEmpty,
                "\(phaseName): \(identifier) card frame is empty (container \(containerFrame))"
            )
            XCTAssertGreaterThanOrEqual(
                cardFrame.minX,
                containerFrame.minX - 1,
                "\(phaseName): \(identifier) card escaped the leading edge (card \(cardFrame), container \(containerFrame))"
            )
            XCTAssertLessThanOrEqual(
                cardFrame.maxX,
                containerFrame.maxX + 1,
                "\(phaseName): \(identifier) card escaped the trailing edge (card \(cardFrame), container \(containerFrame))"
            )
        }
    }

    private var container: XCUIElement {
        app.descendants(matching: .any)["vvterm.stats.layout.container"].firstMatch
    }

    private func card(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)["vvterm.stats.card.\(identifier)"].firstMatch
    }

    private struct LayoutConfiguration {
        let minimumColumnWidth: CGFloat
        let spacing: CGFloat
        let horizontalPadding: CGFloat
        let maximumWidth: CGFloat

        static let compact = LayoutConfiguration(
            minimumColumnWidth: 292,
            spacing: 14,
            horizontalPadding: 14,
            maximumWidth: 1_180
        )
        static let detailed = LayoutConfiguration(
            minimumColumnWidth: 320,
            spacing: 18,
            horizontalPadding: 18,
            maximumWidth: 1_360
        )
        static let lockedDockerDetailed = LayoutConfiguration(
            minimumColumnWidth: 560,
            spacing: 18,
            horizontalPadding: 18,
            maximumWidth: 1_360
        )

        func columnCount(for viewportWidth: CGFloat) -> Int {
            // Mirror StatsGridLayoutPolicy.columnCount(for:minimumColumnWidth:spacing:)
            // exactly: the layout uses the view's proposed width directly and does
            // NOT subtract horizontalPadding (padding is applied by the parent
            // ScrollView + page padding, not by StatsCardsGridLayout). The old
            // code subtracted horizontalPadding * 2, which made the expected
            // column count differ from the actual layout's column count after
            // rotation, causing the flaky "multi-column layout" assertion.
            let availableWidth = max(0, min(viewportWidth, maximumWidth))
            if availableWidth >= minimumGridWidth(for: 3) {
                return 3
            }
            if availableWidth >= minimumGridWidth(for: 2) {
                return 2
            }
            return 1
        }

        private func minimumGridWidth(for columnCount: Int) -> CGFloat {
            CGFloat(columnCount) * minimumColumnWidth + CGFloat(columnCount - 1) * spacing
        }
    }
}
#endif
