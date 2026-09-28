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
        // Counterfactual hook: the guard-sensitivity runs point this at a
        // mutated /tmp tree to prove the pins fail there. Never set in CI.
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
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

    /// Every `logger.` call in `source` (balanced parentheses, so multi-line
    /// calls are covered) as source text.
    private func loggerCalls(in source: String) -> [String] {
        var calls: [String] = []
        var searchStart = source.startIndex
        while let marker = source.range(of: "logger.", range: searchStart..<source.endIndex) {
            guard let open = source[marker.upperBound...].firstIndex(of: "(") else { break }
            var depth = 0
            var cursor = open
            var end: String.Index?
            while cursor < source.endIndex {
                if source[cursor] == "(" {
                    depth += 1
                } else if source[cursor] == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = source.index(after: cursor)
                        break
                    }
                }
                cursor = source.index(after: cursor)
            }
            guard let end else { break }
            calls.append(String(source[marker.lowerBound..<end]))
            searchStart = end
        }
        return calls
    }

    /// The `\(…)` interpolation expressions inside a logger call.
    private func interpolations(in call: String) -> [String] {
        var expressions: [String] = []
        var searchStart = call.startIndex
        while let open = call.range(of: "\\(", range: searchStart..<call.endIndex) {
            var depth = 1
            var cursor = open.upperBound
            while cursor < call.endIndex, depth > 0 {
                if call[cursor] == "(" {
                    depth += 1
                } else if call[cursor] == ")" {
                    depth -= 1
                }
                if depth == 0 { break }
                cursor = call.index(after: cursor)
            }
            guard depth == 0 else { break }
            expressions.append(String(call[open.upperBound..<cursor]))
            searchStart = call.index(after: cursor)
        }
        return expressions
    }

    @Test
    func agentModuleNeverLogsAgentByteMaterial() throws {
        // Property check: no `\(…)` interpolation in an agent-module logger
        // call may reference a byte-carrying accessor of the identity/material
        // types (certificate/key bytes, blobs, PEMs, seeds, signatures, the
        // sign payload). A `.count` of a buffer is the payload-free
        // alternative and is allowed.
        let agentFiles = [
            "VVTerm/Core/SSH/SSHAgentProtocolCodec.swift",
            "VVTerm/Core/SSH/OpenSSHEd25519PrivateKey.swift",
            "VVTerm/Features/Teleport/Infrastructure/TeleportAgentForwarding.swift",
            "VVTerm/Core/SSH/SSHClient.swift",
        ]
        let byteAccessors = [
            "certData", "keyData", "certPEM", "keyPEM", "privateKeyPEM",
            "certBlob", "keyBlob", "identityBlob", "publicKeyBlob", "rawBlob",
            "publicKeyRaw", "signingKey", "seed", "signature", "requestData",
            "identityMaterial",
        ]

        for file in agentFiles {
            let source = try source(file)
            for call in loggerCalls(in: source) {
                for interpolation in interpolations(in: call) {
                    let expression = interpolation.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !expression.hasSuffix(".count") else { continue }
                    for accessor in byteAccessors where expression.contains(accessor) {
                        Issue.record(
                            "\(file) interpolates agent byte material (\(accessor)) into a log call: \(call)"
                        )
                    }
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
    func proxySubsystemLogsArePayloadFree() throws {
        // The proxy's channel stderr (and the subsystem name, which embeds the
        // node name) must never reach OSLog/the diagnostics ring: the E2E
        // workflow uploads the simulator log and the ring merges into the
        // shareable report. Only the code and byte count are logged, and the
        // success line carries no payload at all.
        let source = try source("VVTerm/Core/SSH/SSHClient.swift")
        let lines = source.components(separatedBy: "\n")

        let failureLines = lines.indices.filter { lines[$0].contains("teleport_proxy_subsystem_failed") }
        #expect(failureLines.count == 1, "expected exactly one proxy-subsystem failure log line")
        let failureLine = lines[try #require(failureLines.first)]
        #expect(!failureLine.contains("stderr="), "the stderr payload must not be logged: \(failureLine)")
        #expect(!failureLine.contains("subsystem="), "the node-embedding subsystem name must not be logged: \(failureLine)")
        #expect(!failureLine.contains("privacy: .public"), "the log line must carry no public payload: \(failureLine)")
        #expect(failureLine.contains("stderr_bytes="), "the byte count is the payload-free diagnostic: \(failureLine)")

        let successLines = lines.indices.filter { lines[$0].contains("teleport_proxy_subsystem_ok") }
        #expect(successLines.count == 1, "expected exactly one proxy-subsystem success log line")
        let successLine = lines[try #require(successLines.first)]
        #expect(!successLine.contains("subsystem="), "the node-embedding subsystem name must not be logged: \(successLine)")
        #expect(!successLine.contains("target="), "the node name must not be logged: \(successLine)")
        #expect(!successLine.contains("privacy:"), "the success line must carry no payload: \(successLine)")
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

    @Test
    func teleportPrepareFailureRethrowsAtEveryMaskPoint() throws {
        // #268: `remoteEnvironment()` swallows the prepare failure, so every
        // shell/exec mask point must rethrow the stored SSHError instead of
        // masking it as `.notConnected`.
        let source = try source("VVTerm/Core/SSH/SSHClient.swift")
        let rethrow = "throw lastTeleportPrepareFailure ?? SSHError.notConnected"

        // Three guard rethrows: SSHSession.startShell and execute()'s
        // route-to-inner + reject-on-outer guards.
        let total = source.components(separatedBy: rethrow).count - 1
        #expect(total == 3, "expected the stored prepare failure at three mask points, found \(total)")

        let startShellGuard = try #require(
            source.range(of: "guard isActive, let session = libssh2Session else {")
        )
        let startShellRethrow = source[startShellGuard.upperBound...].prefix(160)
        #expect(
            startShellRethrow.contains(rethrow),
            "SSHSession.startShell must rethrow the stored failure from its isActive guard"
        )

        let executeStart = try #require(
            source.range(of: "func execute(_ command: String) async throws -> String {")
        )
        let executeEnd = try #require(
            source.range(
                of: "nonisolated static func shouldRouteExecToInnerSession",
                range: executeStart.upperBound..<source.endIndex
            )
        )
        let executeBody = source[executeStart.lowerBound..<executeEnd.lowerBound]
        let executeRethrows = executeBody.components(separatedBy: rethrow).count - 1
        #expect(executeRethrows == 2, "execute() must rethrow the stored failure on both Teleport guards")

        // SSHClient.startShell rethrows through the helper; the helper must
        // throw the stored failure itself, never a fallback.
        let helperStart = try #require(
            source.range(of: "private func rethrowStoredTeleportPrepareFailure")
        )
        let helperEnd = try #require(
            source.range(of: "// MARK: - Mosh", range: helperStart.upperBound..<source.endIndex)
        )
        let helperBody = source[helperStart.lowerBound..<helperEnd.lowerBound]
        #expect(helperBody.contains("lastTeleportPrepareFailure"))
        #expect(helperBody.contains("throw failure"), "the helper must throw the stored failure")
        #expect(
            source.contains("try await rethrowStoredTeleportPrepareFailure(from: sshSession)"),
            "SSHClient.startShell must call the stored-failure rethrow"
        )
    }

    @Test
    func teleportPrepareFailureSnapshotIsPerSessionAndHopFree() throws {
        // #276/D3: the stored prepare failure used to be an actor-isolated
        // property, so `rethrowStoredTeleportPrepareFailure` hopped into
        // SSHSession — a startup park candidate. It must now be a
        // per-session lock-protected box read without a hop. A client-owned
        // shared box is forbidden: it would be stale across sessions and
        // miss SSHSession.connect()'s clear.
        let source = try source("VVTerm/Core/SSH/SSHClient.swift")

        #expect(
            source.contains(
                "private let lastTeleportPrepareFailureBox = OSAllocatedUnfairLock<SSHError?>(initialState: nil)"
            ),
            "the stored prepare failure must be a lock-protected box owned by SSHSession"
        )
        #expect(
            source.contains("let failure = session.lastTeleportPrepareFailure"),
            "the helper must read the per-session snapshot directly"
        )
        #expect(
            !source.contains("await session.lastTeleportPrepareFailure"),
            "the helper must not hop into the session actor for the stored failure"
        )
    }
}
