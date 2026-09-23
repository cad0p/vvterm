// SPDX-License-Identifier: MIT
//
//  TeleportLogging.swift
//  VVTerm
//
//  The package-movable logging seam for the Teleport feature.
//
//  Static loggers (`Logger.forCategory`) cannot be init-injected, so the
//  package-movable code requests its loggers through this seam instead. The
//  host supplies an adapter that preserves the app's logging subsystem
//  (bundle id) and the existing category strings, so diagnostics exports
//  (`DiagnosticsExporter` filters by `subsystem == bundleID`) keep working
//  unchanged.
//
//  Tests can inject a spy implementation to assert the exact category
//  strings requested by each host construction path.
//

import os.log

/// A seam over `os.Logger` creation.
///
/// `Sendable` so it can be stored on actors + detached tasks. The returned
/// `Logger` is `Sendable` and cheap to copy.
protocol TeleportLogging: Sendable {
    /// A logger for the given category. Category strings must stay stable:
    /// they are the diagnostic surface users/agents read.
    func logger(category: String) -> Logger
}

/// The package-owned default logger.
///
/// Used by tests and any non-app host. The app never relies on this default
/// at a host-reachable entry point: every production construction path
/// injects `AppTeleportLogging` (the host adapter that preserves the app
/// subsystem).
struct DefaultTeleportLogging: TeleportLogging {
    /// The `os.Logger` subsystem. The app adapter ignores this and uses the
    /// app bundle id instead.
    let subsystem: String

    init(subsystem: String = "Teleport") {
        self.subsystem = subsystem
    }

    func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
