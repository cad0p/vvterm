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
            ("let s = \"a // b\"", "let s = \"a // b\""),            // A `/*` inside a string literal is not a comment.
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
            // Divergent raw-string cases, fixed by issue #455: the canonical
            // scanner is now hash-aware (the shared worker's string handling),
            // so the embedded quote no longer desynchronizes it and the
            // trailing comment blanks.
            ("#\"a \"b\"# // tail", "#\"a \"b\"#        "),
            ("##\"a#\"#b\"## // tail", "##\"a#\"#b\"##        "),
            // Triple-quoted raw string with a `//` inside: the literal is
            // copied verbatim and a `//` inside it is not a comment.
            ("let s = #\"\"\"a // b\"\"\"#", "let s = #\"\"\"a // b\"\"\"#"),
            // A trailing comment after a triple-quoted raw string still blanks.
            ("let s = #\"\"\"a \"b\" // c\"\"\"# // tail", "let s = #\"\"\"a \"b\" // c\"\"\"#        "),
            // Swift line terminators: a `//` comment ends on CRLF (one
            // Character) or CR, and the terminator is preserved verbatim.
            ("let a = 1 // tail\r\nlet b = 2", "let a = 1        \r\nlet b = 2"),
            ("let a = 1 // tail\rlet b = 2", "let a = 1        \rlet b = 2"),
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
    /// interpolations included — verbatim. The #453 defeat rows are fixed
    /// output assertions (issue #455): a comment in an interpolation body no
    /// longer inflates the bracket depth, and Swift line terminators (LF,
    /// CRLF, CR) end a `//` comment with the terminator kept verbatim.
    @Test
    func strippingCommentsKeepingLiteralsGoldenCorpus() {
        let cases: [(name: String, input: String, expected: String)] = [
            ("line-comment-lf", "let a = 1 // tail\nlet b = 2", "let a = 1        \nlet b = 2"),
            ("string-decoy", "let s = \"a // b\"\nlet x = 1", "let s = \"a // b\"\nlet x = 1"),
            ("raw-string-embedded-quote", "#\"a \"b\"# // tail", "#\"a \"b\"#        "),
            ("raw-string-hash2", "##\"a#\"#b\"## // tail", "##\"a#\"#b\"##        "),
            ("interpolation-verbatim", "let s = \"\\(x) // c\"", "let s = \"\\(x) // c\""),
            ("raw-interpolation-verbatim", "let s = #\"\\#(x) // c\"#", "let s = #\"\\#(x) // c\"#"),
            // The #453 under-strip: a `(` in an interpolation block comment no
            // longer inflates the depth; the real close is found and the tail
            // blanks.
            ("under-strip-interp-comment", "let s = \"\\(a /* ( */ + b)\" // tail\nlet y = 1", "let s = \"\\(a /* ( */ + b)\"        \nlet y = 1"),
            // A `(` in an interpolation line comment is comment content too.
            ("interp-line-comment-open-paren", "let s = \"\\(a // (\n + b)\" // tail\nlet y = 1", "let s = \"\\(a // (\n + b)\"        \nlet y = 1"),
            // A `)` in an interpolation line comment does not close it early.
            ("interp-line-comment-close-paren", "let s = \"\\(a // )\n + b)\" // tail\nlet y = 1", "let s = \"\\(a // )\n + b)\"        \nlet y = 1"),
            ("unterminated-string", "let s = \"open", "let s = \"open"),
            // A CRLF (or lone CR) ends the comment and is kept verbatim; the
            // next line stays visible.
            ("crlf-in-comment", "let a = 1 // tail\r\nlet b = 2", "let a = 1        \r\nlet b = 2"),
            ("lone-cr-in-comment", "let a = 1 // tail\rlet b = 2", "let a = 1        \rlet b = 2"),
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
    /// The #453 shrink and CRLF-swallow rows are fixed output assertions
    /// (issue #455), joined by the CRLF-inside-a-block-comment/string rows.
    @Test
    func strippingCommentsAndStringsGoldenCorpus() {
        let cases: [(name: String, input: String, expected: String)] = [
            ("line-comment-lf", "let a = 1 // tail\nlet b = 2", "let a = 1        \nlet b = 2"),
            ("string-decoy", "let s = \"a // b\"\nlet x = 1", "let s = \"      \"\nlet x = 1"),
            ("interpolation-as-code", "let s = \"\\(x) // c\"", "let s = \"\\(x)     \""),
            ("comment-in-interpolation", "let s = \"\\(a /* x */ + b)\"", "let s = \"\\(a         + b)\""),
            // The #453 shrink: the interpolation close resolves and the tail
            // survives — 48 -> 48, not the fabricated `let s = "\()`.
            ("shrink-interp-comment", "let s = \"\\(a /* ( */ + b)\"\nfunc repositoryRoot()", "let s = \"\\(a         + b)\"\nfunc repositoryRoot()"),
            // A `(`/`)` in an interpolation line comment is comment content;
            // the comment blanks and the body code stays.
            ("interp-line-comment-open-paren", "let s = \"\\(a // (\n + b)\" // tail\nlet y = 1", "let s = \"\\(a     \n + b)\"        \nlet y = 1"),
            ("interp-line-comment-close-paren", "let s = \"\\(a // )\n + b)\" // tail\nlet y = 1", "let s = \"\\(a     \n + b)\"        \nlet y = 1"),
            ("raw-interpolation-as-code", "let s = #\"\\#(x) // c\"#", "let s = #\"\\#(x)     \"#"),
            ("unterminated-string", "let s = \"open", "let s = \"    "),
            // A CRLF ends the comment and is kept verbatim; the next line stays.
            ("crlf-in-comment", "let a = 1 // tail\r\nlet b = 2", "let a = 1        \r\nlet b = 2"),
            // A CRLF inside a block comment (or a blanked string) keeps its two
            // UTF-16 units instead of collapsing to one space.
            ("crlf-in-block-comment", "let a = 1 /* x\r\ny */ let b = 2\r\n", "let a = 1     \r\n     let b = 2\r\n"),
            ("crlf-in-string", "let s = \"a\r\nb\" // c\nlet x = 1", "let s = \" \r\n \"     \nlet x = 1"),
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
    /// #453 nested-quote leak is a fixed-output assertion (issue #455): the
    /// interpolation body is skipped with a bracket stack that looks through
    /// nested literals and comments, so the inner `"` cannot exit the literal
    /// early. The `non-bmp` row makes the UTF-16 length assertion non-vacuous
    /// (19 Characters / 20 UTF-16 units in, 20/20 out).
    @Test
    func strippingCommentsAndStringsPreservingUTF16GoldenCorpus() {
        let cases: [(name: String, input: String, expected: String)] = [
            ("line-comment-lf", "let a = 1 // tail\nlet b = 2", "let a = 1        \nlet b = 2"),
            ("interpolation-as-content", "let s = \"\\(x) // c\"\nlet y = 1", "let s =            \nlet y = 1"),
            // The #453 nested-quote leak, fixed: the whole literal blanks and
            // the `k` no longer leaks into code; the UTF-16 length matches.
            ("nested-quote-leak", "let s = \"\\(d[\"k\"]) // c\"\nlet y = 1", "let s =                 \nlet y = 1"),
            ("hash-prefix-close", "##\"a \"## b\"## // tail", "         b           "),
            ("multiline-literal", "let s = \"\"\"\nfunc\n\"\"\" // tail\nlet x = 1", "let s =    \n    \n           \nlet x = 1"),
            // The LF unit is kept and the CR blanked (UTF-16 unit fidelity);
            // a lone CR now also ends the comment (issue #455).
            ("crlf-in-comment", "let a = 1 // tail\r\nlet b = 2", "let a = 1         \nlet b = 2"),
            ("lone-cr-in-comment", "let a = 1 // tail\rlet b = 2", "let a = 1         let b = 2"),
            ("unterminated-string", "let s = \"open", "let s =      "),
            ("non-bmp", "let s = \"😀\" // tail", "let s =             "),
            // Raw `\#(` with a `"#`-in-body: the exact hash count and the
            // bracket-stack skip keep the literal one span.
            ("raw-interp-hash1", "let s = #\"\\#(d[\"#\"]) // c\"#", "let s =                    "),
            // Nested interpolation inside an interpolation string.
            ("nested-interpolation", "let s = \"\\(d[\"\\(x)\"])\"\nlet y = 1", "let s =               \nlet y = 1"),
            // A `"` inside an interpolation block comment is comment content.
            ("interp-block-comment-quote", "let s = \"\\(a /* \" */ + b)\"\nlet y = 1", "let s =                   \nlet y = 1"),
            // A `"` inside an interpolation line comment is comment content
            // too; the comment ends at the terminator and the body resolves.
            ("interp-line-comment-quote", "let s = \"\\(x // \" )\n + 2)\"\nlet y = 1", "let s =            \n      \nlet y = 1"),
            ("interp-line-comment-close-paren", "let s = \"\\(a // )\n + b)\" // tail\nlet y = 1", "let s =          \n              \nlet y = 1"),
            ("crlf-in-string", "let s = \"a\r\nb\" // c\nlet x = 1", "let s =    \n       \nlet x = 1"),
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
