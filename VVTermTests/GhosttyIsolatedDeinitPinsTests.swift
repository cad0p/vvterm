// SPDX-License-Identifier: MIT
//
//  GhosttyIsolatedDeinitPinsTests.swift
//  VVTermTests
//
//  CI-visible source pins for the #294 sweep (VVTerm/GhosttyTerminal).
//
//  A MainActor-isolated class with no explicit `deinit` gets a
//  compiler-synthesized *isolated* deinit (`__isolated_deallocating_deinit`,
//  mangled `…CfZ`). Releasing such an object outside a Swift task context takes
//  the back-deployed MainActor deinit path and aborts in libmalloc (`pointer
//  being freed was not allocated`) — swiftlang/swift#85663, #88036. The sweep
//  adds the repo's standard empty marker (`nonisolated deinit {}`) to every such
//  class in VVTerm/GhosttyTerminal; these pins keep it there.
//
//  WHY SOURCE PINS AND NOT A RUNTIME TEST: the abort reproduces on the iOS
//  26.3.1 simulator runtime but not on the CI runtime, so a runtime test is
//  green by construction in CI. The binary-level oracle (`nm … | grep 'CfZ$'` +
//  `swift-demangle`) is the primary acceptance and runs locally; these pins are
//  the CI-visible tripwire. The #280 runtime suite
//  (`Features/Stats/StatsIsolatedDeinitReleaseTests.swift`) remains the local
//  runtime proof that the marker removes the abort.
//
//  WHAT THESE PINS SEE (and what they do not): each pin comment-strips the
//  source, optionally slices the enclosing declaration first, resolves the class
//  body with `bracedBlock(after:)`, checks a positive control first (so a
//  mis-resolved span cannot satisfy the assertion), then asserts exactly one
//  `nonisolated deinit {}` at *relative* depth 1 — the class's own member level,
//  so a marker moved into a nested type cannot satisfy it. Every anchor and
//  every control is asserted unique before use, with identifier-boundary-aware
//  matching (`final class InlineEditingTextField` must not match the prefix of
//  `InlineEditingTextFieldCell`).
//
//  Reported defeats (measured against the real sources in the PR's
//  counterfactual runs): a marker deleted (count 0), a marker moved to another
//  class in the same file (source count 0, sink count 2), a marker moved into a
//  nested type (the source's relative-depth-1 count drops to 0), a rename (the
//  anchor no longer resolves), a multi-line `nonisolated deinit {` + `}`
//  spelling (the exact-token count drops to 0), and a duplicated anchor text
//  (the uniqueness assertion fails).
//
//  VERIFIED FALSE GREENS, deliberately not claimed as caught: a marker inside
//  `#if false` and a marker inside a string literal both keep the token at
//  relative depth 1 and stay green. A tripwire, not a proof.
//

import Foundation
import Testing

@testable import VVTerm

struct GhosttyIsolatedDeinitPinsTests {

    // MARK: - Pin table

    /// One swept class. `scopeAnchor` slices the enclosing declaration first
    /// (nested types, and the two same-named `Coordinator`s in one file);
    /// `control` is a member token unique in the resolved body and in the file
    /// that proves the resolved span is the intended class body.
    private struct Pin {
        let file: String
        let anchor: String
        let scopeAnchor: String?
        let control: String

        init(file: String, anchor: String, scopeAnchor: String? = nil, control: String) {
            self.file = file
            self.anchor = anchor
            self.scopeAnchor = scopeAnchor
            self.control = control
        }
    }

