import Testing
import CoreGraphics
@testable import VVTerm

struct TerminalZenFullScreenPolicyTests {
    // MARK: - Overscroll Limits

    @Test
    func overscrollLimitsClearObscuredRegionPlusOneRow() {
        let limits = TerminalZenFullScreenPolicy.overscrollLimits(
            topInset: 47,
            bottomInset: 34,
            cellHeight: 16
        )
        #expect(limits.top == 63)
        #expect(limits.bottom == 50)
    }

    @Test
    func overscrollLimitsNeverBelowTwoRows() {
        let limits = TerminalZenFullScreenPolicy.overscrollLimits(
            topInset: 0,
            bottomInset: 0,
            cellHeight: 0
        )
        #expect(limits.top == 2)
        #expect(limits.bottom == 2)
    }

    // MARK: - Edge State

    @Test
    func edgeStatePinsAtTopAndBottom() {
        let top = TerminalZenFullScreenPolicy.edgeState(offset: 0, total: 100, len: 24)
        #expect(top.atTop)
        #expect(!top.atBottom)

        let bottom = TerminalZenFullScreenPolicy.edgeState(offset: 76, total: 100, len: 24)
        #expect(!bottom.atTop)
        #expect(bottom.atBottom)

        let middle = TerminalZenFullScreenPolicy.edgeState(offset: 40, total: 100, len: 24)
        #expect(!middle.atTop)
        #expect(!middle.atBottom)
    }

    @Test
    func edgeStatePinsAtBothEndsWhenGridCoversScrollback() {
        let state = TerminalZenFullScreenPolicy.edgeState(offset: 0, total: 20, len: 24)
        #expect(state.atTop)
        #expect(state.atBottom)
    }

    @Test
    func edgeStatePinsWhenScrollbackIsEmpty() {
        let state = TerminalZenFullScreenPolicy.edgeState(offset: 0, total: 0, len: 0)
        #expect(state.atTop)
        #expect(state.atBottom)
    }

    // MARK: - Shift Resolution

    @Test
    func deltaIntoTopEdgeAccumulatesShiftAndForwardsNothing() {
        let resolved = TerminalZenFullScreenPolicy.resolvedShift(
            shift: 0,
            delta: 12,
            atTop: true,
            atBottom: false,
            maxTop: 60,
            maxBottom: 40
        )
        #expect(resolved.shift == 12)
        #expect(resolved.forwarded == 0)
    }

    @Test
    func deltaIntoTopEdgeClampsAtLimit() {
        let resolved = TerminalZenFullScreenPolicy.resolvedShift(
            shift: 0,
            delta: 100,
            atTop: true,
            atBottom: false,
            maxTop: 60,
            maxBottom: 40
        )
        #expect(resolved.shift == 60)
        #expect(resolved.forwarded == 0)
    }

    @Test
    func deltaIntoBottomEdgeShiftsNegative() {
        let resolved = TerminalZenFullScreenPolicy.resolvedShift(
            shift: 0,
            delta: -12,
            atTop: false,
            atBottom: true,
            maxTop: 60,
            maxBottom: 40
        )
        #expect(resolved.shift == -12)
        #expect(resolved.forwarded == 0)
    }

    @Test
    func deltaIntoBottomEdgeClampsAtLimit() {
        let resolved = TerminalZenFullScreenPolicy.resolvedShift(
            shift: 0,
            delta: -100,
            atTop: false,
            atBottom: true,
            maxTop: 60,
            maxBottom: 40
        )
        #expect(resolved.shift == -40)
        #expect(resolved.forwarded == 0)
    }

    @Test
    func normalScrollForwardsEverythingWhenNotAtEdge() {
        let resolved = TerminalZenFullScreenPolicy.resolvedShift(
            shift: 0,
            delta: 12,
            atTop: false,
            atBottom: false,
            maxTop: 60,
            maxBottom: 40
        )
        #expect(resolved.shift == 0)
        #expect(resolved.forwarded == 12)
    }

    @Test
    func opposingDeltaConsumesShiftBeforeForwarding() {
        let resolved = TerminalZenFullScreenPolicy.resolvedShift(
            shift: 30,
            delta: -10,
            atTop: false,
            atBottom: false,
            maxTop: 60,
            maxBottom: 40
        )
        #expect(resolved.shift == 20)
        #expect(resolved.forwarded == 0)
    }

    @Test
    func overflowAfterConsumingShiftIsForwarded() {
        let resolved = TerminalZenFullScreenPolicy.resolvedShift(
            shift: 30,
            delta: -40,
            atTop: false,
            atBottom: false,
            maxTop: 60,
            maxBottom: 40
        )
        #expect(resolved.shift == 0)
        #expect(resolved.forwarded == -10)
    }

    @Test
    func saturatedShiftForwardsExcessMotionIntoEdge() {
        let resolved = TerminalZenFullScreenPolicy.resolvedShift(
            shift: 60,
            delta: 10,
            atTop: true,
            atBottom: false,
            maxTop: 60,
            maxBottom: 40
        )
        #expect(resolved.shift == 60)
        #expect(resolved.forwarded == 10)
    }

    @Test
    func crossingThroughZeroForwardsOverflowAsRealScroll() {
        // A single gesture from the top edge's overscroll across zero must
        // not flip into the bottom edge's overscroll: the overflow past zero
        // becomes a real scroll toward the bottom edge.
        let resolved = TerminalZenFullScreenPolicy.resolvedShift(
            shift: 30,
            delta: -80,
            atTop: false,
            atBottom: true,
            maxTop: 60,
            maxBottom: 40
        )
        #expect(resolved.shift == 0)
        #expect(resolved.forwarded == -50)
    }

    @Test
    func zeroDeltaKeepsState() {
        let resolved = TerminalZenFullScreenPolicy.resolvedShift(
            shift: 25,
            delta: 0,
            atTop: true,
            atBottom: false,
            maxTop: 60,
            maxBottom: 40
        )
        #expect(resolved.shift == 25)
        #expect(resolved.forwarded == 0)
    }
}
