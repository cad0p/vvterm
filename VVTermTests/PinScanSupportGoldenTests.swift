//  PinScanSupportGoldenTests.swift
//
//  The committed golden corpus for the shared pin-scan lexers (issue #450).
//  This is the permanent contract for `PinScan.strippingComments`,
//  `PinScan.strippingYAMLComments`, `PinScan.normalizedWhitespace` and
//  `PinScan.isInside`, now that the per-suite copies are gone. A deliberate
//  lexer change updates this file in the same commit.

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
}
