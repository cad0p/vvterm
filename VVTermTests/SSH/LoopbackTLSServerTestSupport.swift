// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  LoopbackTLSServerTestSupport.swift
//  VVTermTests
//
//  A minimal in-process TLS server for the SSHTLSTransport handshake tests.
//
//  The certificate/key material comes from
//  `VVTermTests/Features/Teleport/Fixtures/loopback-tls/` and is generated
//  test-only material (committed PKCS#12 + PEM; no production secret). The
//  identity is imported with `SecPKCS12Import` (memory-only on iOS and on
//  macOS 15+ via `kSecImportToMemoryOnly`) so no keychain state is required.
//

#if canImport(Network)
import Foundation
import Network
import Security

enum LoopbackTLSServerTestError: Error {
    case identityImport(OSStatus)
    case listenerStart
}

enum LoopbackTLSServerTestSupport {

    static let fixturePassword = "vvterm-test"

    static func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // VVTermTests/SSH
            .deletingLastPathComponent()          // VVTermTests
            .appendingPathComponent("Features/Teleport/Fixtures/\(relativePath)")
    }

    static func pemString(_ relativePath: String) throws -> String {
        try String(contentsOf: fixtureURL(relativePath), encoding: .utf8)
    }

    /// Import a committed test identity (cert + key) from a PKCS#12 fixture.
    static func identity(named name: String) throws -> SecIdentity {
        let data = try Data(contentsOf: fixtureURL("loopback-tls/\(name)"))
        var options: [String: Any] = [kSecImportExportPassphrase as String: fixturePassword]
        if #available(macOS 15.0, iOS 18.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]],
              let identity = entries.first?[kSecImportItemIdentity as String] else {
            throw LoopbackTLSServerTestError.identityImport(status)
        }
        // SecPKCS12Import returns SecIdentityRef values.
        return (identity as! SecIdentity)
    }
}

/// A loopback `NWListener` presenting the given test identity over TLS.
final class LoopbackTLSServer {

    private(set) var port: UInt16 = 0

    private let listener: NWListener
    private let queue = DispatchQueue(label: "vvterm.tests.loopback-tls")
    private var connections: [NWConnection] = []

    init(identity: SecIdentity, alpnProtocols: [String]) throws {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        guard let secIdentity = sec_identity_create(identity) else {
            throw LoopbackTLSServerTestError.listenerStart
        }
        sec_protocol_options_set_local_identity(sec, secIdentity)
        for proto in alpnProtocols {
            proto.withCString { cStr in
                sec_protocol_options_add_tls_application_protocol(sec, cStr)
            }
        }

        let params = NWParameters(tls: tls)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: params)
        self.listener = listener

        // The handler must be installed before `start`: Network.framework
        // fails a listener started with neither a connection nor a group
        // handler. The weak capture keeps `self` out of the closure; no
        // connection can arrive before `start` below.
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
        }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success,
              listener.state == .ready,
              let assignedPort = listener.port else {
            listener.cancel()
            throw LoopbackTLSServerTestError.listenerStart
        }
        self.port = assignedPort.rawValue
    }

    func stop() {
        listener.cancel()
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
    }

    deinit {
        listener.cancel()
    }
}

#endif // canImport(Network)
