import XCTest

final class TerminalZenModeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let zenHarnessArguments = [
        "--vvterm-ui-test-terminal-reconnect-harness",
        "--vvterm-ui-test-enable-startup-zen",
        "--vvterm-ui-test-keyboard-toggle-controls",
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US",
        "-hasSeenWelcome", "YES",
        "-iCloudSyncEnabled", "NO",
        "-sshAutoReconnect", "NO",
        "-terminalTmuxEnabledDefault", "NO",
        "-terminalUsePerAppearanceTheme", "NO",
        "-terminalThemeName", "Aizen Dark",
        "-security.privacyModeEnabled", "NO",
        "-security.fullAppLockEnabled", "NO",
        "-security.lockOnBackground", "NO",
    ]

    /// Boots the production server route against the loopback SSH fixture
    /// (skipped in CI unless the rig injected VVTERM_REPRO_SSH_*) and returns
    /// the terminal surface element.
    @MainActor
    private func launchZenRouteHarness(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        app.launchArguments = Self.zenHarnessArguments
        // Re-export the fixture env into the app launch environment (same
        // pattern as ZmxScrollbackReloadUITests): the harness reads
        // VVTERM_REPRO_SSH_* from the app's ProcessInfo.
        seedLoopbackFixtureEnv(into: app)
        _ = launchForTest(app, file: file, line: line)
        // The reconnect harness re-identifies the surface; the zen DEBUG
        // identifier is only the pre-harness default.
        let terminal = app.descendants(matching: .any)["vvterm.reconnectTest.terminalSurface"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 45), "Terminal surface never appeared", file: file, line: line)
        // The loopback shell takes focus on connect; hide the software keyboard
        // so geometry assertions see the unobstructed terminal frame.
        let hideKeyboard = app.buttons["vvterm.reconnectTest.keyboard.hide"]
        if hideKeyboard.waitForExistence(timeout: 5) {
            hideKeyboard.tap()
        }
        return terminal
    }

    @MainActor
    private func overscrollShift(of terminal: XCUIElement) -> Int? {
        guard let value = terminal.value as? String,
              value.hasPrefix("overscroll="),
              let raw = value.split(separator: "=").last else {
            return nil
        }
        return Int(raw)
    }

    // MARK: - Diagnostics helpers (shared label format with the zmx/reconnect rigs)

    @MainActor
    private func diagnosticsElement(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["vvterm.reconnectTest.diagnostics"]
    }

    @MainActor
    private func waitForDiagnostics(
        _ element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval,
        app: XCUIApplication
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(expected) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected diagnostics to contain '\(expected)'. \(diagnosticText(in: app))")
    }

    @MainActor
    private func diagnosticValue(_ name: String, in diagnostics: XCUIElement) -> String? {
        diagnostics.label
            .split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("\(name)=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }

    @MainActor
    private func diagnosticIntegerValue(_ name: String, in diagnostics: XCUIElement) -> Int? {
        diagnosticValue(name, in: diagnostics).flatMap(Int.init)
    }

    @MainActor
    private func diagnosticDoubleValue(_ name: String, in diagnostics: XCUIElement) -> Double? {
        diagnosticValue(name, in: diagnostics).flatMap(Double.init)
    }

    @MainActor
    private func diagnosticText(in app: XCUIApplication) -> String {
        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        return diagnostics.exists
            ? diagnostics.label
            : "diagnostics unavailable; app state=\(app.state.rawValue)"
    }

    /// With "Open in Zen mode by default" on (the default), the production
    /// route must enter zen automatically once the terminal is active — no
    /// menu tap — and the full-screen terminal must span the whole screen
    /// (behind the notch and home indicator).
    @MainActor
    func testDefaultToZenEntersZenAutomaticallyAndTerminalCoversScreen() throws {
        try skipUnlessLoopbackFixtureAvailable()
        let app = XCUIApplication()
        defer { app.terminate() }

        let terminal = launchZenRouteHarness(app)

        let launcher = app.buttons["vvterm.zen.controls"]
        XCTAssertTrue(
            launcher.waitForExistence(timeout: 10),
            "Startup zen should enter zen mode automatically without user action"
        )

        let screenFrame = app.frame
        let terminalFrame = terminal.frame
        XCTAssertEqual(
            terminalFrame.minY, screenFrame.minY, accuracy: 1,
            "Full-screen zen terminal should start at the top of the screen"
        )
        XCTAssertEqual(
            terminalFrame.maxY, screenFrame.maxY, accuracy: 1,
            "Full-screen zen terminal should reach the bottom of the screen"
        )
    }

    /// The first shell prompt sits in the rows hidden behind the notch once
    /// the terminal is truly full screen. Entering full-screen zen must
    /// automatically apply the top overscroll shift (no user scroll) so the
    /// prompt is visible.
    @MainActor
    func testFullScreenZenAutoShiftsInitialPromptBelowNotch() throws {
        try skipUnlessLoopbackFixtureAvailable()
        let app = XCUIApplication()
        defer { app.terminate() }

        let terminal = launchZenRouteHarness(app)
        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForExistence(timeout: 10)
        )

        let shift = overscrollShift(of: terminal)
        let engaged = try XCTUnwrap(
            shift,
            "Terminal does not expose an overscroll value; auto-shift cannot be verified"
        )
        XCTAssertGreaterThan(
            engaged, 0,
            "Entering full-screen zen should auto-shift the initial prompt below the notch "
                + "(overscroll=\(engaged)). \(diagnosticText(in: app))"
        )
    }

    /// The full-screen terminal hides rows behind the notch; scrolling past
    /// the top edge must shift the rendered content (overscroll) so those
    /// rows become visible, and scrolling back must return to normal. The
    /// auto-shift from entering zen is consumed first so the interactive
    /// engagement is measured from a zero baseline.
    @MainActor
    func testFullScreenZenOverscrollShiftsContentPastTopEdgeAndResets() throws {
        try skipUnlessLoopbackFixtureAvailable()
        let app = XCUIApplication()
        defer { app.terminate() }

        let terminal = launchZenRouteHarness(app)
        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForExistence(timeout: 10)
        )

        // Phase 1: consume the auto-shift by scrolling back (finger up).
        let consumeDeadline = Date().addingTimeInterval(20)
        while Date() < consumeDeadline {
            terminal.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if let value = overscrollShift(of: terminal), value == 0 {
                break
            }
        }
        XCTAssertEqual(
            overscrollShift(of: terminal), 0,
            "Scrolling back should consume the initial auto-shift. \(diagnosticText(in: app))"
        )

        // Phase 2: swipe down (toward older content) until the top edge is
        // reached and the overscroll shift engages interactively.
        var shift: Int?
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            terminal.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if let value = overscrollShift(of: terminal), value > 0 {
                shift = value
                break
            }
        }
        let engagedShift = try XCTUnwrap(
            shift,
            "Overscroll shift never engaged while swiping past the top edge"
        )
        XCTAssertGreaterThan(engagedShift, 0)

        // Phase 3: swipe up (toward newer content): the shift must be
        // consumed and return to zero before normal scrolling resumes.
        let resetDeadline = Date().addingTimeInterval(20)
        while Date() < resetDeadline {
            terminal.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if let value = overscrollShift(of: terminal), value == 0 {
                return
            }
        }
        XCTFail("Overscroll shift did not reset after scrolling back from the top edge")
    }

    /// OTA regression: while connecting in full-screen zen, the "Connecting…"
    /// banner rendered at the very top of the screen — behind the notch.
    /// It must sit below the top safe area. Uses a raw listener socket that
    /// accepts but never speaks SSH, so the connecting state (and its banner)
    /// persists long enough to measure.
    @MainActor
    func testFullScreenZenConnectionBannerSitsBelowNotch() throws {
        try skipUnlessLoopbackFixtureAvailable()
        let app = XCUIApplication()
        defer { app.terminate() }

        // The UI test process runs on the simulator host; the simulator
        // shares the host loopback. Accept the SSH TCP connect and then stay
        // silent so the SSH banner handshake hangs and the connecting state
        // (with its top banner) persists.
        let listener = SilentTCPListener()
        defer { listener.close() }

        app.launchArguments = Self.zenHarnessArguments
        seedLoopbackFixtureEnv(into: app)
        // Point the harness at the silent listener instead of the fixture sshd.
        app.launchEnvironment["VVTERM_REPRO_SSH_PORT"] = String(listener.port)
        _ = launchForTest(app)

        let launcher = app.buttons["vvterm.zen.controls"]
        XCTAssertTrue(
            launcher.waitForExistence(timeout: 20),
            "Startup zen should engage while connecting"
        )

        let diagnostics = diagnosticsElement(in: app)
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 20), diagnosticText(in: app))
        waitForDiagnostics(
            diagnostics, containing: "state=connecting", timeout: 20, app: app
        )

        let banner = app.descendants(matching: .any)
            .matching(identifier: "vvterm.notice.banner")
            .firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), diagnosticText(in: app))
        // Let the zen safe-area transition settle before measuring.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        // The banner renders at topInset(59pt notch) + 8pt padding. If it
        // regresses behind the notch it sits at y ≈ 8.
        let minY = banner.frame.minY
        XCTAssertGreaterThanOrEqual(
            minY, 55,
            "Connection banner must clear the notch in full-screen zen "
                + "(minY=\(minY), expected >= 55). \(diagnosticText(in: app))"
        )
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "zen-connecting-banner"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Keyboard regression guard for full-screen zen: opening the software
    /// keyboard must not reload the terminal surface or the SSH shell, must
    /// not resize the preserved grid, and must keep the terminal content
    /// visible above the keyboard (the BUG A / BUG B assertions from the zmx
    /// repro, applied to the zen full-screen layout).
    @MainActor
    func testFullScreenZenKeyboardOpenPreservesGridAndKeepsContentVisible() throws {
        try skipUnlessLoopbackFixtureAvailable()
        let app = XCUIApplication()
        defer { app.terminate() }

        let terminal = launchZenRouteHarness(app)
        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForExistence(timeout: 10)
        )
        let diagnostics = diagnosticsElement(in: app)
        waitForDiagnostics(
            diagnostics, containing: "setup=ready state=connected", timeout: 30, app: app
        )
        waitForDiagnostics(diagnostics, containing: "shell=true", timeout: 15, app: app)

        let beforeTerminalId = diagnosticValue("terminalId", in: diagnostics)
        let beforeShellId = diagnosticValue("shellId", in: diagnostics)
        let beforeConnectionAttempts = diagnosticIntegerValue("connectionAttempts", in: diagnostics)
        let beforeGridResizes = diagnosticIntegerValue("gridResizes", in: diagnostics)
        let beforeGridRows = diagnosticIntegerValue("gridRows", in: diagnostics)
        let windowFrame = app.windows.firstMatch.frame

        terminal.tap()
        waitForDiagnostics(diagnostics, containing: "keyboardVisible=true", timeout: 10, app: app)
        waitForDiagnostics(diagnostics, containing: "sizePreserved=true", timeout: 10, app: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), diagnosticText(in: app))

        // Let the keyboard + avoidance animation settle before measuring.
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        // BUG B: preserve-size grid must not change rows when the keyboard
        // opens, and no resize may occur (open phase is exact — the close
        // phase allows the benign accessory-transition transient).
        let openGridRows = diagnosticIntegerValue("gridRows", in: diagnostics)
        XCTAssertEqual(
            openGridRows, beforeGridRows,
            "Keyboard open resized the preserved grid rows "
                + "(\(beforeGridRows.map(String.init) ?? "nil") -> "
                + "\(openGridRows.map(String.init) ?? "nil")). \(diagnosticText(in: app))"
        )
        XCTAssertEqual(
            diagnosticIntegerValue("gridResizes", in: diagnostics),
            beforeGridResizes,
            "Keyboard open resized the terminal grid. \(diagnosticText(in: app))"
        )

        // BUG A: no new connection, no surface/shell replacement.
        XCTAssertEqual(
            diagnosticIntegerValue("connectionAttempts", in: diagnostics),
            beforeConnectionAttempts,
            "Keyboard open started a new SSH connection attempt. \(diagnosticText(in: app))"
        )
        XCTAssertEqual(
            diagnosticValue("terminalId", in: diagnostics),
            beforeTerminalId,
            "Keyboard open replaced the terminal surface. \(diagnosticText(in: app))"
        )
        XCTAssertEqual(
            diagnosticValue("shellId", in: diagnostics),
            beforeShellId,
            "Keyboard open replaced the SSH shell. \(diagnosticText(in: app))"
        )

        // BUG B: the terminal content must stay visible above the keyboard.
        let keyboardHeight = diagnosticDoubleValue("keyboardHeight", in: diagnostics) ?? 0
        let visibleRect = CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: max(windowFrame.height - keyboardHeight, 0)
        )
        let terminalFrame = terminal.frame
        let intersection = terminalFrame.intersection(visibleRect)
        let visibleFraction = terminalFrame.height > 0
            ? intersection.height / terminalFrame.height
            : 0
        print("ZEN-KEYBOARD: terminalFrame=\(terminalFrame) keyboardHeight=\(keyboardHeight) "
            + "visibleRect=\(visibleRect) intersection=\(intersection) "
            + "visibleFraction=\(visibleFraction)")
        XCTAssertFalse(
            intersection.isNull || intersection.isEmpty,
            "Terminal surface is entirely outside the visible area above the keyboard. "
                + "\(diagnosticText(in: app))"
        )
        XCTAssertGreaterThanOrEqual(
            visibleFraction, 0.3,
            "Only \(String(format: "%.0f", visibleFraction * 100))% of the terminal "
                + "surface remains visible above the keyboard. \(diagnosticText(in: app))"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "zen-keyboard-open"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Raw TCP listener that accepts connections and then stays silent, so
    /// the SSH banner handshake hangs and the app stays in "connecting"
    /// (the state whose banner must clear the notch). Runs in the test
    /// process on the simulator host.
    private final class SilentTCPListener {
        let port: Int
        private let serverFD: Int32

        init() {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            assert(fd >= 0, "socket() failed")
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0 // kernel-assigned
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            assert(bindResult == 0, "bind() failed")
            assert(listen(fd, 4) == 0, "listen() failed")

            var bound = sockaddr_in()
            var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &boundLen)
                }
            }
            port = Int(CFSwapInt16HostToBig(bound.sin_port))
            serverFD = fd

            // Accept one connection and hold it open without writing anything.
            Thread.detachNewThread { [fd] in
                var client = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &client) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        accept(fd, sa, &clientLen)
                    }
                }
                if clientFD >= 0 {
                    // Hold the connection open (no SSH banner) for up to 30s
                    // so the app stays in "connecting".
                    Thread.sleep(forTimeInterval: 30)
                    Darwin.close(clientFD)
                }
            }
        }

        func close() {
            Darwin.close(serverFD)
        }
    }

    @MainActor
    func testRealTerminalLauncherOpensZenPanel() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        _ = launchForTest(app)

        XCTAssertTrue(
            app.descendants(matching: .any)["vvterm.zenTest.terminalSurface"]
                .waitForExistence(timeout: 15)
        )
        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        let launcher = app.buttons["vvterm.zen.controls"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(launcher.isHittable)
        XCTAssertEqual(launcher.frame.width, launcher.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(launcher.frame.width, 48)
        launcher.tap()

        XCTAssertTrue(
            app.buttons["vvterm.terminal.zen.view.terminal"].waitForExistence(timeout: 5),
            "Zen launcher remained visible but did not open the control panel"
        )
    }

    @MainActor
    func testMenuEntryHidesChromeAndFloatingControlRestoresIt() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        _ = launchForTest(app)

        let chrome = app.buttons["vvterm.zenTest.chrome"]
        XCTAssertTrue(chrome.waitForExistence(timeout: 5))

        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(chrome.waitForNonExistence(timeout: 5))

        app.buttons["vvterm.zen.controls"].tap()
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.view.terminal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.view.files"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.newTab"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.settings"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.editServer"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.back"].exists)
        XCTAssertTrue(app.buttons["vvterm.terminal.zen.disconnect"].exists)

        app.buttons["vvterm.terminal.zen.view.files"].tap()
        XCTAssertTrue(app.buttons["vvterm.zen.controls"].exists)

        let exitZenMode = app.buttons["vvterm.terminal.exitZenMode"]
        XCTAssertTrue(exitZenMode.waitForExistence(timeout: 5))
        if !exitZenMode.isHittable {
            app.scrollViews["vvterm.terminal.zenPanel"].swipeUp()
        }
        XCTAssertTrue(exitZenMode.isHittable)
        exitZenMode.tap()

        XCTAssertTrue(chrome.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["vvterm.zen.controls"].waitForNonExistence(timeout: 5)
        )
    }

    /// The zen tray exposes an ungated "Share Diagnostics" button so users
    /// can attach recent logs to bug reports (see GitHub issue #74).
    @MainActor
    func testZenPanelShareDiagnosticsButtonTriggersHandler() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        _ = launchForTest(app)

        XCTAssertTrue(app.buttons["vvterm.zenTest.chrome"].waitForExistence(timeout: 5))

        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        app.buttons["vvterm.zen.controls"].tap()
        let shareDiagnostics = app.buttons["vvterm.terminal.zen.shareDiagnostics"]
        XCTAssertTrue(shareDiagnostics.waitForExistence(timeout: 5))
        var scrollAttempts = 0
        while !shareDiagnostics.isHittable && scrollAttempts < 3 {
            app.scrollViews["vvterm.terminal.zenPanel"].swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(shareDiagnostics.isHittable)
        shareDiagnostics.tap()

        XCTAssertTrue(
            app.staticTexts["vvterm.zenTest.diagnosticsTapped"].waitForExistence(timeout: 5)
        )
    }

    /// The zen launcher is a glass circle with a thin SF Symbol inside.
    /// Without a `.contentShape`, only the symbol's opaque strokes were
    /// tappable, so tapping the visible glass circle (the obvious target)
    /// did nothing — leaving users stuck in zen mode. This test taps an
    /// off-center point inside the glass circle (not on the symbol) to
    /// verify the whole circle is tappable.
    @MainActor
    func testZenLauncherCircleIsFullyTappable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-zen-mode-harness",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US"
        ]
        _ = launchForTest(app)

        XCTAssertTrue(app.buttons["vvterm.zenTest.chrome"].waitForExistence(timeout: 5))

        app.buttons["vvterm.terminal.moreMenu"].tap()
        let enterZenMode = app.buttons["vvterm.terminal.enterZenMode"]
        XCTAssertTrue(enterZenMode.waitForExistence(timeout: 5))
        enterZenMode.tap()

        let launcher = app.buttons["vvterm.zen.controls"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))

        // Tap near the bottom edge of the launcher circle — well outside the
        // thin slider.symbol but inside the visible glass circle.
        let coordinate = launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        coordinate.tap()

        // The panel should open (proving the off-center tap registered).
        XCTAssertTrue(
            app.buttons["vvterm.terminal.zen.view.terminal"].waitForExistence(timeout: 5)
        )
    }
}
