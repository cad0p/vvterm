// SPDX-License-Identifier: MIT
//
//  TerminalRichPasteProbeCommandTests.swift
//  VVTermTests
//
//  Command-shape pins for the four pure clipboard probe builders converted to
//  non-login shells by #324. The clipboard surface had no command-shape
//  coverage before: the parse arms themselves need a remote server (the
//  blocker is stated in the PR), so these assert the wrapped prefix and the
//  parse-relevant tokens of each builder directly.
//
//  Each builder is `nonisolated static`, so no SSH client or actor hop is
//  needed. A login-shell regression at any of these sites reddens both this
//  suite and `SSHProbeShellPinsTests`.

import Foundation
import Testing
@testable import VVTerm

struct TerminalRichPasteProbeCommandTests {

    /// The body of a `wrapPOSIXProbeCommand` output: strips the outer
    /// `sh -c '…'` and unescapes the `'\''` a body-embedded single quote is
    /// encoded as. The #323 lesson: assertions on a wrapped probe must be
    /// made at the body level, because the outer single-quote wrapper escapes
    /// every quote in the body a second time.
    private static func probeBody(_ command: String) -> String {
        let prefix = "sh -c '"
        let suffix = "'"
        guard command.hasPrefix(prefix), command.hasSuffix(suffix) else { return command }
        let body = String(command.dropFirst(prefix.count).dropLast(suffix.count))
        return body.replacingOccurrences(of: "'\\''", with: "'")
    }

    @Test
    func unixClipboardProbeRunsInANonLoginShell() {
        let command = TerminalRichPasteCoordinator.unixClipboardProbeCommand()
        let body = Self.probeBody(command)

        #expect(command.hasPrefix("sh -c '"))
        #expect(!command.contains("-lc"))
        #expect(body.contains("printf '%s' wayland"))
        #expect(body.contains("printf '%s' x11"))
        #expect(body.contains("printf '%s' unsupported"))
        #expect(command.contains("${WAYLAND_DISPLAY:-}"))
        #expect(command.contains("${DISPLAY:-}"))
        #expect(command.contains("wl-copy"))
        #expect(command.contains("xclip"))
    }

    @Test
    func darwinClipboardProbeRunsInANonLoginShell() {
        let command = TerminalRichPasteCoordinator.darwinClipboardProbeCommand()
        let body = Self.probeBody(command)

        #expect(command.hasPrefix("sh -c '"))
        #expect(!command.contains("-lc"))
        #expect(body.contains("printf '%s' darwin"))
        #expect(body.contains("printf '%s' unsupported"))
        #expect(command.contains("osascript"))
        #expect(command.contains("launchctl print \"gui/$(id -u)\""))
    }

    @Test
    func clipboardSeedProbeRunsInANonLoginShellAndCarriesTheSentinel() {
        let sentinel = "__vvterm_clipboard_seeded__"
        let command = TerminalRichPasteCoordinator.clipboardSeedCommand(
            clipboardCommand: "wl-copy < /tmp/image.png",
            sentinel: sentinel
        )
        let body = Self.probeBody(command)

        #expect(command.hasPrefix("sh -c '"))
        #expect(!command.contains("-lc"))
        #expect(body.contains(sentinel))
        #expect(body.contains("printf '%s'"))
        #expect(body.contains(">/dev/null 2>&1"))
        #expect(body.contains("wl-copy < /tmp/image.png"))
    }

    @Test
    func temporaryPathProbeRunsInANonLoginShellAndKeepsThePathShape() {
        let command = RemoteClipboardTransferService.temporaryPathCommand(extension: "png")
        let body = Self.probeBody(command)

        #expect(command.hasPrefix("sh -c '"))
        #expect(!command.contains("-lc"))
        #expect(command.contains("tmp_base=\"${TMPDIR:-/tmp}\""))
        #expect(command.contains("vvterm-clipboard-XXXXXX"))
        #expect(command.contains("mktemp"))
        #expect(command.contains("mv \"$tmp_path\" \"$target_path\""))
        #expect(body.contains("printf '%s\n' \"$target_path\""))
        #expect(command.contains(".png"))
    }
}
