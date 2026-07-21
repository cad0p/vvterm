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
    func bootstrapCommandCapturesETTerminalLoggingOutput() {
        #expect(
            SSHETBootstrapExecutor.commandCapturingCombinedOutput("start-et")
                == "(start-et) 2>&1"
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
}
