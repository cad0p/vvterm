// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportSFTPRoutingTests.swift
//  VVTermTests
//
//  Documents the Teleport SFTP routing policy.
//
//  Teleport servers connect through a two-session path: the OUTER session is
//  the Teleport PROXY (TLS+ALPN on port 443), which is in `proxyMode` and
//  rejects `exec`/`pty`/`shell`/`sftp` channel requests with
//  LIBSSH2_ERROR_CHANNEL_REQUEST_FAILURE (-22). The remote file browser runs
//  `libssh2_sftp_init(session)` + `libssh2_sftp_*` operations, which must
//  target the INNER (target-node) session — established by
//  `SSHClient.prepareTeleportInnerSession()` (second handshake over the
//  `proxy:<node>:0` subsystem tunnel) — so the SFTP subsystem channel opens
//  on the node that actually supports it.
//
//  Before the inner session is ready (e.g. before
//  `prepareTeleportInnerSession()` completes), SFTP must surface a clear
//  "not ready" error rather than attempting SFTP init on the outer proxy
//  session (which fails with "Failed to start SFTP session"). Runtime
//  readiness is gated by `SSHClient.supportsSFTP`.
//

import XCTest
@testable import VVTerm

final class TeleportSFTPRoutingTests: XCTestCase {

    // MARK: - SSHSession inner-SFTP routing decision

    /// `SSHSession.shouldRouteSFTPToInnerSession(authMethod:innerSessionReady:)`
    /// is the pure routing decision extracted from `ensureSFTPSession()`. It
    /// must route SFTP to the inner session ONLY for Teleport AND when the
    /// inner session is ready. For every other combination (non-Teleport, or
    /// Teleport with no inner session yet) it returns `false` so the outer
    /// path is preserved.
    func testSFTPRoutingRoutesToInnerForTeleportWhenReady() {
        XCTAssertTrue(
            SSHSession.shouldRouteSFTPToInnerSession(
                authMethod: .faceIDTeleport,
                innerSessionReady: true
            ),
            "Teleport with a ready inner session must route SFTP to the inner session"
        )
    }

    func testSFTPRoutingDoesNotRouteToInnerWhenInnerNotReady() {
        // Before prepareTeleportInnerSession completes the inner session is
        // nil. SFTP must NOT route to a non-existent inner session — it would
        // fail to init the SFTP subsystem.
        XCTAssertFalse(
            SSHSession.shouldRouteSFTPToInnerSession(
                authMethod: .faceIDTeleport,
                innerSessionReady: false
            ),
            "Teleport without a ready inner session must not route SFTP to the inner session"
        )
    }

    func testSFTPRoutingDoesNotRouteToInnerForNonTeleport() {
        // Non-Teleport auth methods use the direct outer session, which
        // supports SFTP. Routing them to a (non-existent) inner session
        // would break existing file browsing.
        for method: AuthMethod in [.password, .sshKey, .sshKeyWithPassphrase] {
            XCTAssertFalse(
                SSHSession.shouldRouteSFTPToInnerSession(
                    authMethod: method,
                    innerSessionReady: true
                ),
                "\(method) must never route SFTP to the inner session"
            )
        }
    }

    // MARK: - SSHClient.supportsSFTP contract

    /// `SSHClient.supportsSFTP` is the runtime readiness gate that file-
    /// browser callers consult before attempting SFTP operations. For
    /// Teleport it mirrors `supportsExec` (requires the inner session); for
    /// every other auth method it mirrors `isConnected`. This is a
    /// compile-time contract test: if the property is removed or renamed,
    /// this file fails to compile.
    func testSSHClientExposesSupportsSFTP() {
        // The method signature `var supportsSFTP: Bool { get async }` must
        // stay on `SSHClient` so callers can gate SFTP operations without
        // reaching into `SSHSession` internals.
        let access: @Sendable (SSHClient) async -> Bool = { client in
            await client.supportsSFTP
        }
        _ = access
        XCTAssertTrue(true, "SSHClient.supportsSFTP exists and is callable")
    }

    // MARK: - SFTP-on-outer-session landmine closure

    /// `SSHSession.shouldRejectSFTPOnOuterSession(authMethod:innerSessionReady:)`
    /// is the pure safety-net decision extracted from `ensureSFTPSession()`.
    /// When SFTP init would otherwise fall through to the OUTER (proxy)
    /// session for a Teleport client whose inner session is NOT ready,
    /// `ensureSFTPSession()` must surface a clear error instead of attempting
    /// `libssh2_sftp_init` on the outer session — which fails with -22 and
    /// poisons the outer session state so the subsequent subsystem request
    /// also fails.
    ///
    /// The decision returns `true` (reject) ONLY for the Teleport auth method
    /// AND when the inner session is not ready. For non-Teleport (outer
    /// session supports SFTP directly) and for Teleport-with-ready-inner
    /// (SFTP routes to the inner session), it returns `false`.
    func testShouldRejectSFTPOnOuterSessionForTeleportWhenInnerNotReady() {
        XCTAssertTrue(
            SSHSession.shouldRejectSFTPOnOuterSession(
                authMethod: .faceIDTeleport,
                innerSessionReady: false
            ),
            "Teleport without a ready inner session must not run SFTP on the outer session"
        )
    }

    func testShouldNotRejectSFTPOnOuterSessionForTeleportWhenInnerReady() {
        // Inner session ready: SFTP routes to the inner session via
        // `shouldRouteSFTPToInnerSession`; the outer-session fallthrough is
        // never reached, so the rejection guard must not fire.
        XCTAssertFalse(
            SSHSession.shouldRejectSFTPOnOuterSession(
                authMethod: .faceIDTeleport,
                innerSessionReady: true
            ),
            "Teleport with a ready inner session must not reject outer-session SFTP"
        )
    }

    func testShouldNotRejectSFTPOnOuterSessionForNonTeleport() {
        // Non-Teleport auth methods use the direct outer session, which
        // supports SFTP. They must never be rejected at the outer-session
        // fallthrough.
        for method: AuthMethod in [.password, .sshKey, .sshKeyWithPassphrase] {
            XCTAssertFalse(
                SSHSession.shouldRejectSFTPOnOuterSession(
                    authMethod: method,
                    innerSessionReady: false
                ),
                "\(method) must never be rejected at the outer-session SFTP fallthrough"
            )
        }
    }
}