    private static let pins: [Pin] = [
        Pin(file: "VVTerm/GhosttyTerminal/Ghostty.App.swift", anchor: "class SurfaceReference", scopeAnchor: "enum Ghostty", control: "let surface: ghostty_surface_t"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyIMEHandler.swift", anchor: "class GhosttyIMEHandler", control: "private weak var view"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyInputHandler.swift", anchor: "class GhosttyInputHandler", control: "private weak var view"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyNativeFindSession.swift", anchor: "final class GhosttyNativeFindSession", control: "private let onSearch"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyRenderingSetup.swift", anchor: "class GhosttyRenderingSetup", control: "nonisolated private static let logger"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyTerminalTouchSelection.swift", anchor: "final class TerminalTouchSelectionHandleView", control: "let kind"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyTerminalTouchSelection.swift", anchor: "final class TerminalTouchSelectionOverlayView", control: "private let highlightLayer"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyTerminalTouchSelection.swift", anchor: "final class TerminalTouchSelectionLoupeView", control: "private let chromeView"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift", anchor: "final class TerminalSuppressedKeyboardInputView", control: "init()"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift", anchor: "private final class TerminalIMEProxyTextView", control: "private var documentBuffer"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift", anchor: "private final class RepeatableKeyButton", control: "var key"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift", anchor: "private final class TerminalZoomIndicatorView", control: "private let valueLabel"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyTerminalView+macOS.swift", anchor: "private final class DisplayLinkCallbackContext", control: "private let lock"),
        Pin(file: "VVTerm/GhosttyTerminal/GhosttyTerminalView+macOS.swift", anchor: "private final class TerminalZoomIndicatorView", control: "private let valueLabel"),
        Pin(file: "VVTerm/GhosttyTerminal/TerminalNativeTextSelection.swift", anchor: "final class TerminalNativeTextPosition", control: "let offset: Int"),
        Pin(file: "VVTerm/GhosttyTerminal/TerminalNativeTextSelection.swift", anchor: "final class TerminalNativeTextRange", control: "let startPosition"),
        Pin(file: "VVTerm/GhosttyTerminal/TerminalNativeTextSelection.swift", anchor: "final class TerminalNativeSelectionRect", control: "private let storedRect"),
        Pin(file: "VVTerm/GhosttyTerminal/TerminalNativeTextSelection.swift", anchor: "final class TerminalNativeFindOverlayView", control: "var highlights"),
    ]

    /// The sweep's file census: one entry per swept file, `count` = the number
    /// of pinned classes in that file. The completeness test below asserts the
    /// pins table and this census agree — and that each file actually carries
    /// exactly that many `nonisolated deinit {}` tokens — so a dropped row plus
    /// the matching dropped marker is red even in a single-pin file.
    private static let markerCountsPerFile: [(file: String, count: Int)] = [
        (file: "VVTerm/GhosttyTerminal/Ghostty.App.swift", count: 1),
        (file: "VVTerm/GhosttyTerminal/GhosttyIMEHandler.swift", count: 1),
        (file: "VVTerm/GhosttyTerminal/GhosttyInputHandler.swift", count: 1),
        (file: "VVTerm/GhosttyTerminal/GhosttyNativeFindSession.swift", count: 1),
        (file: "VVTerm/GhosttyTerminal/GhosttyRenderingSetup.swift", count: 1),
        (file: "VVTerm/GhosttyTerminal/GhosttyTerminalTouchSelection.swift", count: 3),
        (file: "VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift", count: 4),
        (file: "VVTerm/GhosttyTerminal/GhosttyTerminalView+macOS.swift", count: 2),
        (file: "VVTerm/GhosttyTerminal/TerminalNativeTextSelection.swift", count: 4),
    ]

    // MARK: - Tests

