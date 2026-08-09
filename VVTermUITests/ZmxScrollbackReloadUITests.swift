// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  ZmxScrollbackReloadUITests.swift
//  VVTermUITests
//
//  CI repro for two iOS bugs with zmx (tmux-compatible) sessions:
//
//  BUG A — with "Keep terminal size when keyboard opens" ENABLED (the
//  default), opening/closing the software keyboard reloads the ENTIRE zmx
//  scrollback over the network. Root cause hypothesis: zmx re-sends the full
//  scrollback only on attach, so a full reload implies a RE-ATTACH, i.e. the
//  SSH shell ended and `attemptAutoReconnectIfNeeded` opened a new SSH
//  connection whose login shell re-ran the auto-attach. The bytemeter proxy
//  distinguishes the three cases by TCP connection identity + byte volume:
//    (a) same-connection small burst        -> redraw (not the bug)
//    (b) same-connection huge burst         -> attach re-exec on same channel
//    (c) NEW TCP connection + huge burst    -> full reconnect -> re-attach
//                                            (THE BUG)
//
//  BUG B — opening the keyboard scrolls terminal content up too much,
//  sometimes fully off-screen.
//
//  Rig (provisioned by scripts/ci/repro-*.sh on the xcode-27 runner; the
//  simulator shares the runner loopback):
//    - sshd on 127.0.0.1:22232 (pubkey auth, login shell /bin/zsh)
//    - bytemeter TCP proxy on 22229 -> 22232 with HTTP state on 22233
//      (GET /state, GET /mark?phase=X)
//    - zmx session `repro` pre-seeded with 8000 lines of scrollback, and a
//      ~/.zprofile + ~/.zshrc fragment that execs `zmx attach repro` in SSH
//      login shells (guarded by a per-job arm flag + ZMX_NO_AUTOATTACH)
//    - the app's TerminalReconnectUITestHarness pointed at the fixture via
//      launchEnvironment (VVTERM_REPRO_SSH_*), read from this test process's
//      own env (xcodebuild strips the TEST_RUNNER_ prefix).
//
//  The tests are intentionally NOT gated behind skipUnlessLoopbackFixture-
//  Available(): they skip only when the VVTERM_REPRO_SSH_* env is absent, so
//  they stay inert in PR CI but run in the repro workflow.
//

import XCTest

@MainActor
final class ZmxScrollbackReloadUITests: XCTestCase {

