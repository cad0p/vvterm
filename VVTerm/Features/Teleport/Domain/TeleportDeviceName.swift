// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportDeviceName.swift
//  VVTerm
//
//  Pure functions for the MFA device-name defaulting + sanitization used by
//  the Teleport registration flow (Phase 2 — see mockup D in the UI design
//  doc).
//
//  Extracted from the UI layer into the Domain so the sanitization rules
//  are unit-testable without presenting the registration sheet. The UI
//  call site (`TeleportRegistrationView`) calls `TeleportDeviceName.default(
//  rawDeviceName:)` with `UIDevice.current.name` (iOS) /
//  `Host.current().localizedName` (macOS); the rules below produce the
//  `vvterm-<sanitized>` default per the design doc.
//
//  Sanitization rules (per the 2.2 UI design doc):
//    - prefix `vvterm-`
//    - spaces → dashes
//    - case folding (lowercased)
//    - length cap 32 chars (truncated after sanitization, not before)
//    - emoji + non-alphanumeric (except dash) stripped
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup D —
//      device-name defaulting + sanitization rules)
//    - 2026-07-21-strategy-b-session2.2-vvterm-sep-key-integration-prompt.md
//

import Foundation

/// Pure functions for the MFA device-name defaulting + sanitization.
///
/// Extracted from `TeleportRegistrationView` (the UI layer) so the rules are
/// unit-testable without presenting the sheet. The UI call site passes the
/// raw device name (`UIDevice.current.name` / `Host.current().localizedName`);
/// these functions produce the `vvterm-<sanitized>` default.
enum TeleportDeviceName {
    /// The prefix applied to every default device name.
    static let prefix = "vvterm-"

    /// The maximum length of the sanitized name (excluding the prefix),
    /// per the design doc.
    static let maxSanitizedLength = 32

    /// Compute the default MFA device name from a raw device name.
    ///
    /// The raw name is `UIDevice.current.name` (iOS) or
    /// `Host.current().localizedName` (macOS) — both of which may contain
    /// spaces, uppercase, emoji, and other characters Teleport's MFA device
    /// naming doesn't accept cleanly. This produces a stable, sanitized
    /// `vvterm-<sanitized>` default.
    ///
    /// The user can still edit the name in the registration sheet — this is
    /// only the default.
    ///
    /// - Parameter rawDeviceName: the raw OS device name.
    /// - Returns: the sanitized `vvterm-<sanitized>` default.
    static func `default`(rawDeviceName: String) -> String {
        prefix + sanitize(rawDeviceName)
    }

    /// Sanitize a raw device name for use as the MFA device-name suffix.
    ///
    /// Rules (per the 2.2 UI design doc):
    ///   1. Lowercase the entire string (case folding).
    ///   2. Replace spaces with dashes.
    ///   3. Strip every character that isn't ASCII alphanumeric or a dash
    ///      (this strips emoji, punctuation, and non-ASCII letters — Teleport
    ///      MFA device names are `[a-z0-9-]`).
    ///   4. Collapse runs of consecutive dashes into a single dash.
    ///   5. Trim leading/trailing dashes.
    ///   6. Truncate to `maxSanitizedLength` (32) chars.
    ///
    /// If the result is empty after sanitization (e.g. the raw name was all
    /// emoji), returns `"device"` so the default is always non-empty (the
    /// registration sheet's Continue button is disabled for empty names —
    /// a fallback here keeps the default usable).
    static func sanitize(_ raw: String) -> String {
        // 1. Lowercase.
        var s = raw.lowercased()

        // 2. Replace spaces with dashes (do this before stripping so " " → "-"
        // rather than being stripped entirely).
        s = s.replacingOccurrences(of: " ", with: "-")

        // 3. Strip non-`[a-z0-9-]` characters. This also strips emoji (which
        //    are multi-scalar sequences) and non-ASCII letters.
        s = String(s.unicodeScalars.filter { scalar in
            scalar.value >= 0x30 && scalar.value <= 0x39   // 0-9
                || scalar.value >= 0x61 && scalar.value <= 0x7A   // a-z
                || scalar.value == 0x2D   // -
        })

        // 4. Collapse runs of consecutive dashes into a single dash.
        //    (Regex isn't available on all deployment targets without
        //    Foundation's NSRegularExpression; a simple character scan is
        //    deterministic and allocation-light.)
        var collapsed = ""
        var lastWasDash = false
        for ch in s {
            if ch == "-" {
                if !lastWasDash {
                    collapsed.append(ch)
                }
                lastWasDash = true
            } else {
                collapsed.append(ch)
                lastWasDash = false
            }
        }
        s = collapsed

        // 5. Trim leading/trailing dashes.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // 6. Truncate to maxSanitizedLength.
        if s.count > maxSanitizedLength {
            s = String(s.prefix(maxSanitizedLength))
            // Re-trim a trailing dash introduced by truncation.
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        // Fallback if the result is empty (e.g. raw name was all emoji).
        if s.isEmpty {
            s = "device"
        }

        return s
    }

    /// Validate a user-edited device name (not the default). Returns nil if
    /// valid, or an error message if invalid.
    ///
    /// A valid user-entered name:
    ///   - is non-empty
    ///   - contains only `[a-z0-9-]` (after the user types, we sanitize live)
    ///   - is ≤ `maxSanitizedLength` chars (excluding the `vvterm-` prefix
    ///     if present)
    ///
    /// Used by the registration sheet for inline validation.
    static func validate(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "Device name required"
        }
        let sanitized = sanitize(name)
        if sanitized != name {
            return "Device name can only contain lowercase letters, numbers, and dashes"
        }
        if sanitized.count > maxSanitizedLength {
            return "Device name must be \(maxSanitizedLength) characters or fewer"
        }
        return nil
    }
}
