// SPDX-License-Identifier: MIT
//
//  TeleportAgentForwardingPinsTests.swift
//  VVTermTests
//
//  Source pins for the parts of the forwarded-agent path that cannot be
//  exercised in-process (there is no SSH server fixture in the test target):
//
//    - the `auth-agent-req@openssh.com` request and the AUTHAGENT callback
//      registration precede the `proxy:<node>:0` subsystem request;
//    - the AUTHAGENT callback performs no libssh2 I/O and no `SessionMutex`
//      work (it runs inside the packet-receive path);
//    - no agent byte material (key blob, signature, request data, PEM) is
//      logged anywhere in the agent module;
//    - the agent identity and the inner authentication come from the same
//      resolved credential material (a different pair would sign for an
//      identity the node rejects).
//
//  Precedent for the source-scan shape: `SSHErrorDiagnosticsTests`
//  `innerSessionPrepareFailureLogUsesTheRedactionSpine`.
//

import Foundation
import Testing
@testable import VVTerm

struct TeleportAgentForwardingPinsTests {

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportAgentForwardingPinsTests.swift
            .deletingLastPathComponent()  // SSH/
            .deletingLastPathComponent()  // VVTermTests/
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// The SSHSession prepare implementation region, which holds the agent
    /// request/subsystem ordering. There is also an `SSHClient` actor wrapper
    /// with the same signature, so this anchors on the SSHSession body's first
    /// statement and walks back to the enclosing function header. Works for
    /// both the plain function and the wrapper/body split.
    private func prepareBody(in source: String) throws -> Substring {
        let guardLine = try #require(
            source.range(of: "guard config.authMethod == .faceIDTeleport else { return }")
        )
        let header = try #require(
            source.range(
                of: "func prepareTeleportInnerSession() async throws {",
                options: .backwards,
                range: source.startIndex..<guardLine.upperBound
            )
        )
        let end = try #require(
            source.range(of: "private func installAgentForwarding", range: guardLine.upperBound..<source.endIndex)
        )
        return source[header.lowerBound..<end.lowerBound]
    }

    /// The `installAgentForwarding` region (callback registration + request).
    private func installRegion(in source: String) throws -> Substring {
        let start = try #require(source.range(of: "private func installAgentForwarding"))
        let end = try #require(
            source.range(of: "private func teardownAgentForwarding", range: start.upperBound..<source.endIndex)
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    @Test
    func prepareRequestsTheAgentAndInstallsTheCallbackBeforeTheSubsystem() throws {
        let source = try source("VVTerm/Core/SSH/SSHClient.swift")
        let body = try prepareBody(in: source)
        let install = try installRegion(in: source)

        // The install (callback + request) is invoked before the subsystem
        // request, so a proxy that opens its agent channel while handling the
        // subsystem already finds the callback and identity installed.
        let installCall = try #require(
            body.range(of: "installAgentForwarding("),
            "prepareTeleportInnerSession must install agent forwarding"
        )
        let subsystem = try #require(
            body.range(of: "TeleportProxySubsystem.request"),
            "prepareTeleportInnerSession must request the proxy subsystem"
        )
        #expect(installCall.lowerBound < subsystem.lowerBound, "agent forwarding must precede the subsystem request")

        let callback = try #require(
            install.range(of: "LIBSSH2_CALLBACK_AUTHAGENT"),
            "installAgentForwarding must install the AUTHAGENT callback"
        )
        let request = try #require(
            install.range(of: "libssh2_channel_request_auth_agent"),
            "installAgentForwarding must request the agent channel"
        )
        #expect(callback.lowerBound < request.lowerBound, "the callback must be registered before the agent request")
    }

    @Test
    func authAgentCallbackIsQueueOnly() throws {
        // The callback runs inside libssh2's packet-receive path (possibly
        // while the bridge pump holds the non-reentrant SessionMutex), so it
        // must never call into libssh2 or the mutex.
        let source = try source("VVTerm/Features/Teleport/Infrastructure/TeleportAgentForwarding.swift")
        let start = try #require(source.range(of: "private let teleportAuthAgentCallback"))
        let rest = source[start.lowerBound...]
        let end = try #require(rest.range(of: "// MARK:", range: rest.index(after: rest.startIndex)..<rest.endIndex))
        let callbackBody = rest[..<end.lowerBound]

        #expect(!callbackBody.contains("libssh2_"), "the AUTHAGENT callback must not perform libssh2 I/O")
        #expect(!callbackBody.contains("SessionMutex"), "the AUTHAGENT callback must not take the session mutex")
        #expect(callbackBody.contains("TeleportAgentCallbackRegistry"), "the callback must route through the registry")
    }

    @Test
    func agentModuleNeverLogsAgentByteMaterial() throws {
        let agentFiles = [
            "VVTerm/Core/SSH/SSHAgentProtocolCodec.swift",
            "VVTerm/Core/SSH/OpenSSHEd25519PrivateKey.swift",
            "VVTerm/Features/Teleport/Infrastructure/TeleportAgentForwarding.swift",
            "VVTerm/Core/SSH/SSHClient.swift",
        ]
        let forbidden = [
            "keyBlob",
            "certBlob",
            "identityBlob",
            "privateKeyPEM",
            "publicKeyBlob",
            "signature",
            "requestData",
            "rawBlob",
        ]

        for file in agentFiles {
            let lines = try source(file).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("logger.") {
                for token in forbidden {
                    #expect(
                        !line.contains(token),
                        "\(file):\(index + 1) logs agent byte material (\(token)): \(line)"
                    )
                }
            }
        }
    }

    @Test
    func proxySubsystemRejectionUsesTheBoundedCaptureAndSurfacedCase() throws {
        // #268: the old path read stderr once with `String(cString:)` (an
        // out-of-bounds read on a full buffer) and threw a payload-free
        // `.shellRequestFailed`, which the shell-start guard masked as
        // `.notConnected`.
        let source = try source("VVTerm/Core/SSH/SSHClient.swift")
        let body = try prepareBody(in: source)
        #expect(body.contains("TeleportSubsystemStderrCapture.capture"))
        #expect(body.contains("TeleportSubsystemFailureMessage.display"))
        #expect(body.contains("throw SSHError.teleportPrepareFailed"))
        #expect(
            !body.contains("String(cString: stderrBuf"),
            "the stderr buffer must be decoded by the actual byte count, never by a NUL scan"
        )
    }

    @Test
    func proxySubsystemFailureLogIsPayloadFree() throws {
        // The proxy's channel stderr (and the subsystem name, which embeds the
        // node name) must never reach OSLog/the diagnostics ring: the E2E
        // workflow uploads the simulator log and the ring merges into the
        // shareable report. Only the code and byte count are logged.
        let source = try source("VVTerm/Core/SSH/SSHClient.swift")
        let lines = source.components(separatedBy: "\n")
        let markerLines = lines.indices.filter { lines[$0].contains("teleport_proxy_subsystem_failed") }
        #expect(markerLines.count == 1, "expected exactly one proxy-subsystem failure log line")
        let markerLine = try #require(markerLines.first)
        let line = lines[markerLine]
        #expect(!line.contains("stderr="), "the stderr payload must not be logged: \(line)")
        #expect(!line.contains("subsystem="), "the node-embedding subsystem name must not be logged: \(line)")
        #expect(!line.contains("privacy: .public"), "the log line must carry no public payload: \(line)")
        #expect(line.contains("stderr_bytes="), "the byte count is the payload-free diagnostic: \(line)")
    }

    @Test
    func execStderrLogIsPayloadFree() throws {
        // Same class of sink: remote exec stderr is arbitrary server text.
        let source = try source("VVTerm/Core/SSH/SSHClient.swift")
        let lines = source.components(separatedBy: "\n")
        let markerLines = lines.indices.filter { lines[$0].contains("Exec command stderr") }
        #expect(markerLines.count == 1, "expected exactly one exec-stderr log line")
        let markerLine = try #require(markerLines.first)
        let line = lines[markerLine]
        #expect(!line.contains("privacy: .public"), "the exec stderr payload must not be logged: \(line)")
        #expect(line.contains("bytes="), "the byte count is the payload-free diagnostic: \(line)")
    }

    @Test
    func prepareFailureRingEmissionUsesTheRedactionSpine() throws {
        // The prepare failure is rethrown at the connect mask points and also
        // recorded in the on-device ring. The ring message must go through
        // `SSHError.diagnosticsMessage` (case-only for the payload-bearing
        // case), never `localizedDescription`.
        let source = try source("VVTerm/Core/SSH/SSHClient.swift")
        let lines = source.components(separatedBy: "\n")
        let markerLines = lines.indices.filter {
            lines[$0].contains("teleportPrepareFailed \\(")
        }
        #expect(markerLines.count == 1, "expected exactly one prepare-failure ring emission")
        let markerLine = try #require(markerLines.first)
        let window = lines[max(0, markerLine - 6)...markerLine].joined(separator: "\n")
        #expect(window.contains("SSHError.diagnosticsMessage"))
        #expect(!window.contains("localizedDescription"))
    }

    @Test
    func innerAuthenticationReusesTheAgentIdentityMaterial() throws {
        let source = try source("VVTerm/Core/SSH/SSHClient.swift")

        // authenticateInner must not resolve the credential material itself:
        // a second resolution could pair a different certificate with the
        // forwarded agent identity.
        let authStart = try #require(source.range(of: "private func authenticateInner("))
        let authEnd = try #require(
            source.range(of: "private func validateInnerShellStartup", range: authStart.upperBound..<source.endIndex)
        )
        let authBody = source[authStart.lowerBound..<authEnd.lowerBound]
        #expect(
            !authBody.contains("resolveTeleportAuthMaterial"),
            "authenticateInner must use the caller-resolved material, not a fresh resolution"
        )
        #expect(authBody.contains("material: TeleportAuthMaterial"), "authenticateInner must take the resolved material")

        // One resolution in prepareTeleportInnerSession, feeding both the
        // agent identity and the inner auth.
        let prepareBody = try prepareBody(in: source)
        let resolutions = prepareBody.components(separatedBy: "resolveTeleportAuthMaterial()").count - 1
        #expect(resolutions == 1, "prepareTeleportInnerSession must resolve the credential material exactly once")
        #expect(prepareBody.contains("installAgentForwarding("), "the agent identity comes from the resolved material")
        #expect(
            prepareBody.contains("authenticateInner(session: innerSession, material: material)"),
            "the inner auth must use the same resolved material as the agent identity"
        )
    }
}
