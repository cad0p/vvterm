// SPDX-License-Identifier: MIT
//
//  TerminalSessionsIsolatedDeinitPinsTests.swift
//  VVTermTests
//
//  CI-visible source pins for the #294 sweep (VVTerm/Features/TerminalSessions).
//
//  A MainActor-isolated class with no explicit `deinit` gets a
//  compiler-synthesized *isolated* deinit (`__isolated_deallocating_deinit`,
//  mangled `…CfZ`). Releasing such an object outside a Swift task context takes
//  the back-deployed MainActor deinit path and aborts in libmalloc (`pointer
//  being freed was not allocated`) — swiftlang/swift#85663, #88036. The sweep
//  adds the repo's standard empty marker (`nonisolated deinit {}`) to every such
//  class in VVTerm/Features/TerminalSessions; these pins keep it there. The one
//  converged exception is `TerminalKeyboardCoordinator`: #308 gave it a real
//  `nonisolated deinit` body (observer teardown + verification-task cancel), so
//  it is pinned by the dedicated body tests at the end of this file instead of
//  the exact-marker table.
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

struct TerminalSessionsIsolatedDeinitPinsTests {

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
        Pin(file: "VVTerm/Features/TerminalSessions/Application/EternalTerminalRuntime.swift", anchor: "final class EternalTerminalRuntime", control: "let paneId: UUID"),
        Pin(file: "VVTerm/Features/TerminalSessions/Application/LiveActivityManager.swift", anchor: "final class LiveActivityManager", control: "static let shared"),
        Pin(file: "VVTerm/Features/TerminalSessions/Application/TerminalScreenAwakeCoordinator+iOS.swift", anchor: "final class TerminalScreenAwakeCoordinator", control: "private var requestingRouteIDs"),
        Pin(file: "VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift", anchor: "final class TerminalTabManager", control: "static let shared"),
        Pin(file: "VVTerm/Features/TerminalSessions/Application/TerminalTransportWriteQueue.swift", anchor: "final class TerminalTransportWriteQueue", control: "private var pendingWrite"),
        Pin(file: "VVTerm/Features/TerminalSessions/Application/TmuxAttachResolver.swift", anchor: "final class TmuxAttachResolver", control: "var sessionNames"),
        Pin(file: "VVTerm/Features/TerminalSessions/Infrastructure/MoshResumeStore.swift", anchor: "final class MoshResumeStore", control: "static let shared"),
        Pin(file: "VVTerm/Features/TerminalSessions/UI/Splits/TerminalView+iOS.swift", anchor: "private final class TerminalKeyboardAvoidanceViewModel", control: "private weak var terminal"),
        Pin(file: "VVTerm/Features/TerminalSessions/UI/Terminal/TerminalCloseConfirmation+iOS.swift", anchor: "private final class TerminalCloseAlertHostController", control: "private var request"),
        Pin(file: "VVTerm/Features/TerminalSessions/UI/Terminal/TerminalPaneConnectionCoordinator.swift", anchor: "final class TerminalPaneConnectionCoordinator", control: "private let backend"),
        Pin(file: "VVTerm/Features/TerminalSessions/UI/Terminal/TerminalPaneConnectionCoordinator.swift", anchor: "private final class EternalTerminalPaneCoordinator", control: "let paneId"),
        Pin(file: "VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift", anchor: "final class TerminalRichPasteRuntime", control: "let sessionId"),
    ]

    /// The sweep's file census: one entry per swept file, `count` = the number
    /// of pinned classes in that file. The completeness test below asserts the
    /// pins table and this census agree — and that each file actually carries
    /// exactly that many `nonisolated deinit {}` tokens — so a dropped row plus
    /// the matching dropped marker is red even in a single-pin file.
    private static let markerCountsPerFile: [(file: String, count: Int)] = [
        (file: "VVTerm/Features/TerminalSessions/Application/EternalTerminalRuntime.swift", count: 1),
        (file: "VVTerm/Features/TerminalSessions/Application/LiveActivityManager.swift", count: 1),
        (file: "VVTerm/Features/TerminalSessions/Application/TerminalScreenAwakeCoordinator+iOS.swift", count: 1),
        (file: "VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift", count: 1),
        (file: "VVTerm/Features/TerminalSessions/Application/TerminalTransportWriteQueue.swift", count: 1),
        (file: "VVTerm/Features/TerminalSessions/Application/TmuxAttachResolver.swift", count: 1),
        (file: "VVTerm/Features/TerminalSessions/Infrastructure/MoshResumeStore.swift", count: 1),
        (file: "VVTerm/Features/TerminalSessions/UI/Splits/TerminalView+iOS.swift", count: 1),
        (file: "VVTerm/Features/TerminalSessions/UI/Terminal/TerminalCloseConfirmation+iOS.swift", count: 1),
        (file: "VVTerm/Features/TerminalSessions/UI/Terminal/TerminalPaneConnectionCoordinator.swift", count: 2),
        (file: "VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift", count: 1),
    ]

    // MARK: - Tests

    /// Table completeness: every other test in this suite iterates `Self.pins`,
    /// so an emptied or shortened table would be silently vacuous. 12
    /// is the exact-marker table's recorded class count for this area (one
    /// marker per class; the #308-converged `TerminalKeyboardCoordinator` is
    /// pinned by the body tests below instead).
    @Test
    func testTerminalSessionsPinTableIsComplete() {
        #expect(
            Self.pins.count == 12,
            "the TerminalSessions pin table must stay complete: expected 12 rows, found \(Self.pins.count)"
        )
    }

    @Test
    func testTerminalSessionsClassesCarryExactlyOneNonisolatedDeinit() {
        for pin in Self.pins {
            Self.checkPin(pin)
        }
    }

    @Test
    func testTerminalSessionsPinAnchorsResolveUniquely() {
        for pin in Self.pins {
            Self.checkAnchorResolution(pin)
        }
    }

    @Test
    func testTerminalSessionsSweptFilesCarryTheExpectedMarkerCount() {
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

    // MARK: - #308 convergence pins (TerminalKeyboardCoordinator)

    /// `TerminalKeyboardCoordinator` is the class #308 converged: it used to
    /// carry the sweep's exact `nonisolated deinit {}` marker, and now carries a
    /// `nonisolated deinit` with a real body (remove every keyboard-observer
    /// token, then cancel the pending presentation-verification task). The three
    /// tests below pin the converged shape from independent angles: a reversion
    /// to the empty marker reds 1 and 2; a body collapse reds 2; a dropped
    /// observer removal or a dropped task cancel reds 3. The file is
    /// deliberately no longer in the exact-marker table above (a body is
    /// invisible to that spelling), so these tests are its only pins.
    private static let keyboardCoordinatorFile = "VVTerm/Features/TerminalSessions/Application/TerminalKeyboardCoordinator.swift"

    /// The comment-stripped source of `file`, or `nil` after recording why it
    /// could not be read.
    private static func commentStrippedSource(of file: String) -> String? {
        do {
            return try strippingComments(source(file))
        } catch {
            Issue.record("\(file): cannot read the pinned source file: \(error)")
            return nil
        }
    }

    /// The resolved body of the class declared at `anchor`, or `nil` after
    /// recording why it did not resolve. The body contains nested types, so
    /// callers must use `relativeDepth` for member-level assertions.
    private static func classBody(
        anchor: String,
        in text: String,
        file: String
    ) -> Range<String.Index>? {
        let anchors = occurrences(of: anchor, in: text)
        guard anchors.count == 1 else {
            Issue.record("\(file): the `\(anchor)` anchor must be unique (found \(anchors.count)); the declaration was renamed, duplicated or moved")
            return nil
        }
        do {
            return try bracedBlock(after: anchors[0], in: text)
        } catch {
            Issue.record("\(file): the `\(anchor)` anchor does not open a braced body: \(error)")
            return nil
        }
    }

    /// The comment-stripped coordinator source, or `nil` after recording why it
    /// could not be read.
    private static func keyboardCoordinatorSource() -> String? {
        commentStrippedSource(of: keyboardCoordinatorFile)
    }

    /// The coordinator's resolved class body behind the suite's mandatory
    /// positive control, or `nil` after recording why it did not resolve. Every
    /// converged-shape test calls this, so a mis-resolved span fails loudly
    /// instead of passing by accident.
    private static func checkedKeyboardCoordinatorBody(in text: String) -> Range<String.Index>? {
        guard let body = classBody(
            anchor: "final class TerminalKeyboardCoordinator",
            in: text,
            file: keyboardCoordinatorFile
        ) else { return nil }
        let controls = occurrences(of: "var isSoftwareKeyboardVisible", in: text, range: body)
        #expect(
            controls.count == 1,
            "\(keyboardCoordinatorFile): the positive control `var isSoftwareKeyboardVisible` must occur exactly once in the resolved class body (found \(controls.count))"
        )
        guard controls.count == 1 else { return nil }
        return body
    }

    /// The unique class-member `nonisolated deinit` token in the resolved
    /// coordinator body, or `nil` after recording why it did not resolve.
    private static func nonisolatedDeinitToken(
        in text: String,
        classBody: Range<String.Index>
    ) -> Range<String.Index>? {
        let tokens = occurrences(of: "nonisolated deinit", in: text, range: classBody)
            .filter { relativeDepth(of: $0, to: classBody, in: text) == 1 }
        guard tokens.count == 1 else {
            Issue.record("\(keyboardCoordinatorFile): the class-member `nonisolated deinit` token must be unique to pin its body (found \(tokens.count))")
            return nil
        }
        return tokens[0]
    }

    /// The body of the unique class-member `nonisolated deinit`, or `nil` after
    /// recording why it did not resolve.
    private static func nonisolatedDeinitBody(
        in text: String,
        classBody: Range<String.Index>
    ) -> Range<String.Index>? {
        guard let token = nonisolatedDeinitToken(in: text, classBody: classBody) else { return nil }
        guard let body = try? bracedBlock(after: token, in: text) else {
            Issue.record("\(keyboardCoordinatorFile): the class-member `nonisolated deinit` must open a braced body")
            return nil
        }
        return body
    }

    /// 1 of 3 — exactly one `nonisolated deinit` at class-member depth, behind
    /// the positive control. The exact-marker table above deliberately does not
    /// see this body-bearing spelling.
    @Test
    func testTerminalKeyboardCoordinatorCarriesExactlyOneNonisolatedDeinit() {
        guard let text = Self.keyboardCoordinatorSource() else { return }
        guard let body = Self.checkedKeyboardCoordinatorBody(in: text) else { return }
        let tokens = Self.occurrences(of: "nonisolated deinit", in: text, range: body)
            .filter { Self.relativeDepth(of: $0, to: body, in: text) == 1 }
        #expect(
            tokens.count == 1,
            "\(Self.keyboardCoordinatorFile): TerminalKeyboardCoordinator must carry exactly one `nonisolated deinit` at class-member depth (found \(tokens.count)); #308 converged it off the exact `nonisolated deinit {}` marker"
        )
    }

    /// 2 of 3 — the converged deinit body survives: the token is followed by a
    /// real braced body, so a future #294-style collapse back to
    /// `nonisolated deinit {}` reds here.
    @Test
    func testTerminalKeyboardCoordinatorDeinitBodySurvives() {
        guard let text = Self.keyboardCoordinatorSource() else { return }
        guard let body = Self.checkedKeyboardCoordinatorBody(in: text) else { return }
        guard let token = Self.nonisolatedDeinitToken(in: text, classBody: body) else { return }
        let afterToken = text[token.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" }
        #expect(
            afterToken.first == "{",
            "\(Self.keyboardCoordinatorFile): `nonisolated deinit` must be followed by a body, not by `;` or another declaration"
        )
        guard afterToken.first == "{", let deinitBody = try? Self.bracedBlock(after: token, in: text) else { return }
        #expect(
            !text[deinitBody].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(Self.keyboardCoordinatorFile): the converged `nonisolated deinit` body must not be empty; #308 keeps nonisolated teardown here"
        )
    }

    /// 3 of 3 — every obligation the class body creates is unwound by the
    /// deinit. The expected token set is derived from the registration sites,
    /// not hardcoded, and the three-site count keeps the derivation honest; the
    /// array binding plus the literal in-block removal excludes
    /// `keyboardObservers = nil` / `_ = keyboardObservers`. The
    /// five-registration cardinality is deliberately not encoded here — the
    /// runtime test (`TerminalKeyboardCoordinatorObserverTeardownTests`) owns it.
    ///
    /// Measured limits (tripwire, not proof): an `if false`/`#if false`-guarded
    /// removal and a removal inside a string literal stay green, and a
    /// registration added in an extension or another file is invisible to the
    /// class-body scan. An in-class *extra* registration reds the site count,
    /// but a *replacement* of one `.append(…)` with a direct assignment
    /// (`keyboardObservers = [addObserver(…)]`) keeps the site count at three
    /// and stays green here — the runtime suite's `count == 5` control catches
    /// that one, because the overwritten token leaves the array.
    @Test
    func testTerminalKeyboardCoordinatorDeinitRemovesEveryRegisteredObserver() {
        guard let text = Self.keyboardCoordinatorSource() else { return }
        guard let body = Self.checkedKeyboardCoordinatorBody(in: text) else { return }
        guard let deinitBody = Self.nonisolatedDeinitBody(in: text, classBody: body) else { return }

        let registrations = Self.notificationObserverRegistrations(in: body, text: text, file: Self.keyboardCoordinatorFile)
        #expect(
            registrations.count == 3,
            "\(Self.keyboardCoordinatorFile): the class body must carry exactly three traceable `addObserver` registration sites (found \(registrations.count)); the derivation is written against that measured set"
        )
        let tokens = Self.uniqueTokens(of: registrations)
        #expect(
            tokens == ["keyboardObservers"],
            "\(Self.keyboardCoordinatorFile): the `addObserver` sites must derive exactly the stored array token `keyboardObservers` (derived: \(tokens))"
        )

        let removals = Self.occurrences(of: "NotificationCenter.default.removeObserver", in: text, range: deinitBody)
        #expect(
            removals.count == tokens.count,
            "\(Self.keyboardCoordinatorFile): the deinit must remove exactly the registered tokens (derived tokens \(tokens.count), removals \(removals.count)): \(tokens)"
        )
        for token in tokens {
            Self.assertObserverTokenIsRemovedByBinding(token, in: deinitBody, text: text, file: Self.keyboardCoordinatorFile)
        }

        // The second resource: a pending verification task retains the terminal
        // it captured across its 1 s sleep, so the deinit must cancel it too.
        // One linked spelling, not two independent substrings: `contains("presentationVerifyTask")`
        // plus `contains(".cancel()")` also accepts `presentationVerifyTask = nil`
        // followed by an unrelated cancel (measured GREEN), which defeats the
        // task half of the fix while every test stays green.
        let normalized = Self.whitespaceNormalized(text[deinitBody])
        #expect(
            normalized.contains("presentationVerifyTask?.cancel()"),
            "\(Self.keyboardCoordinatorFile): the deinit body must cancel the stored `presentationVerifyTask` (`presentationVerifyTask?.cancel()`); a pending verification task retains the terminal it captured across its 1 s sleep past the coordinator's life"
        )
    }

    // MARK: - #308 obligation-derivation helpers

    /// A `NotificationCenter.addObserver` registration site inside the
    /// coordinator's class body, with the stored token the site feeds.
    private struct ObserverRegistration {
        let token: String
        let site: Range<String.Index>
    }

    /// Every `addObserver` registration site in the class body, with the token
    /// derived from the statement shape it feeds: `<token> = … addObserver(…)`
    /// or `<token>.append(… addObserver(…)…)`.
    ///
    /// The needle is `addObserver`, not `addObserver(`: the boundary-aware
    /// matcher checks the character after the match, and `addObserver(forName:`
    /// leaves an identifier character (`f`) there — measured 1 of 3 sites with
    /// the longer needle, 3 of 3 with the shorter one. A registration that
    /// cannot be traced is recorded as an issue rather than skipped, so the pin
    /// cannot go green by losing coverage.
    private static func notificationObserverRegistrations(
        in body: Range<String.Index>,
        text: String,
        file: String
    ) -> [ObserverRegistration] {
        var registrations: [ObserverRegistration] = []
        for site in occurrences(of: "addObserver", in: text, range: body) {
            guard let token = registrationToken(before: site, in: text, lowerBound: body.lowerBound) else {
                Issue.record("\(file): the `addObserver` site must be traceable to a stored token (`token = … addObserver(…)` / `token.append(… addObserver(…)…)`); extend the observer-teardown derivation to cover this shape")
                continue
            }
            registrations.append(ObserverRegistration(token: token, site: site))
        }
        return registrations
    }

    /// The derived tokens in first-registration order, with repeated appends to
    /// the same array token (`keyboardObservers` for all three sites) collapsed
    /// into one obligation.
    private static func uniqueTokens(of registrations: [ObserverRegistration]) -> [String] {
        var seen = Set<String>()
        return registrations.map(\.token).filter { seen.insert($0).inserted }
    }

    /// The stored property a registration site assigns to, or `nil` when the
    /// preceding statement matches neither the direct assignment nor the array
    /// append shape. The backward scan stops at the nearest statement/block
    /// boundary so an unrelated `=` earlier in the function cannot be borrowed.
    private static func registrationToken(
        before site: Range<String.Index>,
        in text: String,
        lowerBound: String.Index
    ) -> String? {
        var index = site.lowerBound
        while index > lowerBound {
            let previous = text.index(before: index)
            let character = text[previous]
            if character == "{" || character == "}" || character == ";" {
                return nil
            }
            if character == "=" {
                if previous > lowerBound {
                    let beforeAssignment = text.index(before: previous)
                    if "=!<>+-*/%&|^".contains(text[beforeAssignment]) { return nil }
                }
                let afterAssignment = text.index(after: previous)
                if afterAssignment < site.lowerBound, text[afterAssignment] == "=" { return nil }
                return identifier(before: previous, in: text, lowerBound: lowerBound)
            }
            if character == "(" {
                let head = text[lowerBound..<previous]
                guard head.hasSuffix(".append") else { return nil }
                let receiverEnd = head.index(head.endIndex, offsetBy: -".append".count)
                return identifier(before: receiverEnd, in: text, lowerBound: lowerBound)
            }
            index = previous
        }
        return nil
    }

    /// The identifier ending immediately before `index` (exclusive), after
    /// skipping the whitespace between the identifier and its separator
    /// (`token = …` / `token.append(…`). `nil` when there is none.
    private static func identifier(
        before index: String.Index,
        in text: String,
        lowerBound: String.Index
    ) -> String? {
        var cursor = index
        while cursor > lowerBound {
            let previous = text.index(before: cursor)
            let character = text[previous]
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                cursor = previous
            } else {
                break
            }
        }
        let identifierEnd = cursor
        while cursor > lowerBound {
            let previous = text.index(before: cursor)
            let character = text[previous]
            if character.isLetter || character.isNumber || character == "_" {
                cursor = previous
            } else {
                break
            }
        }
        guard cursor < identifierEnd else { return nil }
        return String(text[cursor..<identifierEnd])
    }

    /// A token is removed only when the deinit binds it and removes the bound
    /// observer inside the binding's block. Identifier-preserving shapes
    /// (`token = nil`, `_ = token`) and non-removing calls are rejected
    /// explicitly, so the failure names the leak rather than only the missing
    /// binding. The required idiom is
    /// `for observer in <token> { NotificationCenter.default.removeObserver(observer) }`
    /// (or the `if let observer = <token>` form for a single token); the
    /// in-block `removeObserver(observer)` match is literal, so a multi-line
    /// call also reds conservatively.
    private static func assertObserverTokenIsRemovedByBinding(
        _ token: String,
        in deinitBody: Range<String.Index>,
        text: String,
        file: String
    ) {
        let ifLet = occurrences(of: "if let observer = \(token)", in: text, range: deinitBody)
            + occurrences(of: "if let observer = self.\(token)", in: text, range: deinitBody)
        let forIn = occurrences(of: "for observer in \(token)", in: text, range: deinitBody)
            + occurrences(of: "for observer in self.\(token)", in: text, range: deinitBody)
        let bindings = (ifLet + forIn).sorted { $0.lowerBound < $1.lowerBound }
        #expect(
            bindings.count == 1,
            "\(file): the deinit must remove `\(token)` as `for observer in \(token) { NotificationCenter.default.removeObserver(observer) }` (the single-token form is `if let observer = \(token) { … }`) — found \(bindings.count); the check is deliberately conservative about equivalent spellings, and `\(token) = nil` / `_ = \(token)` still leaks the registration"
        )
        // The binding must iterate the whole stored collection: require the next
        // non-whitespace character to open the loop body (`{`). Without this, a
        // partial-iteration spelling keeps the bare-token match and stays green —
        // measured GREEN for `.prefix(3)`, `.dropLast()`, `[0..<2]`, `where`, and
        // `if let observer = \(token).first`, each of which leaves registrations
        // installed. The runtime suite's `count == 5` control is the behavioural
        // backstop; this is the static one.
        if let binding = bindings.first {
            let nextNonWhitespace = text[binding.upperBound...].first { !$0.isWhitespace }
            #expect(
                nextNonWhitespace == "{",
                "\(file): the `\(token)` binding must iterate the whole stored collection — expected `{` immediately after `\(token)`, found \(nextNonWhitespace.map(String.init) ?? "end of body"); a partial iteration (`.prefix(…)`, `[0..<n]`, `.first`, `where`) leaves registrations installed"
            )
        }
        #expect(
            occurrences(of: "\(token) = nil", in: text, range: deinitBody).isEmpty
                && occurrences(of: "_ = \(token)", in: text, range: deinitBody).isEmpty,
            "\(file): the deinit must not merely drop the `\(token)` reference (`= nil` / `_ =`) — the NotificationCenter registration must be removed"
        )
        guard bindings.count == 1, let binding = bindings.first else { return }
        guard let bindingBody = try? bracedBlock(after: binding, in: text) else {
            Issue.record("\(file): the `\(token)` binding must open a braced block that removes the observer")
            return
        }
        let removals = occurrences(of: "removeObserver(observer)", in: text, range: bindingBody)
        #expect(
            removals.count == 1,
            "\(file): the `\(token)` binding block must call `removeObserver(observer)` exactly once (found \(removals.count)); a removal call that does not use the bound observer leaves this registration in NotificationCenter"
        )
    }

    /// The body text with every whitespace run collapsed to a single space, so
    /// a call can be matched without depending on how it wraps across lines.
    private static func whitespaceNormalized(_ text: Substring) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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
