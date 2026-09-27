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
