import ETBootstrap
import ETSession
import Testing
@testable import VVTerm

struct EternalTerminalStatePolicyTests {
    @Test
    func recoverableTransportStatesRemainInReconnectPresentation() {
        #expect(
            EternalTerminalStatePolicy.connectionState(
                for: .disconnected,
                host: "example.com",
                port: 2022
            ) == .reconnecting(attempt: 1)
        )
        #expect(
            EternalTerminalStatePolicy.connectionState(
                for: .reconnecting,
                host: "example.com",
                port: 2022
            ) == .reconnecting(attempt: 1)
        )
    }

    @Test
    func permanentRecoveryFailureRequiresANewSession() {
        let state = EternalTerminalStatePolicy.connectionState(
            for: .failed(.sessionUnrecoverable("history expired")),
            host: "example.com",
            port: 2022
        )

        #expect(state == .failed("The Eternal Terminal session can no longer recover. Reconnect to start a new session."))
        #expect(
            EternalTerminalErrorPresentation.analyticsCategory(
                for: ETClientError.sessionUnrecoverable("history expired")
            ) == "recovery"
        )
    }

    @Test
    func transportFailureIncludesTheConfiguredEndpoint() {
        let message = EternalTerminalErrorPresentation.message(
            for: ETClientError.transportFailure("offline"),
            host: "et.example.com",
            port: 22022
        )

        #expect(message.contains("et.example.com:22022"))
        #expect(message.contains("TCP port 22022"))
    }

    @Test
    func bootstrapCommandUsesKnownPOSIXShellAndExpandedPath() {
        let command = SSHETBootstrapExecutor.remoteBootstrapCommand("start-et")

        #expect(command.hasPrefix("/bin/sh -lc"))
        #expect(command.contains("export PATH="))
        #expect(command.contains("command -v etterminal"))
        #expect(command.contains("start-et"))
        #expect(!command.contains("(start-et) 2>&1"))
    }

    @Test
    func bootstrapRequestsETTerminalDiagnosticsOnStandardOutput() {
        #expect(
            SSHETBootstrapExecutor.bootstrapOptions.etterminalPath
                == "etterminal --logtostdout"
        )
    }

    @Test
    func missingBootstrapMarkerIncludesTheSanitizedHostResponse() {
        let message = EternalTerminalErrorPresentation.message(
            for: ETBootstrapError.markerNotFound("sh: etterminal: command not found"),
            host: "example.com",
            port: 2022
        )

        #expect(message.contains("Host response:"))
        #expect(message.contains("etterminal: command not found"))
    }

    @Test
    func unavailableETDaemonHasActionableServiceGuidance() {
        let message = EternalTerminalErrorPresentation.message(
            for: ETBootstrapError.markerNotFound(
                "Error: Connection error communicating with et daemon: No such file or directory."
            ),
            host: "example.com",
            port: 2022
        )

        #expect(message.contains("etterminal is installed"))
        #expect(message.contains("Start or restart the et service"))
        #expect(!message.contains("Stack Trace"))
    }
}
