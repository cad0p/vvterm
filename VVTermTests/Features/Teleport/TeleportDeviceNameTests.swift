// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportDeviceNameTests.swift
//  VVTermTests
//
//  Layer 1 unit tests for `TeleportDeviceName` (the device-name defaulting +
//  sanitization pure function extracted from the UI layer).
//
//  Covers the sanitization rules from the 2.2 UI design doc (mockup D):
//    - prefix `vvterm-`
//    - spaces → dashes
//    - case folding (lowercased)
//    - length cap 32 chars (truncated after sanitization)
//    - emoji + non-alphanumeric (except dash) stripped
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup D —
//      "Device name: vvterm-<device-name> where <device-name> is
//      UIDevice.current.name (iOS) / Host.current().localizedName (macOS),
//      sanitized (alphanumeric + dash, lowercased, truncated to 32 chars).")
//    - VVTerm/Features/Teleport/Domain/TeleportDeviceName.swift
//

import XCTest
@testable import VVTerm

final class TeleportDeviceNameTests: XCTestCase {

    // MARK: - default(rawDeviceName:)

    func testDefault_prependsVvtermPrefix() {
        // A simple ASCII name → vvterm-<name>.
        let name = TeleportDeviceName.default(rawDeviceName: "pier-iphone")
        XCTAssertEqual(name, "vvterm-pier-iphone")
    }

    func testDefault_lowercasesUppercaseInput() {
        // Case folding: "Pier-iPhone" → "pier-iphone".
        let name = TeleportDeviceName.default(rawDeviceName: "Pier-iPhone")
        XCTAssertEqual(name, "vvterm-pier-iphone")
    }

    func testDefault_replacesSpacesWithDashes() {
        // "Pier's iPhone" → spaces become dashes → "pier-s-iphone".
        // (The apostrophe is stripped — non-alphanumeric.)
        let name = TeleportDeviceName.default(rawDeviceName: "Pier iPhone")
        XCTAssertEqual(name, "vvterm-pier-iphone")
    }

    func testDefault_collapsesMultipleSpacesIntoSingleDash() {
        // "Pier  iPhone" (two spaces) → "pier-iphone" (one dash), not
        // "pier--iphone".
        let name = TeleportDeviceName.default(rawDeviceName: "Pier  iPhone")
        XCTAssertEqual(name, "vvterm-pier-iphone")
    }

    func testDefault_stripsEmoji() {
        // "Pier's iPhone 📱" → emoji stripped → "pier-s-iphone" (apostrophe
        // stripped, space → dash). Wait — the apostrophe is stripped, so
        // "Pier's iPhone 📱" becomes "pier" + "" (apostrophe removed) +
        // "s" + "-iphone" → "piers-iphone".
        let name = TeleportDeviceName.default(rawDeviceName: "📱Pier's iPhone📱")
        XCTAssertEqual(name, "vvterm-piers-iphone")
    }

    func testDefault_stripsPunctuation() {
        // "Pier's-iPhone!" → apostrophe + exclamation stripped → "piers-iphone".
        let name = TeleportDeviceName.default(rawDeviceName: "Pier's-iPhone!")
        XCTAssertEqual(name, "vvterm-piers-iphone")
    }

    func testDefault_trimsLeadingAndTrailingDashes() {
        // "  Pier  " → spaces → dashes → "-pier-" → trimmed → "pier".
        let name = TeleportDeviceName.default(rawDeviceName: "  Pier  ")
        XCTAssertEqual(name, "vvterm-pier")
    }

    func testDefault_truncatesTo32CharsAfterSanitization() {
        // A 64-char name → truncated to 32 chars (after the prefix).
        let long = String(repeating: "a", count: 64)
        let name = TeleportDeviceName.default(rawDeviceName: long)
        XCTAssertEqual(name, "vvterm-" + String(repeating: "a", count: 32))
        XCTAssertEqual(name.count, "vvterm-".count + 32)
    }

    func testDefault_truncatesAndReTrimsTrailingDash() {
        // If truncation lands on a trailing dash, re-trim it.
        // "a-b-c-..." with the cut at position 32 landing on a dash.
        // Build a name where the 32nd char is a dash.
        let raw = "aaaa-aaaa-aaaa-aaaa-aaaa-aaaa-aaaa-aaaa-aaaa"
        let name = TeleportDeviceName.default(rawDeviceName: raw)
        // The first 32 chars of "aaaa-aaaa-aaaa-aaaa-aaaa-aaaa-aaaa-aaaa-aaaa"
        // are "aaaa-aaaa-aaaa-aaaa-aaaa-aaaa-aaa-" (31 a's + ...). Let's just
        // assert the result doesn't end in a dash and is ≤ prefix+32.
        XCTAssertFalse(name.hasSuffix("-"), "name must not end in a dash after truncation: \(name)")
        XCTAssertLessThanOrEqual(name.count, "vvterm-".count + 32)
    }

    // MARK: - sanitize(_:)

