// SPDX-License-Identifier: MIT
//
//  TerminalKeyboardFloatGestureClassifierTests.swift
//  VVTermTests
//
//  #372: scheduled coverage for the native float-probe classifier. The
//  classifier itself lives in `VVTermTestSupport` (compiled into this target
//  and the UI-test target, which cannot import app code), so the
//  skip-vs-hard-fail table the UI probe relies on is exercised by the
//  required `unit-tests` job instead of a scratch probe.

#if os(iOS)
import CoreGraphics
import Testing

struct TerminalKeyboardFloatGestureClassifierTests {
    /// CF-4 (walk): the measured iPhone 17 no-op — 1 pt of AX jitter, every
    /// frame still docked-width — is a capability skip, not a regression.
    @Test
    func measuredJitteredNoOpClassifiesUnsupported() {
        let frames = [
            CGRect(x: 75, y: 237, width: 724, height: 163),
            CGRect(x: 75, y: 238, width: 724, height: 162)
        ]
        #expect(
            classifyFloatGesture(
                frames: frames,
                prePinchFrame: CGRect(x: 75, y: 237, width: 724, height: 163),
                screenWidth: 874
            ) == .unsupported(frames: frames)
        )
    }

    /// CF-4 (walk): the measured iPad Pro 11-inch float is the success case.
    @Test
    func measuredFloatClassifiesFloated() {
        let float = CGRect(x: 7, y: 536, width: 320, height: 216)
        #expect(
            classifyFloatGesture(
                frames: [float],
                prePinchFrame: CGRect(x: 0, y: 461, width: 1_210, height: 370),
                screenWidth: 1_210
            ) == .floated(frame: float)
        )
    }

    /// CF-4 (walk): a 151 pt width move (724 -> 600) that never reaches float
    /// size is an app-side divergence, not a capability gate.
    @Test
    func widthMovePastToleranceClassifiesDivergence() {
        let frames = [CGRect(x: 75, y: 150, width: 600, height: 163)]
        #expect(
            classifyFloatGesture(
                frames: frames,
                prePinchFrame: CGRect(x: 75, y: 237, width: 724, height: 163),
                screenWidth: 874
            ) == .divergence(frames: frames)
        )
    }

    /// CF-4 (walk): a dismissed keyboard (`.zero`) must classify as a
    /// divergence, never as a capability gate.
    @Test
    func dismissedKeyboardClassifiesDivergence() {
        #expect(
            classifyFloatGesture(
                frames: [.zero],
                prePinchFrame: CGRect(x: 75, y: 237, width: 724, height: 163),
                screenWidth: 874
            ) == .divergence(frames: [.zero])
        )
    }

    /// The tolerance band is exactly 4 pt per edge (the measured jitter is
    /// 1 pt); 5 pt must already be a divergence.
    @Test
    func toleranceBoundaryIsFourPoints() {
        let prePinch = CGRect(x: 0, y: 200, width: 800, height: 300)
        let within = CGRect(x: 0, y: 204, width: 800, height: 300)
        let beyond = CGRect(x: 0, y: 205, width: 800, height: 300)
        #expect(
            classifyFloatGesture(
                frames: [within],
                prePinchFrame: prePinch,
                screenWidth: 1_000
            ) == .unsupported(frames: [within])
        )
        #expect(
            classifyFloatGesture(
                frames: [beyond],
                prePinchFrame: prePinch,
                screenWidth: 1_000
            ) == .divergence(frames: [beyond])
        )
    }

    /// A width inside `[0.5, 0.8) x screenWidth` never floated but is no
    /// longer docked-width: divergence, never `.unsupported`.
    @Test
    func narrowedButNotFloatSizedClassifiesDivergence() {
        let frames = [CGRect(x: 0, y: 100, width: 700, height: 300)]
        #expect(
            classifyFloatGesture(
                frames: frames,
                prePinchFrame: CGRect(x: 0, y: 100, width: 900, height: 300),
                screenWidth: 1_000
            ) == .divergence(frames: frames)
        )
    }

    /// A frame wider than the screen is still docked-width geometry when it
    /// does not move (the rule reads width, not position).
    @Test
    func widerThanScreenUnmovedFrameClassifiesUnsupported() {
        let frames = [CGRect(x: -40, y: 200, width: 1_100, height: 300)]
        #expect(
            classifyFloatGesture(
                frames: frames,
                prePinchFrame: frames[0],
                screenWidth: 1_000
            ) == .unsupported(frames: frames)
        )
    }

    /// Empty frames, unusable frames, an unusable anchor or a non-positive
    /// screen width can never be a capability skip.
    @Test
    func unusableInputsClassifyDivergence() {
        let anchor = CGRect(x: 0, y: 200, width: 800, height: 300)
        #expect(
            classifyFloatGesture(frames: [], prePinchFrame: anchor, screenWidth: 1_000)
                == .divergence(frames: [])
        )
        #expect(
            classifyFloatGesture(
                frames: [CGRect(x: 0, y: 200, width: CGFloat.infinity, height: 300)],
                prePinchFrame: anchor,
                screenWidth: 1_000
            ) == .divergence(frames: [CGRect(x: 0, y: 200, width: CGFloat.infinity, height: 300)])
        )
        #expect(
            classifyFloatGesture(frames: [anchor], prePinchFrame: .zero, screenWidth: 1_000)
                == .divergence(frames: [anchor])
        )
        #expect(
            classifyFloatGesture(frames: [anchor], prePinchFrame: anchor, screenWidth: 0)
                == .divergence(frames: [anchor])
        )
    }
}
#endif
