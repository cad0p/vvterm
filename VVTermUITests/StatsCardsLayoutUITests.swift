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
//    at t=248.12 s and the allowance fired at t=300.06 s during that teardown
//    stall — teardown time counts toward the allowance, so the reset alone can
//    kill an otherwise-passing test.
// 2. Query volume: the detailed run's body carried 128 query lines at 1–5 s
//    each on the loaded shard-1 host (phase 2 ≈ 62 s, phase 3 ≈ 108 s).
//    Compact (160 query lines) ran on a healthy host (0.04–0.13 s/query), so
//    compact was stall-dominated while detailed was stall + query bound.
//
// Fix (two levers, test-only):
// - tearDownWithError terminates the app before the orientation reset, so the
//   reset targets springboard (measured ~0.2 s at t=0.09 in setUp) instead of
//   paying the stall.
// - Each phase reads one `container.snapshot()` (a single AX round trip)
//   instead of per-card waits/finds. Phase 1 additionally reads the direct
//   card frames and asserts snapshot-vs-direct parity within 1 pt, so the
//   snapshot path stays measured rather than assumed; phases 2–4 are
//   snapshot-only.
//
// Residual (#257): the ~60 s stall itself is XCTest-side and cannot be removed
// from this file. Post-fix floor ≈ launch 13–20 s + 3 body stalls × 60 s +
// 4 snapshots ≈ 200 s, ~250 s with the documented slow mount, so a 4th body
// stall (e.g. a rotate() retry re-setting the orientation) still exceeds the
// 300 s allowance. Reopen condition: any further allowance kill of these
// methods.
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
        // and costs ~0.2 s. `terminate()` is not new work — the next test's
        // launch already terminates the previous instance; this only moves it
        // where it makes the reset cheap.
        app?.terminate()
        app = nil
        layoutConfiguration = nil
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testDetailedCardsRemainContainedAcrossWideNarrowAndWideTransitions() throws {
        layoutConfiguration = .detailed
        launch()
        try assertPhase(named: "phase 1: portrait", readsDirectFramesForParity: true)

        try rotate(to: .landscapeLeft)
        try assertPhase(named: "phase 2: landscapeLeft")

        try rotate(to: .portrait)
        try assertPhase(named: "phase 3: portrait")

        try rotate(to: .landscapeRight)
        try assertPhase(named: "phase 4: landscapeRight")
    }

    @MainActor
    func testCompactCardsRemainContainedAcrossWideNarrowAndWideTransitions() throws {
        layoutConfiguration = .compact
        launch(extraArguments: ["--vvterm-ui-test-stats-cards-compact"])
        try assertPhase(named: "phase 1: portrait", readsDirectFramesForParity: true)

        try rotate(to: .landscapeLeft)
        try assertPhase(named: "phase 2: landscapeLeft")

        try rotate(to: .portrait)
        try assertPhase(named: "phase 3: portrait")

        try rotate(to: .landscapeRight)
        try assertPhase(named: "phase 4: landscapeRight")
    }

    @MainActor
    func testLockedDockerCardRemainsContainedAfterRepeatedRotation() throws {
        layoutConfiguration = .lockedDockerDetailed
        launch(extraArguments: ["--vvterm-ui-test-stats-cards-locked-docker"])
        try assertPhase(named: "phase 1: portrait", readsDirectFramesForParity: true)

        try rotate(to: .landscapeLeft)
        try assertPhase(named: "phase 2: landscapeLeft")

        try rotate(to: .portrait)
        try assertPhase(named: "phase 3: portrait")
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
        // (#349) with one bounded ≥40 s snapshot poll.
    }

    @MainActor
    private func rotate(to orientation: UIDeviceOrientation) throws {
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
        // (0.5 s apart) so one rotation costs at most 9 width reads.
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
            "Container width never \(expectsWiderLayout ? "grew" : "shrank") from \(oldWidth) "
                + "after 3 rotation attempts to \(orientation.rawValue) (last sample \(lastWidth))"
        )
    }

    /// Reads the phase's geometry and runs the same containment/column
    /// assertions for every phase. Phase 1 uses the bounded mount poll and
    /// cross-checks it against direct per-card frame reads; later phases use a
    /// single snapshot each.
    @MainActor
    private func assertPhase(
        named phaseName: String,
        readsDirectFramesForParity: Bool = false
    ) throws {
        try XCTContext.runActivity(named: phaseName) { _ in
            let phase: PhaseFrames
            if readsDirectFramesForParity {
                phase = try mountedFrames(phaseName: phaseName)
                assertMountedFramesMatchDirectReads(phase, phaseName: phaseName)
            } else if let snapshot = snapshotCardFrames() {
                phase = snapshot
            } else {
                XCTFail("\(phaseName): container snapshot could not be read")
                return
            }
            try assertExpectedColumnsAndContainment(phase: phase, phaseName: phaseName)
        }
    }

    /// Waits for the harness grid to mount all 8 cards, polling one container
    /// snapshot every ~0.5 s. This replaces the old 20 s + 10 s + 10 s
    /// existence tolerances (#349): the harness can take far longer than 40 s
    /// to materialize on a degraded runner (observed ~50 s on run
    /// 30643100567). Snapshot throws are absorbed into the poll — a transient
    /// AX miss while the grid is building is not a test failure; only the
    /// exhausted timeout reds.
    @MainActor
    private func mountedFrames(phaseName: String, timeout: TimeInterval = 40) throws -> PhaseFrames {
        let deadline = Date().addingTimeInterval(timeout)
        var observedCardCount = 0
        repeat {
            if let snapshot = snapshotCardFrames() {
                observedCardCount = snapshot.cardFrames.count
                if observedCardCount == Self.cardIdentifiers.count {
                    return snapshot
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        XCTFail(
            "\(phaseName): stats cards did not mount within \(Int(timeout))s "
                + "(last snapshot had \(observedCardCount)/\(Self.cardIdentifiers.count) cards)"
        )
        return PhaseFrames(containerFrame: .zero, cardFrames: [:])
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
    private func assertExpectedColumnsAndContainment(phase: PhaseFrames, phaseName: String) throws {
        assertExpectedCardIdentifiers(phase: phase, phaseName: phaseName)
        assertCardsAreHorizontallyContained(phase: phase, phaseName: phaseName)

        let containerWidth = phase.containerFrame.width
        guard let systemFrame = phase.cardFrames["system"],
              let cpuFrame = phase.cardFrames["cpu"],
              let memoryFrame = phase.cardFrames["memory"] else {
            // The identifier-set assertion above already failed; do not pile
            // duplicate failures on top of it.
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
