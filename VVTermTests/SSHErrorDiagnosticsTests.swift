import Foundation
import Testing
@testable import VVTerm

struct SSHErrorDiagnosticsTests {
    private func makeServer(
        host: String = "teleport.pcad.it",
        port: Int = 443,
        username: String = "pier",
        teleportHostLogin: String? = nil
    ) -> Server {
        Server(
            workspaceId: UUID(),
            name: "pcad-dev",
            host: host,
            port: port,
            username: username,
            teleportHostLogin: teleportHostLogin
        )
    }

    @Test
    func rendersCaseNameWithConfiguredHostPortRedacted() {
        let message = SSHError.diagnosticsMessage(
            for: SSHError.connectionFailed("Failed to connect to teleport.pcad.it:443"),
            redacting: makeServer()
        )

        #expect(message == #"connectionFailed("Failed to connect to <host>:<port>")"#)
    }

    @Test
    func redactsConfiguredHostWithoutPort() {
        let message = SSHError.diagnosticsMessage(
            for: SSHError.connectionFailed("dial teleport.pcad.it timed out"),
            redacting: makeServer()
        )

        #expect(message.contains("dial <host> timed out"))
        #expect(!message.contains("teleport.pcad.it"))
    }

    @Test
    func redactsConfiguredUsername() {
        let message = SSHError.diagnosticsMessage(
            for: SSHError.authenticationFailed,
            redacting: makeServer()
        )

        #expect(message == "authenticationFailed")
        // Payloads that embed the user name are redacted too.
        let withUser = SSHError.diagnosticsMessage(
            for: SSHError.unknown("publickey rejected for pier"),
            redacting: makeServer()
        )
        #expect(withUser == #"unknown("publickey rejected for <user>")"#)
    }

    @Test
    func redactsConfiguredTeleportHostLogin() {
        // The stored host login is identity material and can appear in
        // connect-path error renderings; it must not reach the export.
        let message = SSHError.diagnosticsMessage(
            for: SSHError.unknown("publickey rejected for login deploy"),
            redacting: makeServer(teleportHostLogin: "deploy")
        )

        #expect(message == #"unknown("publickey rejected for login <login>")"#)
        #expect(!message.contains("deploy"))
    }

    @Test
    func hostLoginFailureRendersCaseNameOnly() {
        // The associated principal array must never render through
        // String(describing:) — the log/diagnostics spine uses it.
        let failure = TeleportHostLoginFailure.ambiguousPrincipalSet(["deploy", "root"])
        #expect(String(describing: failure) == "ambiguousPrincipalSet")
        #expect(failure.errorDescription?.contains("deploy, root") == true)

        let message = SSHError.diagnosticsMessage(
            for: SSHError.teleportHostLoginUnresolvable(failure),
            redacting: makeServer(teleportHostLogin: "deploy")
        )
        #expect(!message.contains("deploy"))
        #expect(!message.contains("root"))
        #expect(message.contains("ambiguousPrincipalSet"))
    }

    @Test
    func redactsLiteralIPAddressesWithoutServerContext() {
        let message = SSHError.diagnosticsMessage(
            for: SSHError.socketError("Connection refused (10.0.0.5:22)"),
            redacting: nil
        )

        #expect(message == #"socketError("Connection refused (<addr>)")"#)
    }

    @Test
    func redactsBareIPv4Literals() {
        let message = SSHError.redacted("peer 192.168.1.1 closed the connection", server: nil)

        #expect(message == "peer <addr> closed the connection")
    }

    @Test
    func leavesNonSensitiveErrorsUntouched() {
        let message = SSHError.diagnosticsMessage(for: SSHError.timeout, redacting: makeServer())

        #expect(message == "timeout")
    }

    @Test
    func rendersNonSSHErrorsWithoutCrashing() {
        let message = SSHError.diagnosticsMessage(
            for: CancellationError(),
            redacting: makeServer()
        )

        #expect(message == "CancellationError()")
    }

    @Test
    func hostReplacementDoesNotCorruptContainedSubstrings() {
        let message = SSHError.redacted(
            "teleporting to teleport.pcad.it failed; retry teleport.pcad.it:443",
            server: makeServer()
        )

        // "teleporting" is a different token; only the exact host and the
        // host:port pair are replaced.
        #expect(message == "teleporting to <host> failed; retry <host>:<port>")
    }
}