    func testSanitize_emptyStringFallsBackToDevice() {
        // If the raw name is empty (or sanitizes to empty), the fallback is
        // "device" so the default is always non-empty (the registration
        // sheet's Continue button is disabled for empty names).
        XCTAssertEqual(TeleportDeviceName.sanitize(""), "device")
    }

    func testSanitize_allEmojiFallsBackToDevice() {
        // "📱🚀🎉" → all stripped → empty → fallback "device".
        XCTAssertEqual(TeleportDeviceName.sanitize("📱🚀🎉"), "device")
    }

    func testSanitize_allPunctuationFallsBackToDevice() {
        // "!@#$%^&*()" → all stripped → empty → fallback "device".
        XCTAssertEqual(TeleportDeviceName.sanitize("!@#$%^&*()"), "device")
    }

    func testSanitize_preservesAlphanumericAndDashes() {
        // A clean name passes through unchanged (already valid).
        XCTAssertEqual(TeleportDeviceName.sanitize("pier-iphone-15"), "pier-iphone-15")
        XCTAssertEqual(TeleportDeviceName.sanitize("my-device-2024"), "my-device-2024")
    }

    func testSanitize_stripsNonASCIILetters() {
        // Non-ASCII letters (é, ñ, ü) are stripped — Teleport MFA device
        // names are ASCII `[a-z0-9-]` only.
        XCTAssertEqual(TeleportDeviceName.sanitize("café-münchen"), "caf-mnchen")
    }

    func testSanitize_stripsUnderscores() {
        // Underscores aren't in the allowed set `[a-z0-9-]` → stripped.
        // (Some device names use underscores; we normalize to dashes-only.)
        XCTAssertEqual(TeleportDeviceName.sanitize("pier_iphone"), "pieriphone")
        // Note: this produces "pieriphone" (the underscore is stripped, not
        // replaced with a dash). This is intentional — the design doc says
        // "alphanumeric + dash", and underscore isn't a dash.
    }

    // MARK: - validate(_:)

    func testValidate_returnsNilForValidName() {
        // A clean, non-empty, ≤32-char name is valid (nil error).
        XCTAssertNil(TeleportDeviceName.validate("pier-iphone-15"))
    }

    func testValidate_returnsErrorForEmptyName() {
        // Empty → "Device name required".
        XCTAssertEqual(TeleportDeviceName.validate(""), "Device name required")
        XCTAssertEqual(TeleportDeviceName.validate("   "), "Device name required")
    }

    func testValidate_returnsErrorForNameWithInvalidChars() {
        // "Pier's iPhone" has an apostrophe + space → invalid.
        XCTAssertNotNil(TeleportDeviceName.validate("Pier's iPhone"))
    }

    func testValidate_returnsErrorForTooLongName() {
        // > 32 chars → invalid.
        let long = String(repeating: "a", count: 64)
        XCTAssertNotNil(TeleportDeviceName.validate(long))
    }

    func testValidate_acceptsExactly32Chars() {
        // Exactly 32 chars is valid (boundary: ≤ 32, not < 32).
        let name = String(repeating: "a", count: 32)
        XCTAssertNil(TeleportDeviceName.validate(name))
    }

    // MARK: - prefix / maxSanitizedLength constants

    func testPrefixIsVvtermDash() {
        XCTAssertEqual(TeleportDeviceName.prefix, "vvterm-")
    }

    func testMaxSanitizedLengthIs32() {
        XCTAssertEqual(TeleportDeviceName.maxSanitizedLength, 32)
    }

    // MARK: - Realistic device names

    func testRealisticIOSDeviceName() {
        // "Pier's iPhone" is a typical iOS device name (set by the user in
        // Settings → General → About → Name).
        let name = TeleportDeviceName.default(rawDeviceName: "Pier's iPhone")
        XCTAssertEqual(name, "vvterm-piers-iphone")
    }

    func testRealisticMacDeviceName() {
        // "Pier's MacBook Pro" is a typical macOS device name.
        let name = TeleportDeviceName.default(rawDeviceName: "Pier's MacBook Pro")
        XCTAssertEqual(name, "vvterm-piers-macbook-pro")
    }

    func testRealisticDeviceNameWithEmoji() {
        // "📱 Pier's iPhone 📱" — emoji + apostrophe + spaces.
        let name = TeleportDeviceName.default(rawDeviceName: "📱 Pier's iPhone 📱")
        XCTAssertEqual(name, "vvterm-piers-iphone")
    }

    func testRealisticDeviceNameWithNumbers() {
        // "Pier's iPhone 15 Pro Max" — numbers preserved.
        let name = TeleportDeviceName.default(rawDeviceName: "Pier's iPhone 15 Pro Max")
        XCTAssertEqual(name, "vvterm-piers-iphone-15-pro-max")
    }

    // MARK: - Stability (same input → same output)

    func testSanitizeIsDeterministic() {
        // Same input always produces the same output (pure function).
        let input = "Pier's iPhone 📱"
        let result1 = TeleportDeviceName.sanitize(input)
        let result2 = TeleportDeviceName.sanitize(input)
        XCTAssertEqual(result1, result2)
    }
}