    // MARK: - Fixture gating

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["VVTERM_REPRO_SSH_USERNAME"] != nil,
              env["VVTERM_REPRO_SSH_PRIVATE_KEY"] != nil else {
            throw XCTSkip(
                "zmx scrollback repro rig not provisioned (missing VVTERM_REPRO_SSH_* env); "
                    + "run via .github/workflows/repro-zmx.yml"
            )
        }
    }

    // MARK: - Shared test state

    private struct Mark: Codable {
        let phase: String
        let ts: Double
        let connections: Int
        let upBytes: Int
        let downBytes: Int
        let openConnections: Int
    }

    private struct ConnectionEvent: Codable {
        let n: Int
        let openTs: Double
        let closeTs: Double?
        let upBytes: Int
        let downBytes: Int
    }

    private struct BytemeterState: Codable {
        let connections: Int
        let upBytes: Int
        let downBytes: Int
        let marks: [Mark]
        let connectionEvents: [ConnectionEvent]
    }

    private struct PhaseReport {
        let phase: String
        let start: Mark
        let end: Mark
        let bytes: Int
        let newConnections: [ConnectionEvent]
    }

    private var statePort: Int {
        Int(ProcessInfo.processInfo.environment["VVTERM_BYTEMETER_STATE_PORT"] ?? "") ?? 22_233
    }

    private var screenshotDir: String {
        let env = ProcessInfo.processInfo.environment
        return env["SCREENSHOT_DIR"]
            ?? env["CI_SCREENSHOT_DIR"]
            ?? "\(NSTemporaryDirectory())screenshots"
    }

    // MARK: - Tests

    /// Rig sanity: connecting the app must replay the pre-seeded zmx
    /// scrollback over a SINGLE TCP connection with a big down-burst. If this
    /// fails the rig is broken, not the app.
    func testZmxAttachReplaysScrollbackOnConnect() throws {
        let baseline = try mark(phase: "baseline-sanity")
        let app = launchZmxApp()
        defer { app.terminate() }

        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45), diagnosticText(in: app))
        waitForDiagnostics(diagnostics, containing: "setup=ready state=connected", timeout: 45, app: app)
        waitForDiagnostics(diagnostics, containing: "shell=true", timeout: 15, app: app)

        // The zmx attach replays ~8000 lines of scrollback: poll until the
        // down-bytes counter has grown well past the small-burst threshold.
        let deadline = Date().addingTimeInterval(45)
        var last = bytemeterState()
        while Date() < deadline {
            if let state = bytemeterState(), state.downBytes >= baseline.downBytes + 20_000 {
                last = state
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let attached = try mark(phase: "attach-complete-sanity")

        let attachBytes = attached.downBytes - baseline.downBytes
        let newConnections = connectionsOpened(between: baseline, and: attached)

        print("ZMXPREPRO sanity: attachBytes=\(attachBytes) newConnections=\(newConnections.map(\.n))")
        XCTAssertGreaterThanOrEqual(
            attachBytes,
            20_000,
            "Scrollback replay did not happen: only \(attachBytes) down bytes "
                + "after connect (expected >= 20000 from the 8000-line zmx history). "
                + "Rig broken — see bytemeter log."
        )
        XCTAssertEqual(
            newConnections.count,
            1,
            "Expected exactly 1 TCP connection for the attach replay, got "
                + "\(newConnections.count). Evidence: \(evidenceJSON())"
        )
        attachEvidenceScreenshot(app, named: "sanity-attached")
    }

    /// BUG A (open phase) + BUG B: with preserve-size enabled (default),
    /// opening the software keyboard must NOT tear down the SSH shell (no new
    /// TCP connection, no big burst), and the terminal content must remain
    /// visible above the keyboard.
    func testKeyboardOpenDoesNotReloadScrollback() throws {
        let baseline = try mark(phase: "baseline-open")
        let app = launchZmxApp()
        defer { app.terminate() }

        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45), diagnosticText(in: app))
        waitForDiagnostics(diagnostics, containing: "setup=ready state=connected", timeout: 45, app: app)
        waitForDiagnostics(diagnostics, containing: "shell=true", timeout: 15, app: app)
        let attached = try waitForAttachReplay(baseline: baseline, phase: "attach-complete-open")

        let terminal = productionTerminal(in: app)
        let beforeTerminalId = diagnosticValue("terminalId", in: diagnostics)
        let beforeShellId = diagnosticValue("shellId", in: diagnostics)
        let beforeGridRows = diagnosticIntegerValue("gridRows", in: diagnostics)
        let beforeConnectionAttempts = diagnosticIntegerValue("connectionAttempts", in: diagnostics)
        let beforeGridResizes = diagnosticIntegerValue("gridResizes", in: diagnostics)
        let windowFrame = app.windows.firstMatch.frame

        terminal.tap()
        waitForDiagnostics(diagnostics, containing: "keyboardVisible=true", timeout: 10, app: app)
        waitForDiagnostics(diagnostics, containing: "sizePreserved=true", timeout: 10, app: app)
        waitForDiagnostics(diagnostics, containing: "imeProxyFirstResponder=true", timeout: 10, app: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), diagnosticText(in: app))

        // Let the keyboard + avoidance animation settle before measuring.
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        // --- BUG B assertions ---------------------------------------------
        let openGridRows = diagnosticIntegerValue("gridRows", in: diagnostics)
        XCTAssertEqual(
            openGridRows,
            beforeGridRows,
            "BUG B: preserve-size grid changed rows when the keyboard opened "
                + "(\(beforeGridRows.map(String.init) ?? "nil") -> \(openGridRows.map(String.init) ?? "nil")). "
                + diagnosticText(in: app)
        )

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
        print("ZMXPREPRO bugB: terminalFrame=\(terminalFrame) keyboardHeight=\(keyboardHeight) "
            + "visibleRect=\(visibleRect) intersection=\(intersection) visibleFraction=\(visibleFraction)")
        XCTAssertFalse(
            intersection.isNull || intersection.isEmpty,
            "BUG B: terminal surface (\(terminalFrame)) is entirely outside the "
                + "visible area above the keyboard (keyboardHeight=\(keyboardHeight), "
                + "window=\(windowFrame)). \(diagnosticText(in: app))"
        )
        XCTAssertGreaterThanOrEqual(
            visibleFraction,
            0.3,
            "BUG B: only \(String(format: "%.0f", visibleFraction * 100))% of the terminal "
                + "surface remains visible above the keyboard (content scrolled up too much). "
                + "terminalFrame=\(terminalFrame) keyboardHeight=\(keyboardHeight) "
                + "window=\(windowFrame). \(diagnosticText(in: app))"
        )
        XCTAssertEqual(
            diagnosticIntegerValue("gridResizes", in: diagnostics),
            beforeGridResizes,
            "BUG B: keyboard open resized the terminal grid "
                + "(\(beforeGridResizes.map(String.init) ?? "nil") -> "
                + "\(diagnosticIntegerValue("gridResizes", in: diagnostics).map(String.init) ?? "nil")). "
                + diagnosticText(in: app)
        )
        XCTAssertEqual(
            diagnosticIntegerValue("connectionAttempts", in: diagnostics),
            beforeConnectionAttempts,
            "BUG A: keyboard open started a new SSH connection attempt "
                + "(\(beforeConnectionAttempts.map(String.init) ?? "nil") -> "
                + "\(diagnosticIntegerValue("connectionAttempts", in: diagnostics).map(String.init) ?? "nil")). "
                + diagnosticText(in: app)
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
        attachEvidenceScreenshot(app, named: "keyboard-open")

        // --- BUG A (open phase) -------------------------------------------
        // The bug window: if the keyboard toggle kills the shell, the app
        // auto-reconnects within a second or two and the full scrollback
        // replay (huge down-burst on a NEW connection) shows up here.
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        let openDone = try mark(phase: "keyboard-open-settled")
        let report = phaseReport(from: attached, to: openDone, label: "keyboard-open")
        assertNoReload(report, attachBytes: attached.downBytes - baseline.downBytes, app: app)

        // Cleanup: close the keyboard (also feeds the close-phase evidence).
        hideKeyboard(diagnostics: diagnostics, app: app)
        attachEvidenceScreenshot(app, named: "keyboard-closed")
    }

    /// BUG A (close phase): hiding the keyboard (after it was opened with
    /// preserve-size) must not tear down the SSH shell either.
    func testKeyboardCloseDoesNotReloadScrollback() throws {
        let baseline = try mark(phase: "baseline-close")
        let app = launchZmxApp()
        defer { app.terminate() }

        let diagnostics = app.staticTexts["vvterm.reconnectTest.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 45), diagnosticText(in: app))
        waitForDiagnostics(diagnostics, containing: "setup=ready state=connected", timeout: 45, app: app)
        waitForDiagnostics(diagnostics, containing: "shell=true", timeout: 15, app: app)
        let attached = try waitForAttachReplay(baseline: baseline, phase: "attach-complete-close")

        let terminal = productionTerminal(in: app)
        let beforeTerminalId = diagnosticValue("terminalId", in: diagnostics)
        let beforeShellId = diagnosticValue("shellId", in: diagnostics)

        terminal.tap()
        waitForDiagnostics(diagnostics, containing: "keyboardVisible=true", timeout: 10, app: app)
        waitForDiagnostics(diagnostics, containing: "sizePreserved=true", timeout: 10, app: app)
        let openMark = try mark(phase: "keyboard-open-close")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let beforeConnectionAttempts = diagnosticIntegerValue("connectionAttempts", in: diagnostics)
        let beforeGridResizes = diagnosticIntegerValue("gridResizes", in: diagnostics)
        let beforeGridRows = diagnosticIntegerValue("gridRows", in: diagnostics)

        hideKeyboard(diagnostics: diagnostics, app: app)
        // Bug window: the close may also tear down the shell.
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        let closedMark = try mark(phase: "keyboard-closed-settled")
        let report = phaseReport(from: attached, to: closedMark, label: "keyboard-toggle-close")
        assertNoReload(report, attachBytes: attached.downBytes - baseline.downBytes, app: app)
        _ = openMark

        XCTAssertEqual(
            diagnosticIntegerValue("connectionAttempts", in: diagnostics),
            beforeConnectionAttempts,
            "BUG A: keyboard close started a new SSH connection attempt "
                + "(\(beforeConnectionAttempts.map(String.init) ?? "nil") -> "
                + "\(diagnosticIntegerValue("connectionAttempts", in: diagnostics).map(String.init) ?? "nil")). "
                + diagnosticText(in: app)
        )
        XCTAssertEqual(
            diagnosticIntegerValue("gridResizes", in: diagnostics),
            beforeGridResizes,
            "BUG B: keyboard close resized the terminal grid "
                + "(\(beforeGridResizes.map(String.init) ?? "nil") -> "
                + "\(diagnosticIntegerValue("gridResizes", in: diagnostics).map(String.init) ?? "nil")). "
                + diagnosticText(in: app)
        )
        XCTAssertEqual(
            diagnosticIntegerValue("gridRows", in: diagnostics),
            beforeGridRows,
            "BUG B: preserve-size grid changed rows when the keyboard closed "
                + "(\(beforeGridRows.map(String.init) ?? "nil") -> "
                + "\(diagnosticIntegerValue("gridRows", in: diagnostics).map(String.init) ?? "nil")). "
                + diagnosticText(in: app)
        )

        XCTAssertEqual(
            diagnosticValue("terminalId", in: diagnostics),
            beforeTerminalId,
            "Keyboard close replaced the terminal surface. \(diagnosticText(in: app))"
        )
        XCTAssertEqual(
            diagnosticValue("shellId", in: diagnostics),
            beforeShellId,
            "Keyboard close replaced the SSH shell. \(diagnosticText(in: app))"
        )
    }

    // MARK: - BUG A verdict

    /// FAIL (bug reproduced) when the phase saw a NEW TCP connection (the SSH
    /// shell died and the app auto-reconnected -> login shell -> zmx re-attach
    /// -> full scrollback replay) or a down-burst >= 50% of the first-attach
    /// burst (attach re-exec on the same channel). A small same-connection
    /// burst (redraw) is fine.
    private func assertNoReload(_ report: PhaseReport, attachBytes: Int, app: XCUIApplication) {
        let evidence = evidenceJSON()
        print("ZMXPREPRO \(report.phase): bytes=\(report.bytes) "
            + "newConnections=\(report.newConnections.map(\.n)) attachBytes=\(attachBytes)")
        XCTAssertEqual(
            report.newConnections.count,
            0,
            "BUG A REPRODUCED: \(report.phase) opened \(report.newConnections.count) NEW TCP "
                + "connection(s) — the SSH shell ended and the app auto-reconnected, "
                + "re-running the zmx attach (full scrollback reload). "
                + "Evidence: \(evidence)"
        )
        XCTAssertLessThan(
            report.bytes,
            attachBytes / 2,
            "BUG A REPRODUCED: \(report.phase) transferred \(report.bytes) down bytes — "
                + ">= 50% of the first-attach burst (\(attachBytes)) — on the same "
                + "connection, i.e. an attach re-exec reloaded the scrollback. "
                + "Evidence: \(evidence)"
        )
    }

    private func phaseReport(from start: Mark, to end: Mark, label: String) -> PhaseReport {
        let state = bytemeterState()
        let newConnections = (state?.connectionEvents ?? []).filter { event in
            event.openTs >= start.ts - 1.0 && event.openTs <= end.ts + 1.0
        }
        return PhaseReport(
            phase: label,
            start: start,
            end: end,
            bytes: end.downBytes - start.downBytes,
            newConnections: newConnections
        )
    }

    private func connectionsOpened(between start: Mark, and end: Mark) -> [ConnectionEvent] {
        (bytemeterState()?.connectionEvents ?? []).filter { event in
            event.openTs >= start.ts - 1.0 && event.openTs <= end.ts + 1.0
        }
    }

    // MARK: - Attach replay helpers

    private func waitForAttachReplay(baseline: Mark, phase: String) throws -> Mark {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let state = bytemeterState(), state.downBytes >= baseline.downBytes + 20_000 {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        // Replay finished when down-bytes are stable across a 3s window.
        let stableDeadline = Date().addingTimeInterval(20)
        while Date() < stableDeadline {
            let first = bytemeterState()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            if let first, let second = bytemeterState(),
               second.downBytes - first.downBytes < 1024 {
                return try mark(phase: phase)
            }
        }
        XCTFail("zmx scrollback replay did not stabilize within 20s. \(evidenceJSON())")
        return try mark(phase: phase)
    }

    // MARK: - Keyboard helpers

    @MainActor
    private func hideKeyboard(diagnostics: XCUIElement, app: XCUIApplication) {
        let hideButton = app.buttons["vvterm.keyboard.accessory.hide"]
        XCTAssertTrue(hideButton.waitForExistence(timeout: 8), diagnosticText(in: app))
        hideButton.tap()
        waitForDiagnostics(diagnostics, containing: "keyboardVisible=false", timeout: 10, app: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 8),
            diagnosticText(in: app)
        )
    }

    @MainActor
    private func productionTerminal(in app: XCUIApplication) -> XCUIElement {
        let terminal = app.descendants(matching: .any)
            .matching(identifier: "vvterm.reconnectTest.terminalSurface")
            .firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), diagnosticText(in: app))
        return terminal
    }

    // MARK: - App launch

    @MainActor
    private func launchZmxApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "--vvterm-ui-test-terminal-reconnect-harness",
            "--vvterm-debug-log", "keyboard",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-hasSeenWelcome", "YES",
            "-iCloudSyncEnabled", "NO",
            "-sshAutoReconnect", "YES",
            "-terminalTmuxEnabledDefault", "NO",
            "-terminalUsePerAppearanceTheme", "NO",
            "-terminalThemeName", "Aizen Dark",
            "-security.privacyModeEnabled", "NO",
            "-security.fullAppLockEnabled", "NO",
            "-security.lockOnBackground", "NO",
        ]
        let env = ProcessInfo.processInfo.environment
        app.launchEnvironment["VVTERM_REPRO_SSH_USERNAME"] = env["VVTERM_REPRO_SSH_USERNAME"] ?? ""
        app.launchEnvironment["VVTERM_REPRO_SSH_PRIVATE_KEY"] = env["VVTERM_REPRO_SSH_PRIVATE_KEY"] ?? ""
        app.launchEnvironment["VVTERM_REPRO_SSH_PORT"] = env["VVTERM_REPRO_SSH_PORT"] ?? "22229"
        _ = launchForTest(app)
        return app
    }

    // MARK: - Diagnostics polling

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

    // MARK: - Bytemeter HTTP (raw POSIX sockets: the sim sandbox parks
    // Network.framework connections of unentitled processes, but raw sockets
    // are not gated — same reasoning as the teleport connector tests)

    private func bytemeterState() -> BytemeterState? {
        guard let data = httpGet("/state") else { return nil }
        return try? JSONDecoder().decode(BytemeterState.self, from: data)
    }

    private func mark(phase: String) throws -> Mark {
        guard let data = httpGet("/mark?phase=\(phase)") else {
            throw NSError(
                domain: "ZmxScrollbackReloadUITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "bytemeter HTTP unreachable (127.0.0.1:\(statePort)) — rig down"]
            )
        }
        guard let mark = try? JSONDecoder().decode(Mark.self, from: data) else {
            throw NSError(
                domain: "ZmxScrollbackReloadUITests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "bytemeter /mark returned an unparseable response for \(phase)"]
            )
        }
        print("ZMXPREPRO mark \(phase): connections=\(mark.connections) "
            + "upBytes=\(mark.upBytes) downBytes=\(mark.downBytes)")
        return mark
    }

    private func httpGet(_ path: String, timeout: TimeInterval = 5) -> Data? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = CFSwapInt16HostToBig(UInt16(statePort))
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            fd, SOL_SOCKET, SO_SNDTIMEO, &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        let request = "GET \(path) HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        request.withCString { _ = send(fd, $0, strlen($0), 0) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return data.subdata(in: headerEnd.upperBound..<data.count)
    }

    // MARK: - Evidence

    private func evidenceJSON() -> String {
        guard let state = bytemeterState() else { return "bytemeter unreachable" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return "encode failed" }
        return String(data: data, encoding: .utf8) ?? "no utf8"
    }

    private func writeEvidence(_ name: String) {
        let dir = URL(fileURLWithPath: screenshotDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("evidence-\(name).json")
        try? evidenceJSON().data(using: .utf8)?.write(to: url)
    }

    private func attachEvidenceScreenshot(_ app: XCUIApplication, named name: String) {
        writeEvidence(name)
        let png = app.screenshot().pngRepresentation
        let dir = URL(fileURLWithPath: screenshotDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        try? png.write(to: url)
        let attachment = XCTAttachment(
            uniformTypeIdentifier: "public.png",
            name: "\(name).png",
            payload: png,
            userInfo: nil
        )
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
