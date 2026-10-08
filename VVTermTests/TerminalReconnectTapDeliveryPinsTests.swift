// SPDX-License-Identifier: MIT
//
//  TerminalReconnectTapDeliveryPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #220: `VVTermUITests/TerminalReconnectUITests.swift`
//  no longer passes or fails on the wall-clock duration of a tap. The removed
//  `tapPromptly` asserted `XCTAssertLessThan(Date().timeIntervalSince(...), 10, …)`
//  and reddened on a tap that had delivered while a loaded runner stalled it
//  (18.382 s in the CI instance, 47.159 s on #257) with `sentCount`/
//  `transportSent` advanced and the app healthy. It is replaced by
//  `tapAndAwaitInput`, which taps and bounded-waits
//  (`inputDeliveryBudget = 30 s`) for the delivered-input counter `sentCount`
//  to advance, returning a Bool that every call site consumes (asserted at the
//  three direct sites, fed into the existing retry at the two session sites).
//  Issue #410 adds two asserted receipt waits at the codex-mode sites (A8/A9)
//  and pins the fixture emission map that makes the `z` probe's receipt unique
//  (A10).
//
//    A1  no wall-clock threshold survives: zero `XCTAssertLessThan(` in the
//        file, and exactly one `timeIntervalSince` read — the helper's
//        `elapsed=` triage print (its context carries `elapsed=`). Plan §4.1
//        A1 said "zero `timeIntervalSince` occurrences", but §3.1's helper
//        (lens-1 F3) requires the elapsed diagnostic, so this pin locks the
//        threshold shape, not the bare token. A re-added `tapPromptly` reds
//        both halves (the count becomes two and `XCTAssertLessThan(` returns).
//    A2  zero `tapPromptly` occurrences (a revert to the old helper name is
//        visible).
//    A3  exactly one `inputDeliveryBudget` declaration with literal 30, and
//        the helper's normalized signature keeps the default binding
//        `timeout: TimeInterval = TerminalReconnectUITests.inputDeliveryBudget`
//        (`Self.` is a compile error in a default argument — lens-1 F1; the
//        pin is needed because a bare constant is not enough: the default could
//        silently become a literal).
//    A4  exactly one `private func tapAndAwaitInput(` and the delivery check
//        `now > before`.
//    A5  call-site shapes: exactly three `XCTAssertTrue(tapAndAwaitInput(`
//        and exactly two `delivered = tapAndAwaitInput(` — the declaration is
//        excluded because it is spelled `private func tapAndAwaitInput(`.
//    A6  the four bare taps in `tapCommandArguments` keep their delivery
//        backing: exactly two `containing: enterTarget` waits (the Return
//        key/button path) and the `terminal.typeText("\n")` IME fallback.
//    A7  no `tapAndAwaitInput` call site passes its own `timeout:` — a
//        balanced-paren extraction of every call's argument text (the
//        declaration is excluded by its `private func ` prefix), so a
//        `timeout: 1` site override cannot keep A1-A6 green.
//    A8  the two #410 codex-mode receipt waits assert their returned Bool: a
//        balanced-paren extraction of every `waitForAnyDiagnostics(` call (the
//        `private func` declaration excluded), classified by whether the
//        immediately preceding non-whitespace source ends with
//        `XCTAssertTrue(`; the asserted subset must be exactly 2. The consumed
//        shapes stay pinned too: exactly 2 `delivered && waitForAnyDiagnostics(`
//        and exactly 1 `let markerSeen = waitForAnyDiagnostics(`, plus a
//        total-occurrence scan-consistency check (5 calls + the declaration).
//    A9  both asserted #410 receipt arguments contain `DEV212_INPUT_Z_1` and
//        neither contains `DEV212_INPUT_X_1` — the `:428` probe was changed
//        from the non-unique `x` to `z` (issue #410).
//    A10 the fixture emission map (`scripts/ci/repro-sshd-setup.sh`): the
//        `hello()` definition line emits no `DEV212_INPUT_Z_1`, the
//        `$HOME/bin/z` heredoc block does, and the script-wide occurrence
//        count is exactly 3. An emission that introduces Z_1 before the probe
//        (the re-vacuuming vector) reds A10 (issue #410).
//    A11 the fixture fragment is shell-correct and install-gated
//        (`scripts/ci/repro-sshd-setup.sh`): a zsh variant installs the
//        precmd OSC hook, carries no bash PS1, and uses `${HOST:-}`; the
//        installer picks it for `.zshrc`/`.zprofile`; the bash PS1 survives;
//        the append and the ~/bin helpers sit behind the `INSTALL_RC` gate
//        (CI or `VVTERM_REPRO_RC=1`) (issue #414).
//
//  Scans run over the comment-stripped, whitespace-normalized source: a
//  comment-embedded decoy is not code, and a multi-line call site normalizes
//  to one logical line. FORMATTING HEURISTIC, NOT A PROOF: this file parses
//  Swift as text.
//
//  Honest defeat list:
//    - a differently-spelled wall-clock read (`CFAbsoluteTimeGetCurrent`,
//      `ProcessInfo.systemUptime`) escapes A1's token count; the
//      `XCTAssertLessThan(` half catches it only when the re-added threshold
//      is spelled `XCTAssertLessThan(` — an
//      `XCTAssert(CFAbsoluteTimeGetCurrent() - t0 < 10)` escapes both halves;
//    - a tap-latency assertion in another file is out of scope;
//    - A4 proves the text, not runtime liveness (that is CF-R2);
//    - A7's override detection is an exact `timeout:` substring of the
//      extracted argument text: `timeout : 1` (space before the colon) and a
//      backticked `` `timeout`: 1 `` are compile-valid spellings that escape
//      it while A1-A6 stay green (measured by the closure lens; the repo's
//      formatting emits neither);
//    - A8's classifier counts `XCTAssertTrue(`-preceded calls, so a
//      token-matching but weakened assert
//      (`XCTAssertTrue(waitForAnyDiagnostics(…) || true)`) keeps the count;
//      the `let receipt = …; XCTAssertTrue(receipt)` re-spelling reds A8
//      (the asserted count drops) and is not an escape;
//    - A8-A10 prove text, not runtime liveness (CF-R2/R3/R4 do that);
//    - A10 is a text heuristic over one fixture script, not an oracle — it
//      reds an emission that changes the pinned 3-occurrence map, not every
//      possible re-vacuuming edit;
//    - the find site's probe KEY (`app.keys["z"]`) is not pinned: a partial
//      revert (x probe + the Z_1 assert) passes A8-A10 because the assert
//      arguments are unchanged, and reds only at runtime (shard-2, report-
//      only). The runtime assertion is the guard; this pin only guards the
//      text it pins (measured by the impl lens 2, see the #410 review notes);
//    - the A8/A9 failure-message wording is not pinned: a coherent reword
//      that reintroduces a misleading "never reached the shell" phrasing for
//      the flag-gated `z` branch stays green here (review-only, the impl
//      lens 1 NIT-3);
//    - a coherent edit paired with a pin update is inherent to an
//      update-on-purpose pin;
//    - the retry sites' control flow is text-pinned by A5; CF-R4's literal
//      `key.tap(); return false` mutation reds at the added initial-x assert
//      (:144) before the retry loop can run, so the retry path was covered by
//      a retry-reachable variant (the helper gates delivery on the pre-tap
//      baseline `before == 0`): it executes both retry iterations and reds at
//      the pre-existing `XCTAssertTrue(delivered, …)`. Raw logs and the exact
//      failure text live in `assets/vvterm-issue220-evidence/README.md`.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scan at a
//  mutated tree copy. The variable reaches the test process only as
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT` in xcodebuild's own environment
//  (a plain env var is inert on the simulator destination). Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct TerminalReconnectTapDeliveryPinsTests {

    private static let uiTestsPath = "VVTermUITests/TerminalReconnectUITests.swift"

    /// The normalized helper signature. The `timeout:` default must bind the
    /// named budget, not a literal and not `Self.` (a default-argument
    /// compile error).
    private static let helperSignature =
        "private func tapAndAwaitInput( _ key: XCUIElement, diagnostics: XCUIElement, app: XCUIApplication, timeout: TimeInterval = TerminalReconnectUITests.inputDeliveryBudget ) -> Bool"

    /// A1: the tap-duration threshold is gone. The one permitted
    /// `timeIntervalSince` is the helper's `elapsed=` triage print.
    @Test
    func testA1NoWallClockTapThresholdSurvives() throws {
        let source = try Self.normalizedSource()
        #expect(
            !source.contains("XCTAssertLessThan("),
            "no `XCTAssertLessThan(` may survive in TerminalReconnectUITests.swift: a wall-clock threshold on a tap is what #220 removed — re-derive this pin (issue #220)"
        )
        let occurrences = source.components(separatedBy: "timeIntervalSince").count - 1
        #expect(
            occurrences == 1,
            "exactly one `timeIntervalSince` read may survive — the helper's `elapsed=` triage print; a re-added tap-duration assertion makes it two — found \(occurrences) (issue #220)"
        )
        #expect(
            Self.firstOccurrenceContext(of: "timeIntervalSince", in: source)?.contains("elapsed=") == true,
            "the surviving `timeIntervalSince` must be the helper's `elapsed=` triage print, not a pass/fail threshold (issue #220)"
        )
    }

    /// A2: the old helper name is gone.
    @Test
    func testA2TapPromptlyIsGone() throws {
        let source = try Self.normalizedSource()
        let occurrences = source.components(separatedBy: "tapPromptly").count - 1
        #expect(
            occurrences == 0,
            "`tapPromptly` must not survive in TerminalReconnectUITests.swift — found \(occurrences) (issue #220)"
        )
    }

    /// A3: the budget constant and the helper's default binding are pinned.
    @Test
    func testA3TheBudgetLiteralAndDefaultBindingArePinned() throws {
        let source = try Self.normalizedSource()
        let literals = Self.budgetLiterals(in: source)
        #expect(
            literals == ["30"],
            "`inputDeliveryBudget` must be declared exactly once with the literal 30 (update on purpose: shrinking the budget shrinks the delivered-tap allowance #220 widened) — found \(literals) (issue #220)"
        )
        #expect(
            source.contains(Self.helperSignature),
            "the helper's normalized signature must keep its `timeout: TimeInterval = TerminalReconnectUITests.inputDeliveryBudget` default — expected `\(Self.helperSignature)` (issue #220)"
        )
    }

    /// A4: one helper, with the counter-advance check.
    @Test
    func testA4TheHelperAndItsDeliveryCheckExist() throws {
        let source = try Self.normalizedSource()
        let helperOccurrences = source.components(separatedBy: "private func tapAndAwaitInput(").count - 1
        #expect(
            helperOccurrences == 1,
            "exactly one `private func tapAndAwaitInput(` must exist — found \(helperOccurrences) (issue #220)"
        )
        #expect(
            source.contains("now > before"),
            "the helper must keep the delivered-input check `now > before` (a `return true` would make every tap pass) (issue #220)"
        )
    }

    /// A5: the call-site shapes.
    @Test
    func testA5CallSiteShapesArePinned() throws {
        let source = try Self.normalizedSource()
        let asserted = source.components(separatedBy: "XCTAssertTrue(tapAndAwaitInput(").count - 1
        #expect(
            asserted == 3,
            "exactly three direct sites must assert the returned delivery Bool — found \(asserted) (issue #220)"
        )
        let retried = source.components(separatedBy: "delivered = tapAndAwaitInput(").count - 1
        #expect(
            retried == 2,
            "exactly two retry sites must feed the returned Bool into `delivered` — found \(retried) (issue #220)"
        )
    }

    /// A6: the four bare taps keep their downstream delivery waits.
    @Test
    func testA6BareTapsKeepTheirDeliveryBacking() throws {
        let source = try Self.normalizedSource()
        let enterWaits = source.components(separatedBy: "containing: enterTarget").count - 1
        #expect(
            enterWaits == 2,
            "the Return key/button path must keep its two `containing: enterTarget` waits — found \(enterWaits) (issue #220)"
        )
        #expect(
            source.contains("terminal.typeText(\"\\n\")"),
            "the IME newline fallback `terminal.typeText(\"\\n\")` must remain after the Return key/button taps (issue #220)"
        )
    }

    /// A7: no call site overrides the helper's bounded wait.
    @Test
    func testA7CallSitesDoNotOverrideTheTimeout() throws {
        let source = try Self.normalizedSource()
        let arguments = Self.callArgumentTexts(in: source)
        #expect(
            arguments.count == 5,
            "the balanced-paren scan must cover the five `tapAndAwaitInput(` call sites — found \(arguments.count) (issue #220)"
        )
        let overrides = arguments.filter { $0.contains("timeout:") }
        #expect(
            overrides.isEmpty,
            "no `tapAndAwaitInput` call site may pass its own `timeout:` (the helper's 30 s default is the only bounded-wait authority; A3 pins the declaration, A7 pins the call sites) — overrides: \(overrides) (issue #220)"
        )
    }

    /// A8: the two #410 codex-mode receipt waits assert their returned Bool.
    @Test
    func testA8CodexReceiptWaitsAssertTheirBool() throws {
        let source = try Self.normalizedSource()
        let calls = Self.waitForAnyDiagnosticsCalls(in: source)
        let totalOccurrences = source.components(separatedBy: "waitForAnyDiagnostics(").count - 1
        #expect(
            totalOccurrences == 6,
            "the `waitForAnyDiagnostics(` scan-consistency total must be 5 call sites + the `private func` declaration — found \(totalOccurrences) (issue #220/#410)"
        )
        #expect(
            calls.count == totalOccurrences - 1,
            "the balanced-paren extraction must resolve every non-declaration `waitForAnyDiagnostics(` call — extracted \(calls.count) of \(totalOccurrences - 1) (issue #220/#410)"
        )
        let asserted = calls.filter(\.isAsserted)
        #expect(
            asserted.count == 2,
            "exactly two `waitForAnyDiagnostics(` calls must assert their returned Bool (the two #410 codex-mode receipt waits); an unasserted call or a `let receipt = …; XCTAssertTrue(receipt)` re-spelling reds here — found \(asserted.count) (issue #410)"
        )
        let chained = source.components(separatedBy: "delivered && waitForAnyDiagnostics(").count - 1
        #expect(
            chained == 2,
            "exactly two session retry sites must keep chaining `delivered &&` into the receipt wait — found \(chained) (issue #220)"
        )
        let markerSeen = source.components(separatedBy: "let markerSeen = waitForAnyDiagnostics(").count - 1
        #expect(
            markerSeen == 1,
            "exactly one `enterCodexModes` site must keep consuming the helper result as `let markerSeen = …` — found \(markerSeen) (issue #220)"
        )
    }

    /// A9: the asserted receipts use only the `z`-probe's unique token.
    @Test
    func testA9TheAssertedReceiptsUseTheUniqueZToken() throws {
        let source = try Self.normalizedSource()
        let asserted = Self.waitForAnyDiagnosticsCalls(in: source).filter(\.isAsserted)
        let zTokens = asserted.filter { $0.arguments.contains("DEV212_INPUT_Z_1") }
        #expect(
            zTokens.count == 2,
            "exactly two asserted receipt waits must use the `DEV212_INPUT_Z_1` marker triple (the find probe at `:419` was changed from the non-unique `x` to `z`); the literal keeps A9 non-vacuous if every assert is reverted — arguments: \(asserted.map(\.arguments)) (issue #410)"
        )
        let xTokens = asserted.filter { $0.arguments.contains("DEV212_INPUT_X_1") }
        #expect(
            xTokens.isEmpty,
            "no asserted receipt wait may keep the `DEV212_INPUT_X_1` marker (`hello()` emits it before the probe, so it is not a receipt) — arguments: \(xTokens.map(\.arguments)) (issue #410)"
        )
    }

    /// A10: the fixture emits `DEV212_INPUT_Z_1` only from the probe command.
    @Test
    func testA10TheFixtureEmitsZOnlyFromTheProbe() throws {
        let script = try Self.source("scripts/ci/repro-sshd-setup.sh")
        let helloLines = script.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.contains("hello() {") }
        #expect(
            helloLines.count == 1,
            "the fixture must define `hello()` on exactly one line — found \(helloLines.count) (issue #410)"
        )
        #expect(
            helloLines.allSatisfy { !$0.contains("DEV212_INPUT_Z_1") },
            "the `hello()` definition must not emit `DEV212_INPUT_Z_1` — it runs before the probe and any emission here re-vacuums the receipt (issue #410)"
        )
        let zHeredocStart = script.range(of: #"cat > "$HOME/bin/z" <<'ZEOF'"#)
        #expect(
            zHeredocStart != nil,
            "the fixture must keep the `$HOME/bin/z` heredoc (the `z` probe's codex branch) (issue #410)"
        )
        if let zHeredocStart {
            let tail = script[zHeredocStart.upperBound...]
            let zHeredocEnd = tail.range(of: "\nZEOF")
            #expect(
                zHeredocEnd != nil,
                "the `$HOME/bin/z` heredoc must terminate with a bare `ZEOF` line (issue #410)"
            )
            if let zHeredocEnd {
                let block = tail[..<zHeredocEnd.lowerBound]
                #expect(
                    block.contains("DEV212_INPUT_Z_1"),
                    "the `$HOME/bin/z` codex branch must emit `DEV212_INPUT_Z_1` — that emission is the probe's unique receipt (issue #410)"
                )
            }
        }
        let total = script.components(separatedBy: "DEV212_INPUT_Z_1").count - 1
        #expect(
            total == 3,
            "the fixture's `DEV212_INPUT_Z_1` emission map must stay exactly the mkdir, the codex cd and the codex OSC 0 title (3 occurrences) — found \(total); update on purpose if the fixture gains a Z_1 emission (issue #410)"
        )
    }

    /// A11: the repro-rig fragment is shell-correct and install-gated. zsh
    /// prints bash's PS1 `\[ \] \e \a` escapes literally (no OSC), so
    /// `.zshrc`/`.zprofile` get a precmd hook instead; off CI the install is
    /// opt-in (`VVTERM_REPRO_RC=1`) so it cannot silently append to real
    /// dotfiles (issue #414).
    @Test
    func testA11ReproRigFragmentIsShellCorrectAndGated() throws {
        let script = try Self.source("scripts/ci/repro-sshd-setup.sh")
        let zshMarker = "TITLE_FRAGMENT_ZSH+=\"$(cat <<'ZSH'"
        let zshStart = script.range(of: zshMarker)
        #expect(
            zshStart != nil,
            "the fixture must define a zsh fragment variant (`TITLE_FRAGMENT_ZSH`) — appending the bash PS1 to .zshrc renders it literally and emits no OSC (issue #414)"
        )
        if let zshStart {
            let tail = script[zshStart.upperBound...]
            let zshEnd = tail.range(of: "\nZSH")
            #expect(
                zshEnd != nil,
                "the zsh fragment heredoc must terminate with a bare `ZSH` line — re-derive this pin (issue #414)"
            )
            if let zshEnd {
                let zshFragment = tail[..<zshEnd.lowerBound]
                #expect(
                    zshFragment.contains("add-zsh-hook precmd _vvterm_repro_osc"),
                    "the zsh fragment must install the precmd OSC hook — zsh ignores bash PS1 escapes (issue #414)"
                )
                #expect(
                    !zshFragment.contains("PS1="),
                    "the zsh fragment must not carry the bash PS1 line — zsh prints `\\[ \\e \\a` literally (issue #414)"
                )
                #expect(
                    zshFragment.contains("${HOST:-}"),
                    "the zsh fragment must use zsh's `HOST` (bash's `HOSTNAME` is empty in zsh) (issue #414)"
                )
            }
        }
        #expect(
            script.contains(#"PS1=\"\[\e]0;DEV199_READY_1\a\]"#),
            "the bash fragment must keep its PS1 OSC marker byte-for-byte — the CI runner's login shell is bash (issue #414)"
        )
        #expect(
            script.contains("*.zshrc|*.zprofile) FRAGMENT=\"$TITLE_FRAGMENT_ZSH\""),
            "the installer must pick the zsh fragment for .zshrc/.zprofile and the bash fragment for the other rc files (issue #414)"
        )
        let gates = script.components(separatedBy: "if [ \"$INSTALL_RC\" -eq 1 ]; then").count - 1
        #expect(
            gates == 2,
            "both the fragment append and the ~/bin helper writes must sit behind the INSTALL_RC gate (CI or VVTERM_REPRO_RC=1) — found \(gates) (issue #414)"
        )
        #expect(
            script.contains("VVTERM_REPRO_RC"),
            "the install must be opt-in off CI (`VVTERM_REPRO_RC=1`) so a local run cannot silently modify real dotfiles (issue #414)"
        )
    }

    // MARK: - Source helpers

    /// The argument text of every `tapAndAwaitInput(` call site — the
    /// declaration is excluded by its `private func ` prefix — extracted with
    /// a balanced-paren scan over the whitespace-normalized source. The
    /// comment stripper copies string contents verbatim, so an unbalanced
    /// paren inside a literal would mis-slice; that is the same text-parser
    /// heuristic class the header names.
    private static func callArgumentTexts(in source: String) -> [String] {
        let token = "tapAndAwaitInput("
        var sites: [String] = []
        var searchStart = source.startIndex
        while let range = source.range(of: token, range: searchStart..<source.endIndex) {
            searchStart = range.upperBound
            if source[..<range.lowerBound].hasSuffix("private func ") { continue }
            var depth = 1
            var index = range.upperBound
            while index < source.endIndex, depth > 0 {
                let character = source[index]
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                }
                if depth == 0 { break }
                index = source.index(after: index)
            }
            guard depth == 0 else { continue }
            sites.append(String(source[range.upperBound..<index]))
        }
        return sites
    }

    /// A8/A9's balanced-paren extraction of every `waitForAnyDiagnostics(`
    /// call (the `private func` declaration is excluded by its `private func `
    /// prefix), each classified by whether the immediately preceding
    /// non-whitespace source ends with `XCTAssertTrue(`.
    private struct WaitCall {
        let arguments: String
        let isAsserted: Bool
    }

    private static func waitForAnyDiagnosticsCalls(in source: String) -> [WaitCall] {
        let token = "waitForAnyDiagnostics("
        var calls: [WaitCall] = []
        var searchStart = source.startIndex
        while let range = source.range(of: token, range: searchStart..<source.endIndex) {
            searchStart = range.upperBound
            if source[..<range.lowerBound].hasSuffix("private func ") { continue }
            var depth = 1
            var index = range.upperBound
            while index < source.endIndex, depth > 0 {
                let character = source[index]
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                }
                if depth == 0 { break }
                index = source.index(after: index)
            }
            guard depth == 0 else { continue }
            var prefix = source[..<range.lowerBound]
            while let last = prefix.last, last.isWhitespace {
                prefix = prefix.dropLast()
            }
            calls.append(WaitCall(
                arguments: String(source[range.upperBound..<index]),
                isAsserted: prefix.hasSuffix("XCTAssertTrue(")
            ))
        }
        return calls
    }

    /// The window around the first occurrence of `token` (for the elapsed-print
    /// context assertion).
    private static func firstOccurrenceContext(of token: String, in source: String) -> String? {
        guard let range = source.range(of: token) else { return nil }
        let start = source.index(range.lowerBound, offsetBy: -200, limitedBy: source.startIndex)
            ?? source.startIndex
        return String(source[start..<range.upperBound])
    }

    /// Every `inputDeliveryBudget` declaration literal, in file order.
    private static func budgetLiterals(in source: String) -> [String] {
        let pattern = #"static let inputDeliveryBudget: TimeInterval = ([0-9.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    private static func normalizedSource() throws -> String {
        let stripped = Self.strippingComments(try Self.source(Self.uiTestsPath))
        return stripped.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = try repositoryRoot().appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PinFailure("could not read \(relativePath) at \(url.path): \(error)")
        }
    }

    private static func repositoryRoot() throws -> URL {
        // Counterfactual hook: the mutation runs point this at a copy of the
        // source with the UI test file mutated. The measured-working form is
        // `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` exported into
        // xcodebuild's own environment (the `TEST_RUNNER_` prefix is consumed
        // by the test runner and forwarded without it).
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
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
        throw PinFailure(
            "could not locate the repository root (no VVTerm.xcodeproj above \(#filePath)) — re-derive this pin"
        )
    }

    /// A comment-stripped copy of `source`: characters inside `//` line
    /// comments and nested `/* … */` block comments become spaces; newlines
    /// are preserved, so slice anchors still resolve. String contents are
    /// copied verbatim. Duplicated from the merged pin suites so each family's
    /// pin file is self-contained and reverts independently.
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

    private struct PinFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }
    }
}
