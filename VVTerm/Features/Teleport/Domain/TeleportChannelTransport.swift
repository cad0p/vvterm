// SPDX-License-Identifier: MIT
//
//  TeleportChannelTransport.swift
//  VVTerm
//
//  Package-movable seams for the libssh2 channel bridge used by the Teleport
//  proxy-subsystem path (D6 #3/#4).
//
//  The implementation stays host-side: `SessionMutex` conforms to
//  `TeleportSessionMutex`, `SSHProxySubsystemTransport` conforms to
//  `TeleportChannelTransport`, and the factory implementation lives in the
//  bridge file. These protocols never mention a host type, so the movable
//  package can depend on them.
//
//  Cancellation must stay synchronous: `cancelPumpSync()` is called from
//  `SSHSession.invalidateTransport` / `cleanupLibssh2` (and `cleanup`) to
//  stop the pump BEFORE the outer libssh2 session is freed — an `await`
//  there could deadlock (the actor may be blocked in a pump-adjacent path).
//  Hence the `nonisolated` requirement with no `async`.
//

import Foundation

/// A synchronous mutex guarding all libssh2 calls on the outer (proxy)
/// session. `SessionMutex` (host-side) conforms.
protocol TeleportSessionMutex: Sendable {
    /// Acquire the mutex, run `body`, release. Returns `body`'s result.
    func withLock<T>(_ body: () -> T) -> T
}

/// A socketpair bridge that exposes a raw FD for the inner libssh2 session.
/// `SSHProxySubsystemTransport` (host-side) conforms.
protocol TeleportChannelTransport: Sendable {
    /// Create the socketpair, start the pump, and return the libssh2 FD.
    func start() async throws -> Int32

    /// Tear down the pump + the pump-end FD. `async` because the conforming
    /// implementation is an actor.
    func close() async

    /// Stop the pump synchronously (callable without `await`) so the caller
    /// can free the outer libssh2 session without a use-after-free.
    nonisolated func cancelPumpSync()
}

/// Builds the channel transport for an outer proxy-subsystem channel.
/// The implementation stays in the host-side bridge file.
protocol TeleportChannelTransportFactory: Sendable {
    func makeChannelTransport(
        channel: OpaquePointer,
        outerSession: OpaquePointer?,
        mutex: any TeleportSessionMutex
    ) -> any TeleportChannelTransport
}
