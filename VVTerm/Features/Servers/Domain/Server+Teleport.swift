// SPDX-License-Identifier: MIT
//
//  Server+Teleport.swift
//  VVTerm
//
//  The `Server`-side Teleport adapters that live outside the server model:
//  the `TeleportCredentialReuseRow` conformance consumed by the shared
//  `TeleportCredentialReuse.match(newRow:liveRows:…)` matcher.
//
//  `Server.normalizedTeleportHostLogin` itself stays on `Server` (it is part
//  of the persisted shape and the decode seam) and delegates to the package's
//  `TeleportHostLogin.normalized(_:)`; the host keeps its own 255-byte
//  constant because the package's `maxTeleportHostLoginBytes` is
//  `package`-visibility.
//

import Foundation
import TeleportCore

extension Server: TeleportCredentialReuseRow {
    /// The row's display name (used only for the deterministic name ordering
    /// of reuse candidates).
    var displayName: String { name }

    /// Whether the row authenticates with a Teleport Face ID credential.
    var isFaceIDTeleport: Bool { authMethod == .faceIDTeleport }
}
