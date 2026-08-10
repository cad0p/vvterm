//
//  TerminalZenFullScreenPolicy.swift
//  VVTerm
//
//  Pure rules for full-screen zen mode and its scroll-overscroll mitigation.
//
//  When zen mode makes the terminal truly full screen, the top rows can sit
//  behind the display notch / window chrome and the bottom rows behind the
//  home indicator / rounded corners. To keep that content reachable, the
//  scroll range is extended past both ends of the scrollback by a bounded
//  "overscroll shift" (in points, positive = content shifted down). Deltas
//  that ghostty would clamp at an edge accumulate into the shift instead;
//  once the shift is consumed by opposite motion, the remainder is forwarded
//  to ghostty as a normal scroll.
//

import CoreGraphics

nonisolated enum TerminalZenFullScreenPolicy {
    /// The maximum overscroll at each end: the obscured region (safe area
    /// inset) plus one full row so the formerly-obscured row clears the
    /// cutout entirely. Never less than two rows so the shift is always
    /// discoverable.
    nonisolated static func overscrollLimits(
        topInset: CGFloat,
        bottomInset: CGFloat,
        cellHeight: CGFloat
    ) -> (top: CGFloat, bottom: CGFloat) {
        let row = max(cellHeight, 1)
        return (
            top: max(topInset + row, row * 2),
            bottom: max(bottomInset + row, row * 2)
        )
    }

    /// Whether the scrollbar is pinned against the start (top) or end
    /// (bottom / live) of the scrollback range.
    nonisolated static func edgeState(
        offset: UInt64,
        total: UInt64,
        len: UInt64
    ) -> (atTop: Bool, atBottom: Bool) {
        guard total > 0, len > 0 else { return (atTop: true, atBottom: true) }
        let clampedLen = min(len, total)
        return (
            atTop: offset <= 0,
            atBottom: offset + clampedLen >= total
        )
    }

    /// Resolves a scroll delta (points, finger-down positive, in the same
    /// units sent to ghostty) against the current overscroll shift.
    ///
    /// Returns the new shift and the portion of the delta that should be
    /// forwarded to ghostty. Deltas pointing into an edge accumulate into the
    /// shift (clamped to the limits); deltas pointing away consume the shift
    /// first, and only overflow is forwarded. When no shift is active and the
    /// edge is reached, the delta is absorbed entirely so ghostty keeps its
    /// clamped position while the view shifts.
    nonisolated static func resolvedShift(
        shift: CGFloat,
        delta: CGFloat,
        atTop: Bool,
        atBottom: Bool,
        maxTop: CGFloat,
        maxBottom: CGFloat
    ) -> (shift: CGFloat, forwarded: CGFloat) {
        guard delta != 0 else { return (shift, 0) }

        if shift == 0 {
            if atTop && delta > 0 {
                return (min(delta, maxTop), 0)
            }
            if atBottom && delta < 0 {
                return (max(delta, -maxBottom), 0)
            }
            return (0, delta)
        }

        // An active shift is pinned to the edge it was accumulated at.
        // Motion pushing deeper into that edge accumulates (clamped); the
        // excess is forwarded to ghostty, which is pinned at the same edge
        // and clamps it — but the shift may outlive the edge if the
        // scrollback changed, so the overflow must keep flowing.
        let movingDeeper = (shift > 0 && delta > 0) || (shift < 0 && delta < 0)
        if movingDeeper {
            let newShift = shift > 0
                ? min(shift + delta, maxTop)
                : max(shift + delta, -maxBottom)
            let absorbed = newShift - shift
            return (newShift, delta - absorbed)
        }

        // Motion away from the edge consumes the shift. Crossing zero makes
        // the remainder a real scroll instead of flipping into the opposite
        // edge's overscroll — the opposite overscroll only applies once the
        // viewport actually reaches that edge.
        let newShift = shift > 0 ? max(shift + delta, 0) : min(shift + delta, 0)
        let absorbed = newShift - shift
        return (newShift, delta - absorbed)
    }
}
