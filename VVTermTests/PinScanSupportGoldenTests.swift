// SPDX-License-Identifier: MIT
//  PinScanSupportGoldenTests.swift
//
//  The committed golden corpus for the shared pin-scan lexers (issues #450,
//  #453). This is the permanent contract for `PinScan.strippingComments`,
//  `PinScan.strippingCommentsKeepingLiterals`,
//  `PinScan.strippingCommentsAndStrings`,
//  `PinScan.strippingCommentsAndStringsPreservingUTF16`,
//  `PinScan.strippingYAMLComments`, `PinScan.normalizedWhitespace` and
//  `PinScan.isInside`, now that the per-suite copies are gone. A deliberate
//  lexer change updates this file in the same commit.
//
//  The #453 rows for the three migrated scanners pin their measured fail-open
//  limits as documented defeats (R1 under-strip, R2 shrink, R3 nested-quote
//  leak, R1/R2 CRLF swallow) with the fix tracked in issue #455; a fix must
//  update these rows in the same commit.

import Foundation
import Testing

struct PinScanSupportGoldenTests {

    @Test
    func strippingCommentsGoldenCorpus() {
        let cases: [(input: String, expected: String)] = [
            // `//` line comments blank to spaces; the newline is preserved.
            ("let a = 1 // tail\nlet b = 2", "let a = 1        \nlet b = 2"),
            // A block comment blanks to spaces, preserving the surrounding code.
            ("let a = 1 /* block */ let b = 2", "let a = 1             let b = 2"),
            // Nested block comments are tracked by depth.
            ("/* a /* nested */ b */ let x = 1", "                       let x = 1"),
            // A `//` inside a string literal is not a comment.
            ("let s = \"a // b\"", "let s = \"a // b\""),
            // A `/*` inside a string literal is not a comment.
            ("let s = \"/*\"", "let s = \"/*\""),
            // An escaped quote does not close the string.
            ("let s = \"a\\\"b\" // c", "let s = \"a\\\"b\"     "),
            // An unterminated block comment blanks to end-of-input.
            ("let a = 1 /* open", "let a = 1        "),
            // Raw-string limitation: `#"…"#` is read as a plain string, so a
            // trailing comment after it is still blanked, but the raw-string
            // body is copied verbatim.
            ("let s = #\"a // b\"# // real", "let s = #\"a // b\"#        "),
            // Interpolation and hashes are copied verbatim (the canonical
            // scanner does not descend into `\( … )`).
            ("let s = \"\\(x) // c\"", "let s = \"\\(x) // c\""),
            ("let s = #\"\\#(x) // c\"#", "let s = #\"\\#(x) // c\"#"),
            // Divergent raw-string cases (issue #450 fold F2): the canonical
            // scanner desynchronizes after a raw string with an embedded
            // quote, so the trailing `//` is kept as code. The shared
            // hash-aware wrapper (`strippingCommentsKeepingLiterals`) blanks
            // the comment instead, so these cases fail if the wrapper is ever
            // substituted for the canonical lexer.
            ("#\"a \"b\"# // tail", "#\"a \"b\"# // tail"),
            ("##\"a#\"#b\"## // tail", "##\"a#\"#b\"## // tail"),
            // Triple-quoted raw string with a `//` inside: the literal is
            // copied verbatim and a `//` inside it is not a comment.
            ("let s = #\"\"\"a // b\"\"\"#", "let s = #\"\"\"a // b\"\"\"#"),
            // A trailing comment after a triple-quoted raw string still blanks.
            ("let s = #\"\"\"a \"b\" // c\"\"\"# // tail", "let s = #\"\"\"a \"b\" // c\"\"\"#        "),
        ]
        for c in cases {
            #expect(
                PinScan.strippingComments(c.input) == c.expected,
                "strippingComments(\(c.input.debugDescription)) diverged from the golden output"
            )
        }
    }

    @Test
    func strippingYAMLCommentsGoldenCorpus() {
        let cases: [(input: String, expected: String)] = [
            // A `#` at line start or after whitespace starts a YAML comment.
            ("# top\nkey: value # comment", "     \nkey: value          "),
            ("key: 'a # b'", "key: 'a # b'"),
            ("key: \"a # b\"", "key: \"a # b\""),
            // YAML `''` escapes stay inside the single-quoted scalar.
            ("key: 'it''s # not a comment'", "key: 'it''s # not a comment'"),
            // A `\"` escape inside a double-quoted scalar does not close it.
            ("key: \"a\\\"#\"", "key: \"a\\\"#\""),
            ("key: value\n# comment", "key: value\n         "),
            // A `#` inside a scalar is not a comment.
            ("run: |\n  echo '#hash'", "run: |\n  echo '#hash'"),
        ]
        for c in cases {
            #expect(
                PinScan.strippingYAMLComments(c.input) == c.expected,
                "strippingYAMLComments(\(c.input.debugDescription)) diverged from the golden output"
            )
        }
    }

    @Test
    func normalizedWhitespaceGoldenCorpus() {
        let cases: [(input: String, expected: String)] = [
            ("  a \n b\tc ", "a b c"),
            ("", ""),
            ("   ", ""),
            ("a", "a"),
        ]
        for c in cases {
            #expect(PinScan.normalizedWhitespace(c.input[...]) == c.expected)
        }
    }

    @Test
    func isInsideGoldenCorpus() {
        let text = "abcdef"
        let lower = text.index(after: text.startIndex)
        let upper = text.index(text.startIndex, offsetBy: 4)
        let block = lower..<upper
        #expect(!PinScan.isInside(block, text.startIndex))
        #expect(!PinScan.isInside(block, lower))
        #expect(PinScan.isInside(block, text.index(text.startIndex, offsetBy: 2)))
        #expect(!PinScan.isInside(block, upper))
        #expect(!PinScan.isInside(block, text.endIndex))
    }

    /// R1 (`PinScan.strippingCommentsKeepingLiterals`, the login-token scan's
    /// view): comments blank, string-literal contents — raw strings and
    /// interpolations included — verbatim. The `under-strip-interp-comment`
    /// row pins the measured fail-open desync (the tail is copied verbatim, so
    /// the trailing `//` stays as code), and the two CRLF/lone-CR rows pin the
    /// swallowed terminator; both are documented defeats tracked by issue #455
    /// and were preserved verbatim by the #453 migration.
    @Test
    func strippingCommentsKeepingLiteralsGoldenCorpus() {
        let cases: [(name: String, input: String, expected: String)] = [
            ("line-comment-lf", "let a = 1 // tail\nlet b = 2", "let a = 1        \nlet b = 2"),
            ("string-decoy", "let s = \"a // b\"\nlet x = 1", "let s = \"a // b\"\nlet x = 1"),
            ("raw-string-embedded-quote", "#\"a \"b\"# // tail", "#\"a \"b\"#        "),
            ("raw-string-hash2", "##\"a#\"#b\"## // tail", "##\"a#\"#b\"##        "),
            ("interpolation-verbatim", "let s = \"\\(x) // c\"", "let s = \"\\(x) // c\""),
            ("raw-interpolation-verbatim", "let s = #\"\\#(x) // c\"#", "let s = #\"\\#(x) // c\"#"),
            // Defeat (#455): the comment-blind interpolation close desynchronizes;
            // the tail (including `// tail`) is copied verbatim.
            ("under-strip-interp-comment", "let s = \"\\(a /* ( */ + b)\" // tail\nlet y = 1", "let s = \"\\(a /* ( */ + b)\" // tail\nlet y = 1"),
            ("unterminated-string", "let s = \"open", "let s = \"open"),
            // Defeat (#455): a CRLF (or lone CR) is one Character (!= "\n"), so
            // the `//` arm blanks the terminator and the next line too.
            ("crlf-in-comment", "let a = 1 // tail\r\nlet b = 2", "let a = 1                  "),
            ("lone-cr-in-comment", "let a = 1 // tail\rlet b = 2", "let a = 1                  "),
            ("multiline-literal", "let s = \"\"\"\nfunc\n\"\"\" // tail\nlet x = 1", "let s = \"\"\"\nfunc\n\"\"\"        \nlet x = 1"),
            ("hash-not-quote", "let x = 1 # 2 // c", "let x = 1 # 2     "),
        ]
        for c in cases {
            let output = PinScan.strippingCommentsKeepingLiterals(c.input)
            #expect(
                output == c.expected,
                "strippingCommentsKeepingLiterals(\(c.name)) diverged: \(output.debugDescription)"
            )
        }
    }

    /// R2 (`PinScan.strippingCommentsAndStrings`, the SSH call-form scans):
    /// comments blank, string interiors blanked, interpolation bodies are code.
    /// The `shrink-interp-comment` row pins the measured shrink (the same
    /// desync drops the tail and its newlines), the `crlf-in-comment` row the
    /// swallowed terminator; both are documented defeats tracked by issue #455.
    @Test
    func strippingCommentsAndStringsGoldenCorpus() {
        let cases: [(name: String, input: String, expected: String)] = [
            ("line-comment-lf", "let a = 1 // tail\nlet b = 2", "let a = 1        \nlet b = 2"),
            ("string-decoy", "let s = \"a // b\"\nlet x = 1", "let s = \"      \"\nlet x = 1"),
            ("interpolation-as-code", "let s = \"\\(x) // c\"", "let s = \"\\(x)     \""),
            ("comment-in-interpolation", "let s = \"\\(a /* x */ + b)\"", "let s = \"\\(a         + b)\""),
            // Defeat (#455): the desync drops the tail with its newline — the
            // 48-Character input yields a 12-Character output.
            ("shrink-interp-comment", "let s = \"\\(a /* ( */ + b)\"\nfunc repositoryRoot()", "let s = \"\\()"),
            ("raw-interpolation-as-code", "let s = #\"\\#(x) // c\"#", "let s = #\"\\#(x)     \"#"),
            ("unterminated-string", "let s = \"open", "let s = \"    "),
            // Defeat (#455): CRLF swallowed like R1.
            ("crlf-in-comment", "let a = 1 // tail\r\nlet b = 2", "let a = 1                  "),
            ("non-ascii", "let s = \"é😀\" // c\nlet x = 1", "let s = \"  \"     \nlet x = 1"),
        ]
        for c in cases {
            let output = PinScan.strippingCommentsAndStrings(c.input)
            #expect(
                output == c.expected,
                "strippingCommentsAndStrings(\(c.name)) diverged: \(output.debugDescription)"
            )
        }
    }

    /// R3 (`PinScan.strippingCommentsAndStringsPreservingUTF16`, the shard
    /// declared-test walk): comments and string interiors blank, UTF-16 units
    /// preserved (the walk's consumers index the result with `NSRange`). The
    /// `nested-quote-leak` row pins the measured desync (the inner `"` exits
    /// the literal early and the token `k` leaks into code) — a documented
    /// defeat tracked by issue #455 — and the `non-bmp` row makes the UTF-16
    /// length assertion non-vacuous (19 Characters / 20 UTF-16 units in,
    /// 20/20 out).
    @Test
    func strippingCommentsAndStringsPreservingUTF16GoldenCorpus() {
        let cases: [(name: String, input: String, expected: String)] = [
            ("line-comment-lf", "let a = 1 // tail\nlet b = 2", "let a = 1        \nlet b = 2"),
            ("interpolation-as-content", "let s = \"\\(x) // c\"\nlet y = 1", "let s =            \nlet y = 1"),
            // Defeat (#455): the nested `"` exits the literal early, so `k`
            // leaks into code; the UTF-16 length still matches.
            ("nested-quote-leak", "let s = \"\\(d[\"k\"]) // c\"\nlet y = 1", "let s =       k         \nlet y = 1"),
            ("hash-prefix-close", "##\"a \"## b\"## // tail", "         b           "),
            ("multiline-literal", "let s = \"\"\"\nfunc\n\"\"\" // tail\nlet x = 1", "let s =    \n    \n           \nlet x = 1"),
            // The LF unit is kept and the CR blanked (UTF-16 unit fidelity).
            ("crlf-in-comment", "let a = 1 // tail\r\nlet b = 2", "let a = 1         \nlet b = 2"),
            ("unterminated-string", "let s = \"open", "let s =      "),
            ("non-bmp", "let s = \"😀\" // tail", "let s =             "),
        ]
        for c in cases {
            let output = PinScan.strippingCommentsAndStringsPreservingUTF16(c.input)
            #expect(
                output == c.expected,
                "strippingCommentsAndStringsPreservingUTF16(\(c.name)) diverged: \(output.debugDescription)"
            )
            #expect(
                output.utf16.count == c.input.utf16.count,
                "strippingCommentsAndStringsPreservingUTF16(\(c.name)) UTF-16 length \(output.utf16.count) != \(c.input.utf16.count)"
            )
        }
        // The non-BMP row is the non-vacuity case for the length property.
        #expect("let s = \"😀\" // tail".utf16.count == 20)
    }
}
