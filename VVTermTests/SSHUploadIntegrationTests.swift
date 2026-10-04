// SPDX-License-Identifier: MIT
//
//  SSHUploadIntegrationTests.swift
//  VVTermTests
//
//  Env-gated real-sshd coverage for the SCP/exec upload family (issue #291).
//
//  Three legs against the loopback fixture sshd:
//    1. `.execPreferred` upload + read-back (the strategy clipboard uploads
//       use on darwin/BSD/windows),
//    2. `.automatic` upload + read-back (the SCP-first path),
//    3. `.execPreferred` to a path whose `cat > <path>` fails (missing parent
//       directory) — the reachable finding-A path: a non-zero exit status
//       makes the caller throw after `finishUploadChannel`, and before the
//       fix its catch freed the already-freed channel a second time.
//
//  Leg 3 is the only end-to-end exercise of the reachable defect. Passing it
//  WITHOUT allocator hardening is compatible with silent heap corruption, so
//  it is run a second time under `MallocScribble=1` by `teleport-e2e.yml`
//  (`MallocScribble` poisons the freed channel block, turning the second
//  `libssh2_channel_free`'s pointer reads/frees into a deterministic fault).
//  ASan would interpose `free` too but costs a full sanitized rebuild per
//  matrix leg; the workflow's hardening step carries the MallocScribble form.
//
//  Fixture variables are the repro rig's (`VVTERM_REPRO_SSH_*`, written by
//  `scripts/ci/repro-sshd-setup.sh`), re-exported with the `TEST_RUNNER_`
//  prefix by `teleport-e2e.yml` (plain env vars do not reach the simulator
//  test process). The rig writes `VVTERM_REPRO_SSH_PORT=22229` for the
//  bytemeter proxy; the workflow overrides it to sshd's 22232, exactly as
//  PR CI does.
//
//  Not covered: the parked-teardown window has no reproduction (the guards
//  are the structural invariant), so these legs are normal-path and
//  failure-path regression coverage only.
//
//  Connect budget (#356): the app default (30 s) is not a contended-CI-host
//  budget. On the dispatch-only `teleport-e2e` runner the *first* handshake
//  measured 20.28 s, 22.98 s and 29.69 s in the slow regime, and the ~30.8 s
//  failures were the app default's right-censored cap (`code=-9`), not the
//  stall length. The legs therefore connect with `contendedConnectBudget`
//  (90 s = 3× the slow-regime 29.7 s success); the app default stays 30 s,
//  and `SSHSessionHandshakeBudget` derives the matching session-I/O /
//  watchdog caps from whatever budget the client carries.

import Foundation
import Testing

@testable import VVTerm

// MARK: - Fixture

/// The repro-rig fixture the suite gates on. Reads the rig's variables
/// directly; returns nil (the suite skips) unless the private key and port
/// are both present and valid, so a local run without the rig stays inert
/// and a CI run with the rig cannot silently execute a half-configured
/// fixture.
private struct UploadFixtureConfiguration {
    let host: String
    let port: Int
    let username: String
    let privateKey: Data
    let hostKeyFingerprint: String?
    let hostKeyType: Int

    static var isAvailable: Bool {
        fromEnvironment() != nil
    }

    static func fromEnvironment() -> UploadFixtureConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        guard let encodedKey = environment["VVTERM_REPRO_SSH_PRIVATE_KEY"],
              !encodedKey.isEmpty,
              let privateKey = Data(base64Encoded: encodedKey),
              !privateKey.isEmpty,
              let rawPort = environment["VVTERM_REPRO_SSH_PORT"],
              let port = Int(rawPort),
              (1...65_535).contains(port) else {
            return nil
        }
        return UploadFixtureConfiguration(
            host: environment["VVTERM_REPRO_SSH_HOST"] ?? "127.0.0.1",
            port: port,
            username: environment["VVTERM_REPRO_SSH_USERNAME"] ?? "vvterm",
            privateKey: privateKey,
            hostKeyFingerprint: environment["VVTERM_REPRO_SSH_HOST_KEY_FINGERPRINT"],
            hostKeyType: Int(environment["VVTERM_REPRO_SSH_HOST_KEY_TYPE"] ?? "") ?? 6
        )
    }
}

