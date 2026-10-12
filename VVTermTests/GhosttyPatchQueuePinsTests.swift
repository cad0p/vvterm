// SPDX-License-Identifier: MIT
//
//  GhosttyPatchQueuePinsTests.swift
//  VVTermTests
//
//  Structural pins for the vendored Ghostty patch queue (#376): the four
//  fork-only C symbols the app depends on, the exact file set the patch
//  carries, the callback backend's `new file mode`, and the `BASE` commit
//  shape.
//
//  WHAT THESE PINS DELIBERATELY DO NOT ASSERT
//    - `git apply --check` against upstream: the suite has no upstream
//      checkout (and should not grow one), so patch applicability is enforced
//      by the weekly probe's `build-ghosttykit` step and the E0 host compile,
//      not here.
//    - `BASE == Vendor/libghostty/VERSION`: intentional in the staging tree
//      (`BASE` is the rebase target; `VERSION` records the committed binary's
//      base and is updated by the landing bump), so equality would pin the
//      wrong invariant.
//
//  The file list is the patch's actual `diff --git` set in patch order. A
//  future rebase that legitimately adds or removes a path must update this
//  pin and the README's 19-path regeneration list in the same commit; that
//  is the point — an accidental path (the demo app, the dep-URL swap,
//  commented-out debug code) cannot slip back in silently.
//
//  MEASURED COUNTERFACTUALS (each pin red under a targeted mutation of a copied
//  tree, run with `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>`; the
//  mutated tree needs only `scripts/patches/ghostty/custom-io.patch` and
//  `scripts/patches/ghostty/BASE` — the same hook the other pin suites use):
//    - drop the `set_write_callback: SetWriteCallback,` field → the fork-symbol
//      pin reds.
//    - delete the `pkg/macos/build.zig` section → the path-set pin reds
//      (18 parsed paths vs the pinned 19).
//    - drop `new file mode` from the Callback.zig section → the new-file pin
//      reds (the fold-round-1 defect this battery exists to catch).
//    - truncate `BASE` to 7 hex → the BASE-shape pin reds.
//    - unmutated copy → all four green (control).

import Foundation
import Testing

struct GhosttyPatchQueuePinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/GhosttyPatchQueuePinsTests.swift`).
    ///
    /// Counterfactual hook: mutation runs point `VVTERM_PINS_SOURCE_ROOT` at a
    /// mutated tree to prove the pins fail there. Never set in CI.
    private func repositoryRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GhosttyPatchQueuePinsTests.swift
            .deletingLastPathComponent()  // VVTermTests/
    }

    private func patchText() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(Self.patchPath),
            encoding: .utf8
        )
    }

    private func baseText() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(Self.basePath),
            encoding: .utf8
        )
    }

    private static let patchPath = "scripts/patches/ghostty/custom-io.patch"
    private static let basePath = "scripts/patches/ghostty/BASE"

    /// The fork-only API VVTerm cannot exist without (README "Why a patch at
    /// all"): config field, host-to-terminal feed, terminal-to-host callback
    /// installation, and the callback typedef.
    private static let forkSymbols = [
        "use_custom_io",
        "ghostty_surface_feed_data",
        "ghostty_surface_set_write_callback",
        "ghostty_surface_write_fn",
    ]

    /// The patch's actual `diff --git` set, in patch order.
    private static let expectedPatchPaths = [
        "HACKING.md",
        "include/ghostty.h",
        "macos/build.nu",
        "nix/devShell.nix",
        "pkg/macos/build.zig",
        "pkg/macos/iosurface/iosurface.zig",
        "src/Surface.zig",
        "src/apprt/embedded.zig",
        "src/build/Config.zig",
        "src/build/GhosttyXCFramework.zig",
        "src/build/MetallibStep.zig",
        "src/font/shaper/coretext.zig",
        "src/renderer/Metal.zig",
        "src/renderer/metal/IOSurfaceLayer.zig",
        "src/termio.zig",
        "src/termio/Callback.zig",
        "src/termio/Thread.zig",
        "src/termio/backend.zig",
        "src/termio/message.zig",
    ]

    /// Every `diff --git a/<path> b/<path>` path in the patch, in order, plus
    /// any `diff --git` header this parser could not read (a quoted path, say).
    /// The caller asserts the unreadable list is empty: a header this parser
    /// skips must fail closed, and comparing only the parsed list is not enough
    /// — an *added* unreadable header leaves the parsed list at the pinned 19
    /// and would pass silently (measured: appending
    /// `diff --git "a/foo bar.txt" "b/foo bar.txt"` to the patch kept the pin
    /// green before this check existed).
    private static func patchPaths(in text: String) -> (paths: [String], unreadable: [String]) {
        var paths: [String] = []
        var unreadable: [String] = []
        for line in text.components(separatedBy: "\n") where line.hasPrefix("diff --git ") {
            let rest = line.dropFirst("diff --git ".count)
            guard rest.hasPrefix("a/"), let separator = rest.range(of: " b/") else {
                unreadable.append(line)
                continue
            }
            paths.append(String(rest[..<separator.lowerBound]))
        }
        return (paths, unreadable)
    }

    // MARK: - Pins

    /// All four fork-only symbols must be carried by the patch. Each is a code
    /// dependency (not a runtime substitute), so a missing one means the app
    /// cannot build against the rebuilt core.
    @Test
    func testPatchCarriesEveryForkSymbol() throws {
        let patch = try patchText()
        for symbol in Self.forkSymbols {
            #expect(
                patch.contains(symbol),
                "the patch must carry the fork symbol \(symbol)"
            )
        }
        // The write-callback message payload is what wires the symbol into the
        // termio message union; it is the hunk the #376 rebase had to re-home.
        #expect(
            patch.contains("set_write_callback: SetWriteCallback,"),
            "the patch must carry the SetWriteCallback message field"
        )
    }

    /// The patch's path set is exactly the documented 19-file queue. Order is
    /// pinned too: a sorted comparison would hide a reordering-only diff in a
    /// file whose whole value is reviewability.
    @Test
    func testPatchDiffSetMatchesTheDocumentedFileList() throws {
        let parsed = Self.patchPaths(in: try patchText())
        #expect(
            parsed.unreadable.isEmpty,
            "every `diff --git` header must be readable by this pin; unreadable: \(parsed.unreadable)"
        )
        #expect(
            parsed.paths == Self.expectedPatchPaths,
            "patch paths changed; update the pin and the README's 19-path regeneration list together. found: \(parsed.paths)"
        )
    }

    /// `src/termio/Callback.zig` is the fork's new backend file. `git diff`
    /// silently drops untracked files, so a regenerated patch that loses the
    /// `new file mode` header builds a tree without the backend (the runbook's
    /// `git add -N src/termio/Callback.zig` gotcha).
    @Test
    func testCallbackBackendIsCarriedAsANewFile() throws {
        let patch = try patchText()
        let callbackHeader = try #require(
            patch.range(of: "diff --git a/src/termio/Callback.zig b/src/termio/Callback.zig"),
            "the patch must carry src/termio/Callback.zig"
        )
        let remainder = patch[callbackHeader.upperBound...]
        let nextFile = remainder.range(of: "diff --git ")?.lowerBound ?? remainder.endIndex
        let sectionText = String(patch[callbackHeader.lowerBound..<nextFile])
        #expect(
            sectionText.contains("new file mode "),
            "src/termio/Callback.zig must be carried as a new file"
        )
        #expect(
            sectionText.contains("--- /dev/null"),
            "src/termio/Callback.zig must be carried as a new file (no preimage)"
        )
    }

    /// `BASE` is the upstream commit the patch was rebased onto: a full 40-hex
    /// SHA. Deliberately not compared to `Vendor/libghostty/VERSION` (see the
    /// header note).
    @Test
    func testBaseIsA40HexUpstreamSha() throws {
        let base = try baseText().trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(base.count == 40, "BASE must be a full 40-hex SHA; found \(base.count) chars")
        #expect(
            base.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
            "BASE must be lowercase hex; found \(base)"
        )
    }
}
