// SPDX-License-Identifier: MIT
//  PinScanCensusPinsTests.swift
//
//  The #450 census pin: every migrated helper lives in
//  `VVTermTests/PinScanSupport.swift`, the cohort still routes through
//  `PinScan.`, and the counterfactual hook is centralized. See
//  `PinScanCensus.swift` for the scan and its honest defeat list.
//
//  A failure message names the file:line and the exact remedy. Allowlisted
//  exceptions are non-empty by design (`SSHProbeShellPinsTests.strippingComments`
//  is the hash/interpolation-aware scanner that must stay local).
//
//  The `maskCode*` tests below pin `PinScanCensus.maskedCode`'s string- and
//  comment-aware semantics and its fail-closed unterminated-construct report
//  (fold round 3, CR-1/CR-2/CR-3).

import Foundation
import Testing

struct PinScanCensusPinsTests {
    @Test
    func pinScanCensusIsPinned() throws {
        let root = try PinScan.repositoryRoot()
        let violations = try PinScanCensus.violations(repositoryRoot: root)
        #expect(
            violations.isEmpty,
            "the #450 pin-scan census found local copies or a stray hook use:\n\(violations.joined(separator: "\n"))"
        )
    }

    /// The mask's permanent semantic contract (fold round 3). CR-1's `/*` in a
    /// raw string, CR-2's `//` in a string, CR-3's multiline-literal tokens and
    /// the interpolation boundary are all pinned here, so the census cannot
    /// silently regress to the comment-only scanner that hid
    /// `WorkflowPrepareXcodeBuildPinsTests.swift` lines 351-479.
    @Test
    func maskCodeGoldenCorpus() {
        let blanked: [(input: String, expected: String)] = [
            ("let a = 1 // tail\nlet b = 2", "let a = 1        \nlet b = 2"),
            ("let a = 1 /* block */ let b = 2", "let a = 1             let b = 2"),
            ("/* a /* nested */ b */ let x = 1", "                       let x = 1"),
            // CR-2: a `//` inside a string does not blank the rest of the line.
            ("let s = \"//\"; func repositoryRoot()", "let s =     ; func repositoryRoot()"),
            // CR-1: a `/*` inside a raw string does not open a block comment.
            ("#\"a /* b \"#; let x = 1", "           ; let x = 1"),
            // An interpolation body is code; a nested string inside it is blanked.
            ("let s = \"\\(d[\"k\"]) // c\"\nlet y = 1", "let s =    d[   ]       \nlet y = 1"),
            // CR-3: a multiline literal's `func` / `repositoryRoot()` are blanked.
            ("let s = \"\"\"\nfunc\nrepositoryRoot()\n\"\"\"\nlet x = 1", "let s =    \n    \n                \n   \nlet x = 1"),
        ]
        for c in blanked {
            let mask = PinScanCensus.maskedCode(c.input, blankingStringContents: true)
            #expect(
                mask.text == c.expected,
                "maskedCode(\(c.input.debugDescription)) diverged: \(mask.text.debugDescription)"
            )
            #expect(mask.unresolvedOffset == nil)
        }
        // The blanking mask hides the hook needle in a key literal...
        #expect(
            !PinScanCensus.maskedCode("environment[\"VVTERM_PINS_SOURCE_ROOT\"]", blankingStringContents: true)
                .text.contains("VVTERM_PINS_SOURCE_ROOT")
        )
        // ...but the hook scan's string-preserving mode keeps it visible, so a
        // stray `environment["VVTERM_PINS_SOURCE_ROOT"]` copy still reds.
        #expect(
            PinScanCensus.maskedCode("environment[\"VVTERM_PINS_SOURCE_ROOT\"]", blankingStringContents: false)
                .text.contains("VVTERM_PINS_SOURCE_ROOT")
        )
    }

    /// Fail-closed: an unresolvable construct is reported by offset and the tail
    /// is restored verbatim, never silently blanked.
    @Test
    func maskCodeFailsClosedOnUnterminatedConstructs() {
        let block = PinScanCensus.maskedCode("let a = 1\n/* open\nlet b = 2", blankingStringContents: true)
        #expect(block.unresolvedOffset == 10)
        #expect(block.text == "let a = 1\n/* open\nlet b = 2")
        let string = PinScanCensus.maskedCode("let a = 1\nlet s = \"open", blankingStringContents: true)
        #expect(string.unresolvedOffset == 18)
        #expect(string.text == "let a = 1\nlet s = \"open")
    }

    /// Change-detector: the cohort list is a deliberate record of the migrated
    /// files, so editing it must update the recorded count and digest in the
    /// same commit. Without this, dropping a cohort entry would pass silently.
    @Test
    func pinScanCohortListIsRecorded() {
        #expect(
            PinScanCensus.expectedCohort.count == PinScanCensus.expectedCohortCount,
            "the #450 census cohort changed size (\(PinScanCensus.expectedCohort.count) != \(PinScanCensus.expectedCohortCount)); update expectedCohortCount and expectedCohortDigest deliberately"
        )
        #expect(
            PinScanCensus.cohortDigest() == PinScanCensus.expectedCohortDigest,
            "the #450 census cohort list changed (digest \(PinScanCensus.cohortDigest()) != \(PinScanCensus.expectedCohortDigest)); update expectedCohortDigest deliberately"
        )
    }
}
