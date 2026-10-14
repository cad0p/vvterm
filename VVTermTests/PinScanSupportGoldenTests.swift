// SPDX-License-Identifier: MIT
//  PinScanSupportGoldenTests.swift
//
//  The committed golden corpus for the shared pin-scan lexers (issues #450,
//  #453, #455). This is the permanent contract for `PinScan.strippingComments`,
//  `PinScan.strippingCommentsKeepingLiterals`,
//  `PinScan.strippingCommentsAndStrings`,
//  `PinScan.strippingCommentsAndStringsPreservingUTF16`,
//  `PinScan.strippingYAMLComments`, `PinScan.normalizedWhitespace` and
//  `PinScan.isInside`, now that the per-suite copies are gone. A deliberate
//  lexer change updates this file in the same commit.
//
//  Issue #455 fixed the #453 defects in place and turned the defeat rows into
//  fixed-output assertions: R1/R2 under-strip/shrink, CRLF/CR swallow,
//  R3 nested-quote leak and the canonical raw-string desync. The remaining
//  residuals (R2's raw-interpolation close, the escaped-triple-quote close and
//  the fabricated close of an unterminated interpolation) are pinned here with
//  their measured output.

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
            // A raw string is read with its exact delimiter (`#"…"#`, any
            // hash count), so a `//` in its body is not a comment and the
            // body is copied verbatim; the trailing comment still blanks.
            ("let s = #\"a // b\"# // real", "let s = #\"a // b\"#        "),
            // Interpolations and hashes are copied verbatim: the scanner
            // descends into `\( … )` only far enough to find the literal end,
            // and the interpolation text stays part of the copied literal.
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
            // A CRLF (or lone CR) ends the comment and is kept verbatim, with
            // the next line visible (Swift line terminators, issue #455).
            ("# c\r\nkey: value", "   \r\nkey: value"),
            ("key: value # c\r\nnext: 1", "key: value    \r\nnext: 1"),
            ("# c\rkey: value", "   \rkey: value"),
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
            // A `\` + CRLF inside a string keeps the backslash and the whole
            // CRLF grapheme (the `blanked()` worker no longer collapses it).
            ("backslash-crlf-in-string", "let s = \"a\\\r\nb\" // c\nlet x = 1", "let s = \" \\\r\n \"     \nlet x = 1"),
            // Residual (#455): a `"#` inside a raw interpolation body closes
            // `stringEnd`'s raw literal early, so the output shrinks. Recorded
            // here so the next construct cannot adopt it silently.
            ("raw-string-interp-embedded-close", "let s = #\"\\#(d[\"#\"]) // c\"#", "let s = #\"\\#()\"#\"       \"#"),
            // Residual (#455): the escaped-triple-quote form closes at the
            // first `"""` sequence, so ` b` and the final quotes stay as code.
            // The escaped-triple-quote row is the fixed-output record of it.
            ("escaped-triple-quote-leak", "let s = \"\"\"a \\\"\"\" b\"\"\"", "let s = \"\"\"   \"\"\" b\"\"\""),
            // Residual (#455): an unterminated interpolation fabricates a `)`
            // and shrinks (lens 1 m3). Pinned so the shrink stays visible.
            ("fabricated-close-unterminated-interp", "let s = \"\\(open", "let s = \"\\()"),
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

    /// The census mask's interpolation close skips nested string literals, so
    /// a bracket inside one cannot close the interpolation early and swallow
    /// the following line (`PinScanCensus.interpolationClose`'s
    /// `stringDelimiter`/`stringSkipEnd` arm). Binds that arm to a named test.
    @Test
    func censusMaskNestedLiteralBracketDoesNotCloseInterpolation() {
        let input = "let s = \"\\(d[\"x(y\"])\"\nlet y = 1"
        let mask = PinScanCensus.maskedCode(input, blankingStringContents: true)
        #expect(mask.unresolvedOffset == nil)
        #expect(mask.text == "let s =    d[     ]  \nlet y = 1")
        #expect(mask.text.hasSuffix("\nlet y = 1"))
    }

    /// Issue #455: the post-fix rows are checked against the properties the
    /// fix must hold, independently of their exact expected strings — a body
    /// sentinel never leaks into blanked code, the terminator grapheme is
    /// preserved verbatim with the next line visible, the per-scanner string
    /// semantics hold (canonical/R1 verbatim, R2/R3 blanked) and R3 keeps the
    /// UTF-16 length on every row.
    @Test
    func pinScanPostFixRowsPreserveTheirProperties() {
        // R1: the under-strip is gone — the literal (interpolation included)
        // stays verbatim and the tail blanks, with no leaked `tail` identifier.
        let r1UnderStrip = PinScan.strippingCommentsKeepingLiterals(
            "let s = \"\\(a /* ( */ + b)\" // tail\nlet y = 1"
        )
        #expect(r1UnderStrip == "let s = \"\\(a /* ( */ + b)\"        \nlet y = 1")
        #expect(!r1UnderStrip.contains("tail"))
        #expect(r1UnderStrip.hasSuffix("\nlet y = 1"))
        #expect(r1UnderStrip.count == "let s = \"\\(a /* ( */ + b)\" // tail\nlet y = 1".count)

        // R2: the shrink is gone — no fabricated close, the tail survives and
        // the interpolation-comment code stays; the interior blanks.
        let r2Shrink = PinScan.strippingCommentsAndStrings(
            "let s = \"\\(a /* ( */ + b)\"\nfunc repositoryRoot()"
        )
        #expect(r2Shrink == "let s = \"\\(a         + b)\"\nfunc repositoryRoot()")
        #expect(r2Shrink.hasSuffix("\nfunc repositoryRoot()"))
        #expect(!r2Shrink.contains("/*"))
        #expect(r2Shrink.utf16.count == "let s = \"\\(a /* ( */ + b)\"\nfunc repositoryRoot()".utf16.count)

        // R1/R2 terminators: CRLF and lone CR are kept verbatim, the next line
        // stays visible and the comment identifier blanks.
        for scanner in ["R1", "R2"] {
            let crlf = scanner == "R1"
                ? PinScan.strippingCommentsKeepingLiterals("let a = 1 // tail\r\nlet b = 2")
                : PinScan.strippingCommentsAndStrings("let a = 1 // tail\r\nlet b = 2")
            #expect(crlf.hasSuffix("\r\nlet b = 2"), "\(scanner) CRLF row: \(crlf.debugDescription)")
            #expect(!crlf.contains("tail"))
            let loneCR = scanner == "R1"
                ? PinScan.strippingCommentsKeepingLiterals("let a = 1 // tail\rlet b = 2")
                : PinScan.strippingCommentsAndStrings("let a = 1 // tail\rlet b = 2")
            #expect(loneCR.hasSuffix("\rlet b = 2"), "\(scanner) lone-CR row: \(loneCR.debugDescription)")
            #expect(!loneCR.contains("tail"))
        }

        // R2: a CRLF inside a block comment or a blanked string keeps both
        // UTF-16 units and the next line stays visible.
        let r2BlockCRLF = PinScan.strippingCommentsAndStrings("let a = 1 /* x\r\ny */ let b = 2\r\n")
        #expect(r2BlockCRLF.hasSuffix("let b = 2\r\n"))
        #expect(r2BlockCRLF.contains("\r\n"))
        let r2StringCRLF = PinScan.strippingCommentsAndStrings("let s = \"a\r\nb\" // c\nlet x = 1")
        #expect(r2StringCRLF.contains("\" \r\n \""))
        #expect(!r2StringCRLF.contains("a\r\nb"))
        #expect(r2StringCRLF.hasSuffix("\nlet x = 1"))

        // R3: the nested-quote leak is gone (no `k`), the UTF-16 length is
        // preserved and the following line stays visible on every row. The raw
        // `\#(` row has a `"#` in its body and the nested-interpolation and
        // interpolation-comment rows carry a `"`/`(`/`)` inside the body.
        let r3Rows: [(name: String, input: String, leaked: [String])] = [
            ("nested-quote", "let s = \"\\(d[\"k\"]) // c\"\nlet y = 1", ["k", "d["]),
            ("raw-interp-hash1", "let s = #\"\\#(d[\"#\"]) // c\"#", ["d[", "c\""]),
            ("nested-interpolation", "let s = \"\\(d[\"\\(x)\"])\"\nlet y = 1", ["\\(x)", "d["]),
            ("interp-block-comment", "let s = \"\\(a /* \" */ + b)\"\nlet y = 1", ["*/", "+ b)"]),
            ("interp-line-comment", "let s = \"\\(x // \" )\n + 2)\"\nlet y = 1", [" + 2)", "x //"]),
            ("lone-cr-in-comment", "let a = 1 // tail\rlet b = 2", ["tail"]),
        ]
        for row in r3Rows {
            let output = PinScan.strippingCommentsAndStringsPreservingUTF16(row.input)
            #expect(
                output.utf16.count == row.input.utf16.count,
                "R3 \(row.name) UTF-16 length \(output.utf16.count) != \(row.input.utf16.count)"
            )
            for leaked in row.leaked {
                #expect(!output.contains(leaked), "R3 \(row.name) leaked \(leaked.debugDescription): \(output.debugDescription)")
            }
            if row.input.contains("\n") {
                #expect(output.hasSuffix("\nlet y = 1") || output.hasSuffix("let b = 2"), "R3 \(row.name) swallowed the next line: \(output.debugDescription)")
            }
        }

        // Canonical/R1: string contents stay verbatim, the trailing comment
        // blanks, and the output keeps the input's Character count.
        for rawString in ["#\"a \"b\"# // tail", "##\"a#\"#b\"## // tail"] {
            for output in [PinScan.strippingComments(rawString), PinScan.strippingCommentsKeepingLiterals(rawString)] {
                #expect(output.contains(rawString.prefix(8)))
                #expect(!output.contains("tail"))
                #expect(output.count == rawString.count)
            }
        }
        // Canonical/R1 CRLF and lone-CR comment rows: the terminator is kept
        // verbatim, the next line stays visible and the comment identifier
        // blanks. The canonical scanner runs the R1 worker (D5 alias).
        for (input, terminator) in [
            ("let a = 1 // tail\r\nlet b = 2", "\r\n"),
            ("let a = 1 // tail\rlet b = 2", "\r"),
        ] {
            for output in [
                PinScan.strippingComments(input),
                PinScan.strippingCommentsKeepingLiterals(input),
            ] {
                #expect(output.hasSuffix("\(terminator)let b = 2"), "canonical/R1 \(input.debugDescription): \(output.debugDescription)")
                #expect(!output.contains("tail"))
                #expect(output.utf16.count == input.utf16.count)
            }
        }

        // YAML CRLF/CR rows: the comment blanks, the terminator is kept
        // verbatim and the next line stays visible.
        for (input, suffix) in [
            ("# c\r\nkey: value", "\r\nkey: value"),
            ("key: value # c\r\nnext: 1", "\r\nnext: 1"),
            ("# c\rkey: value", "\rkey: value"),
        ] {
            let output = PinScan.strippingYAMLComments(input)
            #expect(output.hasSuffix(suffix), "YAML \(input.debugDescription): \(output.debugDescription)")
            #expect(!output.contains("#"))
            #expect(output.utf16.count == input.utf16.count)
        }
    }
}
