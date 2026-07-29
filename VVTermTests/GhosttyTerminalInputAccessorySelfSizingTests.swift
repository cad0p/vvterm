#if os(iOS)
import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import VVTerm

/// Regression coverage for the UIKit Auto Layout constraint conflict:
///
/// ```
/// Unable to simultaneously satisfy constraints.
///   "<NSLayoutConstraint UIView.height == 0 (active)>"
///   "<NSLayoutConstraint 'inputHeight' UIView.height == 233 (active)>"
/// ```
///
/// The conflict fired when switching terminal tabs or entering zen mode while
/// a terminal had content. UIKit imposes an internal `inputHeight` constraint
/// on a `UIInputView` (`inputViewStyle: .keyboard`) accessory, and during
/// input-session teardown it momentarily installs a `height == 0` constraint
/// on the same view; both at required priority, so Auto Layout breaks one.
///
/// The fix is the Apple-DTS-recommended self-sizing contract: the accessory
/// overrides `intrinsicContentSize` to return a concrete height (and opts
/// into `allowsSelfSizing` on iOS 17+). UIKit then derives the height from
/// the intrinsic value instead of adding its own required `inputHeight`
/// constraint, so the teardown `height == 0` never collides.
///
/// Auto Layout conflicts cannot be asserted directly in a unit test, so these
/// tests pin the contract that prevents the conflict: a concrete, stable,
/// non-`UIView.noIntrinsicMetric` intrinsic height on the accessory.
@Suite(.serialized)
@MainActor
struct GhosttyTerminalInputAccessorySelfSizingTests {
    @Test(
        "Accessory reports a concrete intrinsic height (not noIntrinsicMetric)",
        .enabled(if: ProcessInfo.processInfo.environment["VVTERM_SKIP_UITEST_HARNESS"] == nil)
    )
    func accessoryReportsConcreteIntrinsicHeight() throws {
        let (terminal, app) = try Self.makeTerminal()
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let accessory = terminal.keyboardUITestMakeAccessoryView()

        #expect(accessory is UIInputView, "Accessory should be a UIInputView subclass (self-sizing contract).")

        let intrinsic = accessory.intrinsicContentSize
        #expect(
            intrinsic.height != UIView.noIntrinsicMetric,
            "Accessory must report a concrete intrinsic height so UIKit does not impose a competing 'inputHeight' constraint. Got noIntrinsicMetric."
        )
        #expect(intrinsic.height > 0, "Accessory intrinsic height must be positive. Got \(intrinsic.height).")
    }

    @Test(
        "Accessory intrinsic height stays stable across layout passes",
        .enabled(if: ProcessInfo.processInfo.environment["VVTERM_SKIP_UITEST_HARNESS"] == nil)
    )
    func accessoryIntrinsicHeightIsStableAcrossLayoutPasses() throws {
        let (terminal, app) = try Self.makeTerminal()
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let accessory = terminal.keyboardUITestMakeAccessoryView()

        let first = accessory.intrinsicContentSize.height
        accessory.invalidateIntrinsicContentSize()
        let second = accessory.intrinsicContentSize.height

        #expect(
            first == second,
            "Accessory intrinsic height must stay stable across invalidation so the teardown 'height == 0' never conflicts with a drifting 'inputHeight'."
        )
        #expect(first > 0)
    }

    private static func makeTerminal() throws -> (GhosttyTerminalView, Ghostty.App) {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSTemporaryDirectory(),
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "accessory-self-sizing",
            useCustomIO: true
        )
        return (terminal, app)
    }
}
#endif
