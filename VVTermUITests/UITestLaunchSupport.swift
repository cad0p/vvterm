import XCTest

extension XCTestCase {
    /// Launches `app` and waits for it to reach the foreground, terminating
    /// and retrying when the process starts but never becomes foreground —
    /// a recurring wedge on the Xcode 27 CI runners (#43).
    ///
    /// Note: XCTest's own hard "Timed out while launching application"
    /// failure cannot be intercepted; this covers the softer and more common
    /// mode where `launch()` returns but the app stays stuck.
    @discardableResult
    func launchForTest(
        _ app: XCUIApplication,
        attempts: Int = 2,
        foregroundTimeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let totalAttempts = max(1, attempts)
        for attempt in 1...totalAttempts {
            if attempt > 1 {
                app.terminate()
            }
            app.launch()
            if app.wait(for: .runningForeground, timeout: foregroundTimeout) {
                return app
            }
        }
        XCTFail(
            "VVTerm did not reach the foreground after \(totalAttempts) launch attempt(s)",
            file: file,
            line: line
        )
        return app
    }

    /// Taps `element` once it is hittable. The element can exist in the AX
    /// tree before it finishes mounting; a tap that lands early misses it
    /// and the follow-up assertion fails (issue #47). Waits for hittability
    /// so the tap reliably lands. Falls back to the raw tap on timeout so
    /// the follow-up assertion reports the real state.
    @MainActor
    func tapWhenHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable {
                element.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        element.tap()
    }
}
