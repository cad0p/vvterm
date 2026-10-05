// SPDX-License-Identifier: MIT
//
//  TerminalKeyboardFloatGestureClassifier.swift
//  VVTermTestSupport
//
//  #372: the pure skip-vs-hard-fail classifier for the native floating-keyboard
//  probe. It lives in this shared test-support folder so it is compiled into
//  both `VVTermTests` (scheduled unit coverage of the whole table) and
//  `VVTermUITests` (the probe that drives the real gestures); the UI-test
//  target cannot import app code, and the method itself is never scheduled
//  because every CI shard targets an iPhone-class simulator without the
//  native float capability.

import CoreGraphics

/// #372: tri-state outcome of the native float-gesture probe.
///
/// Distinguishes a destination without the native float capability (the
/// iPhone pinch types characters; frames stay docked-width within jitter)
/// from an app-side divergence (the frame moved past the tolerance band
/// without floating, or the keyboard vanished).
enum FloatGestureOutcome: Equatable {
    case floated(frame: CGRect)
    case unsupported(frames: [CGRect])
    case divergence(frames: [CGRect])
}

/// Pure classification of the frames observed after each pinch attempt.
///
/// - `.floated`: the first frame narrower than half the screen (a later
///   pinch on a floating keyboard can move/type, so the caller exits early).
/// - `.unsupported`: no frame ever dropped below `0.8 x screenWidth` and
///   every frame stayed within `tolerance` of the pre-pinch frame.
/// - `.divergence`: everything else, including a missing or zero frame
///   (a pinch that dismisses the keyboard is a failure, not a capability).
///
/// - tolerance: the per-edge jitter allowance. Measured #372: 1 pt on a local
///   iOS 26.3 iPhone 17 (`(75, 237, 724, 163)` -> `(75, 238, 724, 162)`) and
///   0 pt on the iOS 27 CI host, so the band is 4 pt for headroom against a
///   loaded runner's AX jitter — at 2 pt a host with 3 pt jitter would flip
///   the capability skip into a hard red. It stays far below the 151 pt CF-4
///   width move (724 -> 600) that must classify as `.divergence`. Revisit if
///   any measured no-op jitter exceeds 4 pt.
func classifyFloatGesture(
    frames: [CGRect],
    prePinchFrame: CGRect,
    screenWidth: CGFloat,
    tolerance: CGFloat = 4
) -> FloatGestureOutcome {
    guard !frames.isEmpty,
          prePinchFrame.isUsableKeyboardFrame,
          frames.allSatisfy(\.isUsableKeyboardFrame),
          screenWidth > 0 else {
        return .divergence(frames: frames)
    }
    if let floated = frames.first(where: { $0.width < screenWidth / 2 }) {
        return .floated(frame: floated)
    }
    let stayedDockedWidth = frames.allSatisfy { $0.width >= screenWidth * 0.8 }
    let stayedWithinTolerance = frames.allSatisfy { frame in
        abs(frame.minX - prePinchFrame.minX) <= tolerance
            && abs(frame.minY - prePinchFrame.minY) <= tolerance
            && abs(frame.width - prePinchFrame.width) <= tolerance
            && abs(frame.height - prePinchFrame.height) <= tolerance
    }
    return stayedDockedWidth && stayedWithinTolerance
        ? .unsupported(frames: frames)
        : .divergence(frames: frames)
}

extension CGRect {
    /// A real keyboard frame: not null, not zero-sized and not infinite. A
    /// pinch that dismisses the keyboard yields `.zero` (or a missing element);
    /// that must classify as a divergence, never as a float.
    var isUsableKeyboardFrame: Bool {
        !isNull && !isEmpty && !isInfinite
    }
}