    /// Table completeness: every other test in this suite iterates `Self.pins`,
    /// so an emptied or shortened table would be silently vacuous. 18
    /// is the sweep's recorded class count for this area (one marker per class).
    @Test
    func testGhosttyPinTableIsComplete() {
        #expect(
            Self.pins.count == 18,
            "the Ghostty pin table must stay complete: expected 18 rows, found \(Self.pins.count)"
        )
    }

    @Test
    func testGhosttyClassesCarryExactlyOneNonisolatedDeinit() {
        for pin in Self.pins {
            Self.checkPin(pin)
        }
    }

    @Test
    func testGhosttyPinAnchorsResolveUniquely() {
        for pin in Self.pins {
            Self.checkAnchorResolution(pin)
        }
    }

    @Test
    func testGhosttySweptFilesCarryTheExpectedMarkerCount() {
        // The census must cover every pinned file exactly once, and each entry
        // must equal the number of pinned classes in that file (markers-in-file
        // == pins-for-file), so dropping a row together with its marker cannot
        // pass even in a single-pin file.
        var pinsPerFile: [String: Int] = [:]
        for pin in Self.pins {
            pinsPerFile[pin.file, default: 0] += 1
        }
        let pinnedFiles = Set(pinsPerFile.keys)
        let countedFiles = Set(Self.markerCountsPerFile.map(\.file))
        #expect(
            pinnedFiles == countedFiles,
            "the file census must cover every pinned file exactly once: pins-only \(pinnedFiles.subtracting(countedFiles).sorted()), counts-only \(countedFiles.subtracting(pinnedFiles).sorted())"
        )
        for entry in Self.markerCountsPerFile {
            #expect(
                pinsPerFile[entry.file] == entry.count,
                "\(entry.file): the census entry (\(entry.count)) must equal the pinned class count in the file (\(pinsPerFile[entry.file] ?? 0))"
            )
            let text: String
            do {
                text = try Self.strippingComments(Self.source(entry.file))
            } catch {
                Issue.record("\(entry.file): cannot read the pinned source file: \(error)")
                continue
            }
            let count = Self.occurrences(of: "nonisolated deinit {}", in: text).count
            #expect(
                count == entry.count,
                "\(entry.file): expected \(entry.count) `nonisolated deinit {}` markers, found \(count)"
            )
        }
    }

    // MARK: - #299 convergence pins (iOS GhosttyTerminalView)

    /// iOS `GhosttyTerminalView` is the class #299 converged: it used to keep a
    /// deliberate `isolated deinit` because its body called two MainActor
    /// instance methods. It now carries a `nonisolated deinit` with a real body
    /// (the observer removals and the deferred unregister); the two MainActor
    /// calls live in `cleanup()`. The four tests below pin the converged shape
    /// from independent angles: a reversion reds 1, 2 and 3; a stray
    /// re-introduction elsewhere reds 3; a body collapse reds 1 and 4; and the
    /// file census test above keeps the exact-marker count load-bearing.
    private static let terminalViewFile = "VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift"

    /// The comment-stripped `GhosttyTerminalView+iOS.swift` source, or `nil`
    /// after recording why it could not be read.
    private static func terminalViewSource() -> String? {
        do {
            return try strippingComments(source(terminalViewFile))
        } catch {
            Issue.record("\(terminalViewFile): cannot read the pinned source file: \(error)")
            return nil
        }
    }

    /// The resolved body of `class GhosttyTerminalView`, or `nil` after
    /// recording why it did not resolve. The body contains nested types, so
    /// callers must use `relativeDepth` for member-level assertions.
    private static func terminalViewBody(in text: String) -> Range<String.Index>? {
        let anchors = occurrences(of: "class GhosttyTerminalView", in: text)
        guard anchors.count == 1 else {
            Issue.record("\(terminalViewFile): the `class GhosttyTerminalView` anchor must be unique (found \(anchors.count)); the declaration was renamed, duplicated or moved")
            return nil
        }
        do {
            return try bracedBlock(after: anchors[0], in: text)
        } catch {
            Issue.record("\(terminalViewFile): the `class GhosttyTerminalView` anchor does not open a braced body: \(error)")
            return nil
        }
    }

    /// 1 of 4 — exactly one `nonisolated deinit` at class-member depth, behind a
    /// positive control that proves the resolved span is the intended body.
    @Test
    func testGhosttyTerminalViewCarriesExactlyOneNonisolatedDeinit() {
        guard let text = Self.terminalViewSource() else { return }
        guard let body = Self.terminalViewBody(in: text) else { return }

        // Positive control first: a mis-resolved span (wrong class, wrong
        // platform twin, nested type) must fail here, not pass by accident.
        let controls = Self.occurrences(of: "internal var surface: Ghostty.Surface?", in: text, range: body)
        #expect(
            controls.count == 1,
            "\(Self.terminalViewFile): the positive control `internal var surface: Ghostty.Surface?` must occur exactly once in the resolved class body (found \(controls.count))"
        )

        let tokens = Self.occurrences(of: "nonisolated deinit", in: text, range: body)
            .filter { Self.relativeDepth(of: $0, to: body, in: text) == 1 }
        #expect(
            tokens.count == 1,
            "\(Self.terminalViewFile): GhosttyTerminalView must carry exactly one `nonisolated deinit` at class-member depth (found \(tokens.count)); #299 converged it off the deliberate isolated deinit"
        )
    }

    /// 2 of 4 — zero `isolated deinit` anywhere in the file, no depth filter:
    /// any occurrence in this file is a #299 regression (GQ-9). Matching is
    /// boundary-aware and comment-stripped, so `nonisolated deinit` (a longer
    /// token) and the deinit's own comment ("must NOT carry an isolated
    /// deinit") do not count.
    @Test
    func testGhosttyTerminalViewFileHasNoIsolatedDeinit() {
        guard let text = Self.terminalViewSource() else { return }
        let isolated = Self.occurrences(of: "isolated deinit", in: text)
        #expect(
            isolated.count == 0,
            "\(Self.terminalViewFile): no `isolated deinit` may appear anywhere in this file (found \(isolated.count)); see #299"
        )
    }

    /// 3 of 4 — zero `isolated deinit` anywhere under `VVTerm/`. This is the
    /// repo-wide containment for the hazard: a new deliberately-isolated deinit
    /// in any shipped app source reds here, not only in the Ghostty file. The
    /// scan reads `repositoryRoot()` — the real repository in CI, which never
    /// sets the `VVTERM_PINS_SOURCE_ROOT` override; the mutated-tree copy is
    /// read only by the explicit counterfactual runs.
    @Test
    func testNoIsolatedDeinitUnderVVTerm() {
        let root = Self.repositoryRoot()
        let vvterm = root.appendingPathComponent("VVTerm", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: vvterm,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("VVTerm/: the source-root enumerator returned nil for \(vvterm.path); a wrong or missing scan root must not pass green")
            return
        }

        // `resolvingSymlinksInPath()` on both ends keeps the relative-path
        // computation correct when the scan root passes through a symlink (the
        // counterfactual copies live under /tmp → /private/tmp).
        let resolvedRoot = vvterm.resolvingSymlinksInPath().path
        var swiftFiles: [(relativePath: String, url: URL)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let resolvedURL = url.resolvingSymlinksInPath()
            guard resolvedURL.path.hasPrefix(resolvedRoot + "/") else {
                Issue.record("\(resolvedURL.path): the enumerator yielded a file outside \(resolvedRoot)")
                continue
            }
            let relativePath = "VVTerm/" + String(resolvedURL.path.dropFirst(resolvedRoot.count + 1))
            swiftFiles.append((relativePath, resolvedURL))
        }

        // Vacuity floor + positive control (GQ-1): 429 Swift files today, so a
        // typo'd or empty scan root must fail, not pass green.
        #expect(
            swiftFiles.count >= 400,
            "VVTerm/: the repo-wide scan must cover at least 400 Swift files (found \(swiftFiles.count))"
        )
        let control = Self.terminalViewFile
        #expect(
            swiftFiles.contains { $0.relativePath == control },
            "VVTerm/: the scan must include `\(control)` as a positive control"
        )
        guard swiftFiles.count >= 400, swiftFiles.contains(where: { $0.relativePath == control }) else { return }

        var offenders: [String] = []
        for (relativePath, url) in swiftFiles {
            let source: String
            do {
                source = try String(contentsOf: url, encoding: .utf8)
            } catch {
                Issue.record("\(relativePath): cannot read the scanned source file: \(error)")
                continue
            }
            let hits = Self.occurrences(of: "isolated deinit", in: Self.strippingComments(source))
            if !hits.isEmpty {
                offenders.append("\(relativePath) (\(hits.count))")
            }
        }
        #expect(
            offenders.isEmpty,
            "VVTerm/: no shipped source file may carry an `isolated deinit`; offenders: \(offenders.sorted())"
        )
    }

    /// 4 of 4 — the converged deinit body survives (GQ-2). The exact-token
    /// marker count deliberately does not see the with-body spelling, so a
    /// future #294-style sweep collapsing it to `nonisolated deinit {}` reds
    /// here.
    @Test
    func testGhosttyTerminalViewDeinitBodySurvives() {
        guard let text = Self.terminalViewSource() else { return }
        guard let body = Self.terminalViewBody(in: text) else { return }
        let tokens = Self.occurrences(of: "nonisolated deinit", in: text, range: body)
            .filter { Self.relativeDepth(of: $0, to: body, in: text) == 1 }
        guard tokens.count == 1 else {
            Issue.record("\(Self.terminalViewFile): the class-member `nonisolated deinit` token must be unique to pin its body (found \(tokens.count))")
            return
        }
        let token = tokens[0]
        let afterToken = text[token.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" }
        #expect(
            afterToken.first == "{",
            "\(Self.terminalViewFile): `nonisolated deinit` must be followed by a body, not by `;` or another declaration"
        )
        guard afterToken.first == "{", let deinitBody = try? Self.bracedBlock(after: token, in: text) else { return }

        let bodyText = text[deinitBody]
        #expect(
            !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(Self.terminalViewFile): the converged `nonisolated deinit` body must not be empty; #299 keeps nonisolated teardown here"
        )
        let observerRemovals = Self.occurrences(of: "NotificationCenter.default.removeObserver", in: text, range: deinitBody)
        #expect(
            observerRemovals.count >= 3,
            "\(Self.terminalViewFile): the deinit body must keep the three observer removals (found \(observerRemovals.count))"
        )
        let unregisters = Self.occurrences(of: "unregisterSurface", in: text, range: deinitBody)
        #expect(
            unregisters.count >= 1,
            "\(Self.terminalViewFile): the deinit body must keep the deferred `unregisterSurface` (found \(unregisters.count))"
        )
    }


    // MARK: - Pin checks

    private static func checkPin(_ pin: Pin) {
        let text: String
        do {
            text = try strippingComments(source(pin.file))
        } catch {
            Issue.record("\(pin.file): cannot read the pinned source file: \(error)")
            return
        }
        guard let body = resolveBody(pin, in: text) else { return }

        // Positive control first: a mis-resolved span (wrong class, wrong
        // platform twin, nested type) must fail here, not pass by accident.
        let controls = occurrences(of: pin.control, in: text, range: body)
        #expect(
            controls.count == 1,
            "\(pin.file) [\(pin.anchor)]: the positive control \(pin.control.debugDescription) must occur exactly once in the resolved body (found \(controls.count))"
        )

        let markers = occurrences(of: "nonisolated deinit {}", in: text, range: body)
            .filter { relativeDepth(of: $0, to: body, in: text) == 1 }
        #expect(
            markers.count == 1,
            "\(pin.file) [\(pin.anchor)]: expected exactly one `nonisolated deinit {}` at class-member depth, found \(markers.count)"
        )
    }

    private static func checkAnchorResolution(_ pin: Pin) {
        let text: String
        do {
            text = try strippingComments(source(pin.file))
        } catch {
            Issue.record("\(pin.file): cannot read the pinned source file: \(error)")
            return
        }
        if let scopeAnchor = pin.scopeAnchor {
            let scopes = occurrences(of: scopeAnchor, in: text)
            #expect(
                scopes.count == 1,
                "\(pin.file): the enclosing anchor \(scopeAnchor.debugDescription) must be unique in the file (found \(scopes.count))"
            )
            guard scopes.count == 1, let scope = try? bracedBlock(after: scopes[0], in: text) else { return }
            let anchors = occurrences(of: pin.anchor, in: text, range: scope)
            #expect(
                anchors.count == 1,
                "\(pin.file): the class anchor \(pin.anchor.debugDescription) must be unique in its scope (found \(anchors.count))"
            )
            return
        }
        let anchors = occurrences(of: pin.anchor, in: text)
        #expect(
            anchors.count == 1,
            "\(pin.file): the class anchor \(pin.anchor.debugDescription) must be unique in the file (found \(anchors.count))"
        )
    }

    /// The class body for `pin`, or `nil` after recording why it did not resolve.
    private static func resolveBody(_ pin: Pin, in text: String) -> Range<String.Index>? {
        var scope = text.startIndex..<text.endIndex
        if let scopeAnchor = pin.scopeAnchor {
            let scopes = occurrences(of: scopeAnchor, in: text)
            guard scopes.count == 1 else {
                Issue.record("\(pin.file): the enclosing anchor \(scopeAnchor.debugDescription) must be unique in the file (found \(scopes.count))")
                return nil
            }
            do {
                scope = try bracedBlock(after: scopes[0], in: text)
            } catch {
                Issue.record("\(pin.file): the enclosing anchor \(scopeAnchor.debugDescription) does not open a braced body: \(error)")
                return nil
            }
        }
        let anchors = occurrences(of: pin.anchor, in: text, range: scope)
        guard anchors.count == 1 else {
            Issue.record("\(pin.file): the class anchor \(pin.anchor.debugDescription) must be unique in its scope (found \(anchors.count)); the declaration was renamed, duplicated or moved")
            return nil
        }
        do {
            return try bracedBlock(after: anchors[0], in: text)
        } catch {
            Issue.record("\(pin.file): the class anchor \(pin.anchor.debugDescription) does not open a braced body: \(error)")
            return nil
        }
    }

    // MARK: - Source helpers
    //
    // Deliberately duplicated per pin suite (the #280 pattern): the suites must
    // stay independently revertable, so they share no test-target helper file.

    private static func repositoryRoot() -> URL {
        // Counterfactual hook: the mutation runs point this at a copy of the
        // source with markers mutated. The measured-working form is
        // `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` exported into
        // xcodebuild's own environment (the `TEST_RUNNER_` prefix is consumed by
        // the test runner and forwarded without it).
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("VVTerm.xcodeproj").path
            ) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return url
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// A comment-stripped copy of `source` for the token scans: characters
    /// inside `//` line comments and nested `/* … */` block comments become
    /// spaces; newlines are preserved, so slice anchors still resolve. String
    /// contents are copied verbatim (so a `//` inside a literal is not read as a
    /// comment); the scanner covers `"…"` (with `\` escapes) and `"""…"""`
    /// but not raw strings (`#"…"#`) or comments inside an interpolation.
    private static func strippingComments(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        var blockCommentDepth = 0
        var inLineComment = false
        var stringDelimiter: Int? = nil  // 1 for `"…"`, 3 for `"""…"""`
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    result.append("\n")
                } else {
                    result.append(" ")
                }
                index += 1
                continue
            }
            if blockCommentDepth > 0 {
                if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    blockCommentDepth += 1
                    result.append("  ")
                    index += 2
                } else if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    blockCommentDepth -= 1
                    result.append("  ")
                    index += 2
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index += 1
                }
                continue
            }
            if let delimiter = stringDelimiter {
                result.append(character)
                index += 1
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\" {
                    escaped = true
                    continue
                }
                if delimiter == 1, character == "\"" {
                    stringDelimiter = nil
                    continue
                }
                if delimiter == 3,
                   character == "\"",
                   index + 1 < characters.count,
                   characters[index] == "\"",
                   characters[index + 1] == "\"" {
                    result.append("\"\"")
                    index += 2
                    stringDelimiter = nil
                }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                inLineComment = true
                result.append("  ")
                index += 2
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                blockCommentDepth = 1
                result.append("  ")
                index += 2
                continue
            }
            if character == "\"" {
                if index + 2 < characters.count, characters[index + 1] == "\"", characters[index + 2] == "\"" {
                    stringDelimiter = 3
                    result.append("\"\"\"")
                    index += 3
                } else {
                    stringDelimiter = 1
                    result.append("\"")
                    index += 1
                }
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// Every occurrence of `needle` (optionally within `range`), in source
    /// order, that is not part of a longer identifier. The boundary check is
    /// load-bearing: `final class InlineEditingTextField` is a prefix of
    /// `final class InlineEditingTextFieldCell`, and `isolated deinit {` is a
    /// suffix of `nonisolated deinit {`.
    private static func occurrences(
        of needle: String,
        in text: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        let searchRange = range ?? text.startIndex..<text.endIndex
        var result: [Range<String.Index>] = []
        var searchStart = searchRange.lowerBound
        while let found = text.range(of: needle, range: searchStart..<searchRange.upperBound) {
            let before = found.lowerBound == text.startIndex
                ? nil
                : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex
                ? nil
                : text[found.upperBound]
            let isIdentifierCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
            if !(before.map(isIdentifierCharacter) ?? false),
               !(after.map(isIdentifierCharacter) ?? false) {
                result.append(found)
            }
            searchStart = found.upperBound
        }
        return result
    }

    /// The body span `{ … }` of the brace-delimited block that opens at `open`.
    private static func bracedBlock(
        openingAt open: String.Index,
        in text: String
    ) throws -> Range<String.Index> {
        try #require(text[open] == "{", "the explicit block open must be a `{`")
        var depth = 0
        var close: String.Index?
        var index = open
        while index < text.endIndex, close == nil {
            if text[index] == "{" {
                depth += 1
            } else if text[index] == "}" {
                depth -= 1
                if depth == 0 { close = index }
            }
            index = text.index(after: index)
        }
        let blockClose = try #require(close, "the pin block's braces must balance")
        return text.index(after: open)..<blockClose
    }

    /// The body span of the first brace-delimited block after `anchor`.
    ///
    /// The anchor must be **brace-less** for the intended block to be the one it
    /// opens: `bracedBlock` binds the first `{` after the anchor.
    private static func bracedBlock(
        after anchor: Range<String.Index>,
        in text: String
    ) throws -> Range<String.Index> {
        let open = try #require(
            text[anchor.upperBound...].firstIndex(of: "{"),
            "the pin anchor must be followed by a `{`"
        )
        return try bracedBlock(openingAt: open, in: text)
    }

    /// The brace depth at `index`, counted from the start of `text`.
    private static func braceDepth(at index: String.Index, in text: String) -> Int {
        var depth = 0
        var cursor = text.startIndex
        while cursor < index {
            if text[cursor] == "{" {
                depth += 1
            } else if text[cursor] == "}" {
                depth -= 1
            }
            cursor = text.index(after: cursor)
        }
        return depth
    }

    /// Depth of `range` relative to the class body it lives in: a direct member
    /// of the class sits at 1, a member of a nested declaration at ≥ 2. The
    /// shipped #280 helper is absolute (it counts from `text.startIndex`), which
    /// is wrong for nested classes — hence the subtraction.
    ///
    /// `body` is the range *between* the class's braces, so the depth at
    /// `body.lowerBound` already counts the class's own opening brace; the
    /// `- 1` converts it to the interior reference depth (a direct member of a
    /// top-level class is at absolute depth 1).
    ///
    /// Braces inside string literals are counted (the comment stripper copies
    /// string contents verbatim), so a literal containing an unbalanced `{`
    /// before the marker would skew this; a skewed depth fails the assertion
    /// rather than passing it.
    private static func relativeDepth(
        of range: Range<String.Index>,
        to body: Range<String.Index>,
        in text: String
    ) -> Int {
        braceDepth(at: range.lowerBound, in: text) - braceDepth(at: body.lowerBound, in: text) + 1
    }
}