@Suite(.serialized, .enabled(if: UploadFixtureConfiguration.isAvailable))
@MainActor
struct SSHUploadIntegrationTests {

    // MARK: - Connect budget (#356)

    /// The connect budget these legs give the fixture sshd on a contended CI
    /// host. Measured in the slow regime on the `teleport-e2e` runner: the
    /// uncensored first-handshake successes were 20.28 s, 22.98 s and 29.69 s
    /// (the ~30.8 s failures were the app default's right-censored cap, not
    /// the stall length), so 90 s ≈ 3× the slow-mode 29.7 s success. The app
    /// default stays 30 s; this is the test's budget.
    static let contendedConnectBudget: Duration = .seconds(90)

    /// The one construction site for a leg's client. The app default's 30 s
    /// budget is inert for a contended host (#356), so apply the measured
    /// `contendedConnectBudget`. `withConnection` must route through this
    /// factory — pinned by `SSHUploadIntegrationConnectBudgetPinsTests`.
    static func makeUploadClient() async -> SSHClient {
        let client = SSHClient()
        await client.setConnectTimeout(contendedConnectBudget)
        return client
    }

    // MARK: - Helpers

    /// Connect, run `body`, always disconnect.
    ///
    /// Pre-seeds the fixture sshd's host key from the rig's fingerprint/type
    /// because the production `verifyHostKey` throws `hostKeyUnknown` on
    /// first use; the previous `KnownHostsManager` entry is restored
    /// afterwards so the suite does not leak trust state into other suites.
    private func withConnection<T>(
        _ configuration: UploadFixtureConfiguration,
        _ body: (SSHClient) async throws -> T
    ) async throws -> T {
        let previousEntry = KnownHostsManager.shared.entry(
            for: configuration.host,
            port: configuration.port
        )
        if let fingerprint = configuration.hostKeyFingerprint, !fingerprint.isEmpty {
            KnownHostsManager.shared.save(entry: KnownHostsManager.Entry(
                host: configuration.host,
                port: configuration.port,
                fingerprint: fingerprint,
                keyType: configuration.hostKeyType,
                addedAt: Date(),
                lastSeenAt: Date()
            ))
        }
        defer {
            if let previousEntry {
                KnownHostsManager.shared.save(entry: previousEntry)
            } else {
                KnownHostsManager.shared.remove(
                    host: configuration.host,
                    port: configuration.port
                )
            }
        }

        let server = Server(
            workspaceId: UUID(),
            name: "DEV-291 upload integration",
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            connectionMode: .standard,
            authMethod: .sshKey
        )
        let credentials = ServerCredentials(
            serverId: server.id,
            privateKey: configuration.privateKey
        )
        let client = await Self.makeUploadClient()
        do {
            _ = try await client.connect(to: server, credentials: credentials)
            let result = try await body(client)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// Deterministic multi-block payload: enough bytes to exercise the write
    /// loop's EAGAIN branch on a real socket, with markers at both ends so a
    /// truncated/pruned upload fails the comparison loudly.
    private static func uploadPayload() -> Data {
        var text = "__VVTERM_UPLOAD_HEAD__\n"
        for index in 0..<256 {
            text += "vvterm-upload-payload-\(index)\n"
        }
        text += "__VVTERM_UPLOAD_TAIL__\n"
        return Data(text.utf8)
    }

    private static func remoteTempPath() -> String {
        "/tmp/vvterm-upload-int-\(UUID().uuidString.lowercased()).txt"
    }

    /// Upload `payload` to a fresh remote path, read it back with `cat`, and
    /// remove it. The read-back is the assertion: a failed/truncated upload
    /// cannot produce the exact payload.
    private func assertUploadRoundTrip(
        using client: SSHClient,
        strategy: SSHUploadStrategy
    ) async throws {
        let path = Self.remoteTempPath()
        let quotedPath = RemoteTerminalBootstrap.shellQuoted(path)
        let payload = Self.uploadPayload()
        do {
            try await client.upload(payload, to: path, strategy: strategy)
            let readBack = try await client.execute("cat \(quotedPath)")
            #expect(
                readBack == String(decoding: payload, as: UTF8.self),
                "the uploaded payload must round-trip byte-for-byte"
            )
            _ = try await client.execute("rm -f \(quotedPath)")
        } catch {
            _ = try? await client.execute("rm -f \(quotedPath)")
            throw error
        }
    }

    // MARK: - Legs

    /// Leg 1: `.execPreferred` (the production clipboard-upload strategy on
    /// darwin) uploads, and the content round-trips.
    @Test
    func testExecPreferredUploadRoundTrips() async throws {
        let configuration = try #require(UploadFixtureConfiguration.fromEnvironment())
        try await withConnection(configuration) { client in
            try await assertUploadRoundTrip(using: client, strategy: .execPreferred)
        }
    }

    /// Leg 2: `.automatic` (SCP first, then exec) uploads, and the content
    /// round-trips.
    @Test
    func testAutomaticUploadRoundTrips() async throws {
        let configuration = try #require(UploadFixtureConfiguration.fromEnvironment())
        try await withConnection(configuration) { client in
            try await assertUploadRoundTrip(using: client, strategy: .automatic)
        }
    }

    /// Leg 3 (the finding-A path): `cat > <path>` with a missing parent
    /// directory exits non-zero after the close handshake, so
    /// `finishUploadChannel` returns a non-zero status and the caller throws.
    ///
    /// Before the fix the caller's catch closed and freed the channel a
    /// second time. This assertion is therefore split:
    ///   - here (unhardened): the upload fails with a clean `SSHError`, the
    ///     client is still usable, and the remote path was not created;
    ///   - in `teleport-e2e.yml`'s hardening step (`MallocScribble=1`): the
    ///     second free is a deterministic fault on an unfixed build.
    @Test
    func testExecPreferredUploadToAMissingParentFailsCleanlyAndLeavesTheClientUsable() async throws {
        let configuration = try #require(UploadFixtureConfiguration.fromEnvironment())
        try await withConnection(configuration) { client in
            let missingParent = "/tmp/vvterm-upload-int-missing-\(UUID().uuidString.lowercased())"
            let path = "\(missingParent)/upload.txt"
            let quotedPath = RemoteTerminalBootstrap.shellQuoted(path)

            do {
                try await client.upload(Self.uploadPayload(), to: path, strategy: .execPreferred)
                Issue.record("exec upload to a missing parent directory unexpectedly succeeded")
            } catch let error as SSHError {
                // The failing `cat >` surface must be the exec exit-status
                // error, not a transport failure or a crash.
                guard case .socketError(let message) = error else {
                    Issue.record("exec upload to a missing parent returned unexpected SSHError: \(error)")
                    return
                }
                #expect(
                    message.contains("Exec upload failed with exit status"),
                    "unexpected exec upload failure text: \(message)"
                )
            }

            // The remote path must not exist (cat never created it).
            let probe = "__VVTERM_UPLOAD_ABSENT__"
            let probeOutput = try await client.execute(
                "test ! -e \(quotedPath) && printf %s \(probe)"
            )
            #expect(probeOutput == probe, "the failing upload must not leave a partial remote file")

            // The client must remain usable after the failure: the race the
            // guards contain is exactly "the catch touched a dead channel",
            // so a follow-up command on the same session is the regression
            // signal.
            let marker = "__VVTERM_UPLOAD_RECOVERY__"
            let output = try await client.execute("printf %s \(marker)")
            #expect(output == marker, "the client must stay usable after a failing upload")
        }
    }
}
