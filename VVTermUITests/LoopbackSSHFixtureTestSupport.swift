import Foundation
import XCTest

/// Support for UI tests that drive the `TerminalReconnectUITestHarness`, which
/// boots the production terminal route against a real loopback SSH server
/// (127.0.0.1:22229).
///
/// The harness reads its loopback SSH username and private key from the app's
/// `app.vivy.vvterm.dev199-ui-test` UserDefaults suite. That suite is seeded
/// by the developer (locally) before running `xcodebuild test`; CI does not
/// provision a loopback `sshd` or seed the fixture. Without the fixture the
/// harness reports `setup=failed error=Missing loopback SSH username` and
/// every driving test times out waiting for `setup=ready`.
///
/// `skipUnlessLoopbackFixtureAvailable()` lets these tests run locally (where
/// the fixture is seeded) while skipping them cleanly in CI, so the UI test
/// suite reports a complete, honest result instead of timing out.
enum LoopbackSSHFixtureTestSupport {
    /// Returns `true` when the loopback SSH fixture appears to be seeded:
    /// either the CI rig injected `VVTERM_REPRO_SSH_*` into the test runner
    /// environment (see the ui-tests shard in vvterm-pr-ci.yml / the
    /// repro-zmx.yml rig), or a developer seeded the UserDefaults suite
    /// locally. When neither is present the tests skip cleanly instead of
    /// timing out waiting for a connection that can never be made.
    static func isLoopbackFixtureAvailable() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let username = env["VVTERM_REPRO_SSH_USERNAME"], !username.isEmpty {
            return true
        }
        let suite = UserDefaults(suiteName: "app.vivy.vvterm.dev199-ui-test")
        let username = suite?.string(forKey: "sshUsername") ?? ""
        return !username.isEmpty
    }

    /// Throws `XCTSkip` unless the loopback SSH fixture is available.
    static func skipUnlessAvailable(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try XCTSkipUnless(
            isLoopbackFixtureAvailable(),
            "Loopback SSH fixture is not available; TerminalReconnectUITestHarness tests require a seeded 127.0.0.1:22229 sshd + UserDefaults fixture (see TerminalReconnectUITestHarness+iOS.swift).",
            file: file,
            line: line
        )
    }
}

/// Convenience accessor so call sites in `ServerNavigationUITests` and
/// `TerminalReconnectUITests` read as `try skipUnlessLoopbackFixtureAvailable()`.
func skipUnlessLoopbackFixtureAvailable(
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    try LoopbackSSHFixtureTestSupport.skipUnlessAvailable(file: file, line: line)
}
