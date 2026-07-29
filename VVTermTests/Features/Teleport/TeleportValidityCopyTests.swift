// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportValidityCopyTests.swift
//  VVTermTests
//
//  Unit tests for the relative-time formatting used in the Teleport login
//  sheet's "Certificate valid for …" success copy.
//
//  `TeleportValidityCopy.relativeValidityString(for:relativeTo:)` rounds the
//  remaining cert TTL to the nearest minute before handing it to
//  `RelativeDateTimeFormatter`. This prevents an off-by-one where a cert
//  issued with an exact 12h TTL would render as "in 11 hours" because a few
//  seconds of render drift pushed the remaining interval to 11h 59m 59s
//  (which the formatter floors to "11 hours").
//
//  See:
//    - VVTerm/Features/Teleport/UI/TeleportLoginView.swift (certificateValidityText)
//    - VVTermUITests/Features/Teleport/TeleportUITests.swift (the UI tests
//      that first surfaced this bug: testLogin_happyPath12h / _1h)
//

import XCTest
@testable import VVTerm

final class TeleportValidityCopyTests: XCTestCase {

    // MARK: - Whole-hour TTLs render without off-by-one

    /// A 12h TTL with a few seconds of render drift must still say "12 hours",
    /// not "11 hours" (the original bug).
    func testRelativeValidityString_12hTTLWithDrift_says12Hours() {
        let now = Date()
        // Cert issued 2 seconds ago with a 12h TTL → 11h 59m 58s remaining.
        let certValidUntil = now.addingTimeInterval(12 * 3600 - 2)

        let string = TeleportValidityCopy.relativeValidityString(
            for: certValidUntil,
            relativeTo: now
        )

        XCTAssertTrue(
            string.contains("12 hours") || string.contains("12 Hour"),
            "12h TTL with 2s drift should say '12 hours', got: \(string)"
        )
    }

    /// A 1h TTL with a few seconds of render drift must still say "1 hour",
    /// not "59 minutes" (the original bug).
    func testRelativeValidityString_1hTTLWithDrift_says1Hour() {
        let now = Date()
        // Cert issued 2 seconds ago with a 1h TTL → 59m 58s remaining.
        let certValidUntil = now.addingTimeInterval(3600 - 2)

        let string = TeleportValidityCopy.relativeValidityString(
            for: certValidUntil,
            relativeTo: now
        )

        XCTAssertTrue(
            string.contains("1 hour") || string.contains("one hour"),
            "1h TTL with 2s drift should say '1 hour', got: \(string)"
        )
    }

    /// A 4h TTL with a few seconds of drift must still say "4 hours"
    /// (covers the certExpiredOnTap scenario).
    func testRelativeValidityString_4hTTLWithDrift_says4Hours() {
        let now = Date()
        let certValidUntil = now.addingTimeInterval(4 * 3600 - 2)

        let string = TeleportValidityCopy.relativeValidityString(
            for: certValidUntil,
            relativeTo: now
        )

        XCTAssertTrue(
            string.contains("4 hours") || string.contains("4 Hour"),
            "4h TTL with 2s drift should say '4 hours', got: \(string)"
        )
    }

    // MARK: - Exact TTLs (no drift) still render correctly

    func testRelativeValidityString_exact12h_says12Hours() {
        let now = Date()
        let certValidUntil = now.addingTimeInterval(12 * 3600)

        let string = TeleportValidityCopy.relativeValidityString(
            for: certValidUntil,
            relativeTo: now
        )

        XCTAssertTrue(
            string.contains("12 hours") || string.contains("12 Hour"),
            "exact 12h TTL should say '12 hours', got: \(string)"
        )
    }

    func testRelativeValidityString_exact1h_says1Hour() {
        let now = Date()
        let certValidUntil = now.addingTimeInterval(3600)

        let string = TeleportValidityCopy.relativeValidityString(
            for: certValidUntil,
            relativeTo: now
        )

        XCTAssertTrue(
            string.contains("1 hour") || string.contains("one hour"),
            "exact 1h TTL should say '1 hour', got: \(string)"
        )
    }

    // MARK: - Genuine elapsed time still rounds down

    /// If 2 minutes have genuinely elapsed on a 1h TTL (58m remaining), the
    /// copy should say "58 minutes", not round up to "1 hour". This guards
    /// against over-rounding.
    func testRelativeValidityString_1hTTLWith2MinElapsed_says58Minutes() {
        let now = Date()
        let certValidUntil = now.addingTimeInterval(3600 - 120)

        let string = TeleportValidityCopy.relativeValidityString(
            for: certValidUntil,
            relativeTo: now
        )

        XCTAssertTrue(
            string.contains("58 minutes") || string.contains("58 minute"),
            "1h TTL with 2min elapsed should say '58 minutes', got: \(string)"
        )
    }

    // MARK: - Full copy string (regression: "valid for in" duplication)

    /// Regression guard: the full success copy must NOT contain "for in"
    /// (the bug where "Certificate valid for % @" + relativeString="in 12 hours"
    /// produced "valid for in 12 hours").
    func testCertificateValidityCopy_12hTTL_doesNotContainForIn() {
        let now = Date()
        let certValidUntil = now.addingTimeInterval(12 * 3600 - 2)

        let copy = TeleportValidityCopy.certificateValidityText(
            certValidUntil: certValidUntil,
            relativeTo: now
        )

        XCTAssertFalse(
            copy.contains("for in"),
            "copy must not contain the duplicated 'for in': \(copy)"
        )
        XCTAssertTrue(
            copy.hasPrefix("Certificate valid in"),
            "copy should start with 'Certificate valid in': \(copy)"
        )
        XCTAssertTrue(
            copy.contains("12 hours"),
            "copy should mention 12 hours: \(copy)"
        )
    }

    func testCertificateValidityCopy_1hTTL_doesNotContainForIn() {
        let now = Date()
        let certValidUntil = now.addingTimeInterval(3600 - 2)

        let copy = TeleportValidityCopy.certificateValidityText(
            certValidUntil: certValidUntil,
            relativeTo: now
        )

        XCTAssertFalse(
            copy.contains("for in"),
            "copy must not contain the duplicated 'for in': \(copy)"
        )
        XCTAssertTrue(
            copy.hasPrefix("Certificate valid in"),
            "copy should start with 'Certificate valid in': \(copy)"
        )
    }

    /// A sub-minute TTL (e.g. 45 seconds) rounds up to 1 minute, not 0 minutes.
    /// (45s = 0.75 min, which rounds to 1 under any rounding rule.)
    func testRelativeValidityString_45Seconds_says1Minute() {
        let now = Date()
        let certValidUntil = now.addingTimeInterval(45)

        let string = TeleportValidityCopy.relativeValidityString(
            for: certValidUntil,
            relativeTo: now
        )

        XCTAssertTrue(
            string.contains("1 minute") || string.contains("1 min"),
            "45s TTL should round up to '1 minute', got: \(string)"
        )
    }
}
