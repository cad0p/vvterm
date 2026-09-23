// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportLogging+App.swift
//  VVTerm
//
//  The host adapter for the package-movable `TeleportLogging` seam.
//
//  `AppTeleportLogging` routes every Teleport logger through
//  `Logger.forCategory`, preserving the app subsystem (bundle id) and every
//  existing category string. This keeps the on-device diagnostics ring
//  buffer + `DiagnosticsExporter` filtering (`subsystem == bundleID`) intact.
//

import os.log

/// The host-side `TeleportLogging` adapter. Stateless; a single shared
/// instance is injected at every production construction path.
struct AppTeleportLogging: TeleportLogging {
    static let shared = AppTeleportLogging()

    func logger(category: String) -> Logger {
        Logger.forCategory(category)
    }
}
