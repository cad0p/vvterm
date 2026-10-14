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
//  (fold round 3, CR-1/CR-2/CR-3; fold round 4, F1/F2/F4: CRLF newlines,
//  comments inside interpolation bodies, raw-string interpolation and
//  multi-hash closing).

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

    /// The mask's permanent semantic contract (fold rounds 3-4). CR-1's `/*` in
    /// a raw string, CR-2's `//` in a string, CR-3's multiline-literal tokens,
    /// the interpolation boundary, CRLF line endings (F1), comments inside an
    /// interpolation body (F2/F4) and the raw-string `\#(`/multi-hash closing
    /// semantics (F3) are all pinned here, so the census cannot silently
    /// regress to the comment-only scanner that hid
    /// `WorkflowPrepareXcodeBuildPinsTests.swift` lines 351-479.
    ///
    /// A `(name, input, expectedMask)` case is resolved: the mask must equal
    /// `expectedMask` with no unresolved offset. The fail-closed table below
    /// carries the constructs that must instead report their opening offset and
    /// restore the tail verbatim (an unterminated raw string, a backslash at
    /// EOF and unterminated interpolation comments among them), so a disabled
    /// fail-closed signal turns this test red too.
    @Test
    func maskCodeGoldenCorpus() {
        let resolved: [(name: String, input: String, expected: String)] = [
            ("line-comment-lf", "let a = 1 // tail\nlet b = 2", "let a = 1        \nlet b = 2"),
            ("line-comment-crlf", "let a = 1 // tail\r\nlet b = 2", "let a = 1        \r\nlet b = 2"),
            ("block-comment-lf", "let a = 1 /* block */ let b = 2", "let a = 1             let b = 2"),
            ("block-comment-crlf", "let a = 1 /* block */\r\nlet b = 2", "let a = 1            \r\nlet b = 2"),
            ("nested-block", "/* a /* nested */ b */ let x = 1", "                       let x = 1"),
            // CR-2: a `//` inside a string does not blank the rest of the line.
            ("slashslash-in-string", "let s = \"//\"; func repositoryRoot()", "let s =     ; func repositoryRoot()"),
            // CR-1: a `/*` inside a raw string does not open a block comment.
            ("blockopen-in-raw-string", "#\"a /* b \"#; let x = 1", "           ; let x = 1"),
            // An interpolation body is code; a nested string inside it is blanked.
            ("interp-nested-string", "let s = \"\\(d[\"k\"]) // c\"\nlet y = 1", "let s =    d[   ]       \nlet y = 1"),
            // CR-3: a multiline literal's `func` / `repositoryRoot()` are blanked.
            ("multiline-literal-lf", "let s = \"\"\"\nfunc\nrepositoryRoot()\n\"\"\"\nlet x = 1", "let s =    \n    \n                \n   \nlet x = 1"),
            // F1: a CRLF file keeps its newline graphemes in the mask.
            ("multiline-literal-crlf", "let s = \"\"\"\r\nfunc\r\nrepositoryRoot()\r\n\"\"\"\r\nlet x = 1", "let s =    \r\n    \r\n                \r\n   \r\nlet x = 1"),
            // `*/` before any `/*` is plain code; only the real block blanks.
            ("stray-close-before-open", "*/ let a = 1 /* c */ let b = 2", "*/ let a = 1         let b = 2"),
            ("stray-close-in-string", "let a = \"*/\"; /* c */ let b = 2", "let a =     ;         let b = 2"),
            // An escaped quote does not close the literal.
            ("escaped-quote", "let s = \"a \\\" b\"; let x = 1", "let s =         ; let x = 1"),
            // F3/G2: a raw string's `\#( … )` body is code and stays visible.
            ("raw-interp-hash1", "#\"a \\#(x) b\"#", "       x     "),
            ("raw-interp-hash2", "##\"a \\##(x) b\"##", "         x      "),
            // F3/G3: `##"…"##` may contain a `"#` sequence and closes on `"##`.
            ("raw-hash2-closing", "##\"a \"# b\"##", "            "),
            // F3: `#"""…"""#` is a raw multiline string.
            ("raw-multiline", "let s = #\"\"\"\nfunc\nrepositoryRoot()\n\"\"\"#\nlet x = 1", "let s =     \n    \n                \n    \nlet x = 1"),
            // F2/F4: comments inside an interpolation body are skipped by the
            // close scan, so a `(`/`)` in the comment is not a bracket.
            ("interp-block-comment-open-paren", "let s = \"\\(a /* ( */ + b)\"\nfunc repositoryRoot()", "let s =    a         + b  \nfunc repositoryRoot()"),
            ("interp-block-comment-close-paren", "let s = \"\\(x /* ) */ + 2)\"", "let s =    x         + 2  "),
            ("interp-line-comment-paren", "let s = \"\\(a // )\n + b)\"\nlet y = 1", "let s =    a     \n + b  \nlet y = 1"),
            ("interp-nested-block-comment", "let s = \"\\(a /* ( /* ) */ */ + b)\"\nlet y = 1", "let s =    a                 + b  \nlet y = 1"),
        ]
        for c in resolved {
            let mask = PinScanCensus.maskedCode(c.input, blankingStringContents: true)
            #expect(
                mask.text == c.expected,
                "maskedCode(\(c.name)) diverged: \(mask.text.debugDescription)"
            )
            #expect(
                mask.unresolvedOffset == nil,
                "maskedCode(\(c.name)) unexpectedly unresolved at offset \(mask.unresolvedOffset.map(String.init) ?? "nil")"
            )
        }

        // Fail-closed constructs: the mask restores the tail verbatim and
        // reports the opening character offset instead of blanking silently.
        let unresolved: [(name: String, input: String, expected: String, offset: Int)] = [
            ("unterminated-block", "let a = 1\n/* open\nlet b = 2", "let a = 1\n/* open\nlet b = 2", 10),
            ("unterminated-string", "let a = 1\nlet s = \"open", "let a = 1\nlet s = \"open", 18),
            // F3: an unterminated raw string and a backslash at EOF both fail closed.
            ("unterminated-raw-string", "let a = 1\nlet s = #\"open", "let a = 1\nlet s = #\"open", 18),
            ("backslash-at-eof", "let s = \"a\\", "let s = \"a\\", 8),
            // The string before a stray `*/` is blanked, then `/* open` is the opener.
            ("stray-close-then-open-unclosed", "let a = \"*/\"; /* open\nlet b = 2", "let a =     ; /* open\nlet b = 2", 14),
            // F2: an unterminated comment inside an interpolation cannot resolve.
            ("interp-block-comment-unterminated", "let s = \"\\(1 /* open", "let s = \"\\(1 /* open", 8),
            ("interp-line-comment-unterminated", "let s = \"\\(1 // open", "let s = \"\\(1 // open", 8),
        ]
        for c in unresolved {
            let mask = PinScanCensus.maskedCode(c.input, blankingStringContents: true)
            #expect(
                mask.text == c.expected,
                "maskedCode(\(c.name)) tail diverged: \(mask.text.debugDescription)"
            )
            #expect(
                mask.unresolvedOffset == c.offset,
                "maskedCode(\(c.name)) unresolved offset \(mask.unresolvedOffset.map(String.init) ?? "nil") != \(c.offset)"
            )
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
    /// is restored verbatim, never silently blanked. The golden corpus pins the
    /// wider fail-closed set (raw string, backslash at EOF, interpolation
    /// comments); these two stay as the canonical CR-1-era pair.
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
