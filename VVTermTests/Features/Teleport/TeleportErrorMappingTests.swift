// SPDX-License-Identifier: MIT
//
//  TeleportErrorMappingTests.swift
//  VVTermTests
//
//  Seam-contract coverage for the `TeleportPackageError` → `SSHError`
//  boundary: messages must be byte-identical, and the mapped error must
//  still classify as an `SSHError` so `SSHConnectionRunner`'s
//  disconnect-before-retry path keeps firing.
//

#if DEBUG
import Foundation
import Security
import Testing
@testable import VVTerm

struct TeleportErrorMappingTests {

    @Test
    func packageConnectionFailureMapsToByteIdenticalSSHError() {
        let packageError = TeleportPackageError.connectionFailed("TLS transport connect failed: boom")
        #expect(packageError.errorDescription == "Connection failed: TLS transport connect failed: boom")

        let mapped = TeleportErrorMapping.map(packageError)
        guard let sshError = mapped as? SSHError,
              case .connectionFailed(let message) = sshError else {
            Issue.record("expected SSHError.connectionFailed, got \(mapped)")
            return
        }
        #expect(message == "TLS transport connect failed: boom")
        #expect(sshError.errorDescription == packageError.errorDescription)
        // SSHConnectionRunner classification: `.connectionFailed` triggers
        // the disconnect-before-retry reset.
        #expect(sshError.allowsAutomaticReconnectRetry)
    }

    @Test
    func packageKeychainFailureMapsWithByteIdenticalMessage() {
        let status = errSecAuthFailed
        let packageError = TeleportPackageError.keychain(status)
        // Byte-identical to the host error the package file used to throw.
        #expect(packageError.errorDescription == KeychainError.unhandled(status).errorDescription)
        #expect(packageError.errorDescription == "Keychain error: \(status)")

        // The keychain case never crosses into `SSHSession` today; the host
        // mapping is a safety net that maps back to the exact host error
        // (`KeychainError.unhandled`), so the rendered description stays
        // byte-identical instead of gaining an "Unknown error:" prefix.
        let mapped = TeleportErrorMapping.map(packageError)
        guard let keychainError = mapped as? KeychainError,
              case .unhandled(let mappedStatus) = keychainError else {
            Issue.record("expected KeychainError.unhandled, got \(mapped)")
            return
        }
        #expect(mappedStatus == status)
        #expect(keychainError.errorDescription == packageError.errorDescription)
    }

    @Test
    func nonPackageErrorsPassThroughUnchanged() {
        struct HostError: Error, Equatable { let value: Int }
        let hostError = HostError(value: 7)
        let mapped = TeleportErrorMapping.map(hostError)
        #expect(mapped as? HostError == hostError)
    }
}
#endif
