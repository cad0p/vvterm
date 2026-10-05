// SPDX-License-Identifier: MIT
//
//  WorkflowShardSplitPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #248: the 4-bin UI-test shard assignment in
//  `.github/workflows/vvterm-pr-ci.yml` must partition the recorded method
//  universe exactly once, every listed method must still resolve to a real
//  `func` in the class it names, the #227 atomic pair must stay co-located,
//  and the recorded per-bin median sums must still match the fixture that
//  documents where they came from. The fixture is
//  `scripts/ci/shard-split-medians.json`: the 88 per-method medians over the
//  41-run qualifying population plus the #277 CI-calibration medians and the
//  four #364 CI-calibrated medians, with provenance. Without this pin, a list
//  that silently drops a method, names a method that no longer exists, splits
//  the #227 pair, or drifts away from the recorded fixture is invisible —
//  the workflow is prose the compiler cannot check.
//
//  Issue #362 extends the pin to the DECLARED-TEST ALLOWLIST: every
//  `func test…(` declared in the target's `VVTermUITests/` sources must
//  appear in exactly one shard `only-testing` list or in the reasoned
//  exemption ledger at `scripts/ci/ui-test-allowlist.json` (assertions 7-8).
//  The ledger is a CLOSED record of pre-existing never-scheduled debt: new
//  tests must be scheduled; a new exemption requires an in-code `XCTSkip`
//  with a live tracker. A category is a REASON CLASS, not a verified
//  mechanism — only `platformGated` is cross-checked against the
//  declaration's gate — and the ledger is authoritative over in-code
//  `XCTSkip` strings, which are historical provenance.
//
//  PRECISION CONTRACT (lens 2 P1 / lens 1 F6 / closure F10). The fixture
//  stores the per-method medians at 3 dp. The pin computes each bin sum from
//  those values at FULL precision and asserts the NAMED 1 dp rounding rule:
//  `(sum * 10).rounded() / 10` equals the recorded literals
//  611.0 / 612.9 / 681.7 / 615.7. The exact sums are
//  610.956 / 612.882 / 681.724 / 615.662 s, so the |sum − literal| deltas are
//  0.044 / 0.018 / 0.024 / 0.038 — small but non-zero, recorded here so a
//  future refresh sees the margin instead of re-deriving it. A sum that moves
//  by more than 0.05 s from its literal is red (the tolerance is deliberately
//  wider than the current deltas so a calibration refresh has room, and
//  deliberately narrower than any real method move).
//
//  THIS IS THE FIFTH COPY of the workflow-pin idiom (`repositoryRoot()`
//  honouring `VVTERM_PINS_SOURCE_ROOT`, YAML comment stripping) — after
//  `WorkflowArtifactDependencyPinsTests`,
//  `WorkflowArtifactDependencyClassGatePinsTests`,
//  `WorkflowXcodebuildFlagPinsTests` and `WorkflowPerPREventGatePinsTests`.
//  `WorkflowArtifactDependencyClassGatePinsTests`'s header says a fifth pin
//  file justifies extracting a shared helper. This PR DELIBERATELY DEFERS
//  that extraction: the new pin needs a `matrix.shard` block slicer that the
//  other four do not share, and this PR is a record refresh (no behaviour
//  change), so a refactor of four pin suites would be an unrelated risk. The
//  #362 allowlist extension defers it a SECOND time: the declaration scanner
//  is scanner-local by design (hash-prefix-aware string blanking, `#if`
//  polarity), and extraction would still span the five Swift pin suites, plus
//  the ledger schema/loader. Re-evaluate when this
//  file passes ~1500 lines (the ClassGate pin is the 1416-line precedent).
//  Any parser/comment-strip fix for the shared idiom must be applied to all
//  five files until the extraction lands.
//
//  REFRESH PATH (adding, removing or renaming any declared UI test). A PR
//  that changes the declared-test set must, in the SAME PR, do ONE of:
//  (a) schedule the method in a shard — updating
//  `scripts/ci/shard-split-medians.json` (adding the method's 3 dp median and
//  a provenance run), the four 1 dp sum literals plus the exact sums below,
//  and the workflow comment above `matrix.shard` — or (b) record/update a
//  reasoned exemption row in `scripts/ci/ui-test-allowlist.json` (with a live
//  tracker where the category requires one) and refresh the
//  declared/exempt/per-category counts below. A new method's median comes
//  from a calibration measurement. When it is SEEDED from a dispatch sample
//  (no attempt-1 PR run has executed it yet), record the seed in
//  `_provenance.calibration.basis` and leave `_provenance.runs` untouched
//  (its population rule is attempt-1 `pull_request` runs); the first green
//  attempt-1 run after the change then replaces the seeds, appends its run
//  id to `_provenance.runs`, and records the superseded seed under
//  `calibration.superseded`. Removals are
//  additionally caught by the literal 95-method count and the per-class
//  counts below, which are asserted so an existing method cannot be dropped
//  coherently from the fixture and the lists at once.
//
//  FORMATTING HEURISTIC, NOT A PROOF. This pin parses the workflow as text.
//  Defeat list, stated honestly: (1) a reorder inside a list stays green by
//  design (the assertions are order-free); (2) the pin is a CONSISTENCY LOCK,
//  not a measurement-freshness check — a coherently edited fixture+lists pair
//  passes, but a median edit reds unless its net effect on a bin sum is
//  ≤ 0.0005 s (the 1 dp literals tolerate ±0.05 s, yet the exact-sum assertion
//  is ≤ 0.0005 s), so only sub-0.0005 s or compensating edits pass; (3) the
//  workflow comment itself is prose this pin cannot verify; (4) the
//  declaration scanner is lexical: a `func test…(` inside a comment or a
//  string is invisible (blanked), and a candidate whose innermost enclosing
//  declaration is not a resolved `XCTestCase` class/extension (file scope,
//  unknown base, `extension XCTestCase`, or a nested `struct`/`enum`/`actor`/
//  `protocol`) is UNATTRIBUTED and fails assertion 7 closed; a `private
//  func test…` is deliberately treated as declared (rename it). Other
//  lexical escapes are NOT probed: an `@objc(customSelector)` declaration
//  whose runtime selector starts with `test`, a generic clause
//  (`func testX<T>(…)` — harmless, XCTest cannot discover it), and platform
//  conditions that exclude the iOS Simulator destination but contain neither
//  `os(` nor `targetEnvironment(` (e.g. `#if !canImport(UIKit)`,
//  `#if arch(x86_64)`) — revise the probe if any of these become reachable;
//  (5) the
//  shape guard fails CLOSED on the canonical-shape violations it names — a
//  missing/misspelled `needs-fixture`, a multi-line `only-testing:`, a
//  duplicate `only-testing:` key, an `include:`/`exclude:` key in the matrix
//  region (bare OR quoted — `"include":` is the same YAML key), a YAML merge
//  key (`<<: *anchor`, `- <<: *anchor`) or a bare `*alias` value, a
//  `- name:` entry at a non-canonical indent, or any number of canonical
//  `- name:` entries other than four — all red with a re-derive message rather
//  than passing on a partial parse. DOCUMENTED ESCAPES: because the guard is a
//  text scan, equivalent YAML spellings it does NOT catch are a tagged key
//  (`!!str include:`), an explicit key (`? include`), a quoted or
//  space-before-colon shard entry (`- "name": shard-4`, `- name : shard-4`),
//  and an alias as the matrix/shard value (`matrix: *anchor`,
//  `shard: *anchor`) — a visible, documented gap, not a silent pass, and each
//  requires non-canonical YAML; (6) a `shard-N`
//  block appended OUTSIDE the `ui-tests` job is NOT detected — the parser is
//  scoped to that job, so a 5th shard must be added INSIDE its `matrix:` to be
//  caught (the counterfactual (g) recipe was corrected for exactly this);
//  (7) the existence check is a text search for a declaration line — a method
//  name appearing on a line that begins (after inline attributes)
//  `func <method>(` inside a multi-line string literal is NOT detected
//  (comments are stripped; string contents are not; 0 occurrences today);
//  (8) the ledger categories are reason classes, not verified mechanisms —
//  only `platformGated` is cross-checked against the declaration's gate; the
//  pin never executes the in-code `XCTSkip` guard and never proves a reason
//  true; the 20-character reason floor is a LENGTH floor for the 6
//  tracker-forbidden rows (`reproOnly` ×3, `launchPerf` ×2, `platformGated`
//  ×1) — the other 23 rows are additionally protected by the `#N` check;
//  (9) `liveTrackers` is a static Swift set, so the pin cannot query
//  GitHub: a closed tracker stays green until a human removes it, and a
//  closed tracker must name its successor in the reason and in `liveTrackers`
//  in the same PR; (10) JSONSerialization is last-wins on duplicate keys, so
//  a hand-edited duplicate top-level `exemptions` key (or duplicate member)
//  silently keeps one — the count/schema assertions are the guard.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scans at a
//  mutated tree. The variable must actually reach the test process: on this
//  runner (iOS Simulator destination) a plain env var is inert, while
//  exporting `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<tree>` into xcodebuild's
//  own environment reaches the test process. Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct WorkflowShardSplitPinsTests {

    // MARK: - Recorded constants (issue #248, 2026-10-04)

    private static let workflowPath = ".github/workflows/vvterm-pr-ci.yml"
    private static let fixturePath = "scripts/ci/shard-split-medians.json"
    private static let uiTestsDirectory = "VVTermUITests"

    /// 95 = the four lists' total; #277 scheduled the three
    /// TeleportPhaseTransitionUITests methods in shard-3 and #364 scheduled
    /// four measured never-run methods (three in shard-0, one in shard-3).
    private static let expectedMethodCount = 95

    /// The four `only-testing` list lengths.
    private static let expectedEntriesPerShard: [String: Int] = [
        "shard-0": 23,
        "shard-1": 24,
        "shard-2": 24,
        "shard-3": 24,
    ]

    /// The recorded per-bin median sums, 1 dp (the NAMED rounding rule).
    private static let expectedBinSums1dp: [String: Double] = [
        "shard-0": 611.0,
        "shard-1": 612.9,
        "shard-2": 681.7,
        "shard-3": 615.7,
    ]

    /// The same sums at the fixture's full precision (recorded for the
    /// refresh path; deltas to the 1 dp literals are in the header).
    private static let exactBinSums: [String: Double] = [
        "shard-0": 610.956,
        "shard-1": 612.882,
        "shard-2": 681.724,
        "shard-3": 615.662,
    ]

    /// Tolerance around the 1 dp literal; wider than the current deltas
    /// (≤0.044 s) so a refresh has room, narrower than any real method move.
    private static let binSumTolerance = 0.05

    /// The acceptance's structural rebalance threshold (`> ~1.3`). Recorded
    /// as a derived policy reminder, not an independent check.
    private static let maxMinRatio = 1.3

    /// Per-class scheduled counts, so an existing method cannot be dropped
    /// coherently from both the fixture and all four lists.
    private static let expectedPerClassCounts: [String: Int] = [
        "NoticePresentationUITests": 12,
        "ServerNavigationUITests": 3,
        "StatsCardsLayoutUITests": 3,
        "StatsStorageUITests": 1,
        "TeleportFormUITests": 2,
        "TeleportPhaseTransitionUITests": 3,
        "TeleportReadinessIOSUITests": 6,
        "TeleportReadinessUITests": 5,
        "TeleportUITests": 24,
        "TerminalKeyboardUITests": 19,
        "TerminalLinkTapUITests": 2,
        "TerminalReconnectUITests": 5,
        "TerminalScreenAwakeUITests": 1,
        "TerminalZenModeUITests": 9,
    ]

    /// The #227 atomic pair: `ServerNavigationUITests` shares one static
    /// `sharedApp`, so the two halves must share a bin (and an app launch).
    private static let issue227Pair = [
        "VVTermUITests/ServerNavigationUITests/testActiveTerminalPushPopPreservesListPosition",
        "VVTermUITests/ServerNavigationUITests/testActiveTerminalPushPopPreservesSession",
    ]

    // MARK: - Tests

    /// Assertion 1 — shape guard (fail closed). The `ui-tests` job must carry
    /// exactly four canonical `shard-N` matrix blocks (10-space `- name:`),
    /// each with `needs-fixture: true` and exactly one single-line
    /// double-quoted `only-testing:` scalar. The job's `matrix:` region must
    /// carry no `include:`/`exclude:` key (bare or quoted — a quoted key is the
    /// same YAML key) and no YAML merge/alias line, and exactly four `- name:`
    /// entries at any indent, so a well-formed 5th shard the 10-space scanner
    /// would miss (e.g. `matrix.include:`, or a differently-indented `- name:`)
    /// still fails the suite with a re-derive message rather than passing on a
    /// partial parse.
    @Test
    func testTheShardMatrixIsFourCanonicalBlocks() throws {
        let blocks = try Self.uiTestsShardBlocks()
        #expect(
            blocks.count == 4,
            "the `ui-tests` matrix must define exactly four `shard-N` blocks — re-derive this pin (issue #248); found \(blocks.map(\.name))"
        )
        #expect(
            Set(blocks.map(\.name)) == Set(Self.expectedEntriesPerShard.keys),
            "the shard names must be exactly shard-0..shard-3 — re-derive this pin (issue #248); found \(blocks.map(\.name).sorted())"
        )
        for block in blocks {
            #expect(
                !block.entries.isEmpty,
                "\(block.name) must carry a non-empty `only-testing:` list — re-derive this pin (issue #248)"
            )
        }
    }

    /// Assertion 2 — partition + coverage. The four lists total 95 entries,
    /// per-list 23/24/24/24, all unique; their union equals the fixture key
    /// set exactly; and the per-class scheduled counts match, so an existing
    /// method cannot be dropped coherently from both the fixture and the
    /// lists.
    @Test
    func testTheShardListsPartitionTheFixtureUniverse() throws {
        let blocks = try Self.uiTestsShardBlocks()
        let byName = Dictionary(uniqueKeysWithValues: blocks.map { ($0.name, $0) })

        for (name, expected) in Self.expectedEntriesPerShard {
            #expect(
                byName[name]?.entries.count == expected,
                "\(name) must schedule \(expected) methods (issue #248); found \(byName[name].map { String($0.entries.count) } ?? "no block")"
            )
        }

        let all = blocks.flatMap(\.entries)
        #expect(
            all.count == Self.expectedMethodCount,
            "the four `only-testing` lists must total \(Self.expectedMethodCount) methods (issue #248); found \(all.count)"
        )
        #expect(
            Set(all).count == all.count,
            "a method must be scheduled in exactly one shard; duplicates: \(Self.duplicates(in: all).sorted())"
        )

        let fixture = try Self.fixture()
        #expect(
            Set(all) == Set(fixture.medians.keys),
            "the scheduled methods and the fixture keys must be the same set — re-derive this pin (issue #248); only in lists: \(Set(all).subtracting(fixture.medians.keys).sorted()); only in fixture: \(Set(fixture.medians.keys).subtracting(all).sorted())"
        )

        var classCounts: [String: Int] = [:]
        for entry in all {
            classCounts[Self.className(of: entry), default: 0] += 1
        }
        for (className, expected) in Self.expectedPerClassCounts {
            #expect(
                classCounts[className] == expected,
                "\(className) must schedule \(expected) methods (a dropped fixture key and list entry together still reds here, issue #248); found \(classCounts[className] ?? 0)"
            )
        }
        #expect(
            Set(classCounts.keys) == Set(Self.expectedPerClassCounts.keys),
            "unexpected scheduled class(es): \(Set(classCounts.keys).subtracting(Self.expectedPerClassCounts.keys).sorted()); missing: \(Set(Self.expectedPerClassCounts.keys).subtracting(classCounts.keys).sorted())"
        )
    }

    /// Assertion 3 — existence. Every `Target/Class/method` resolves to a
    /// `func <method>(` inside that class body, with the class located
    /// recursively under `VVTermUITests/` (40 of the 95 live under
    /// `Features/Teleport/`), comments stripped first so a commented-out
    /// `func` cannot false-green.
    @Test
    func testEveryListedMethodExistsInItsClass() throws {
        let blocks = try Self.uiTestsShardBlocks()
        var fileCache: [String: String] = [:]
        var missing: [String] = []
        for entry in blocks.flatMap(\.entries) {
            let parts = entry.components(separatedBy: "/")
            guard parts.count == 3, parts[0] == "VVTermUITests" else {
                throw PinFailure("malformed `only-testing` entry `\(entry)` — expected `VVTermUITests/Class/method` (issue #248)")
            }
            let className = parts[1]
            let method = parts[2]
            let body = try Self.classBody(className: className, cache: &fileCache)
            // #248 F6: anchor to a declaration line so a method name that only
            // appears inside a string literal cannot false-green the existence
            // check. An attribute on the PRECEDING line (`@MainActor`, `@Test`)
            // is fine, and the regex also accepts inline attributes on the same
            // line, so a genuine `@MainActor func <method>(` declaration is not
            // reported missing (NIT-1). A non-declaration line that merely
            // contains the name after other text still reds.
            let declaration = #"(?m)^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*func\s+\#(NSRegularExpression.escapedPattern(for: method))\("#
            if body.range(of: declaration, options: .regularExpression) == nil {
                missing.append(entry)
            }
        }
        #expect(
            missing.isEmpty,
            "every scheduled method must still exist as `func <method>(` inside its named class (issue #248); missing: \(missing.sorted())"
        )
    }

    /// Assertion 4 — the #227 atomic pair co-located in one shard.
    @Test
    func testTheIssue227PairIsCoLocated() throws {
        let blocks = try Self.uiTestsShardBlocks()
        func shard(of entry: String) throws -> String {
            let matches = blocks.filter { $0.entries.contains(entry) }.map(\.name)
            guard matches.count == 1 else {
                throw PinFailure("`\(entry)` must be scheduled in exactly one shard (issue #248); found \(matches.sorted())")
            }
            return matches[0]
        }
        let listPosition = try shard(of: Self.issue227Pair[0])
        let session = try shard(of: Self.issue227Pair[1])
        #expect(
            listPosition == session,
            "the #227 pair (sharedApp) must share a bin so it shares one app launch (issue #248); `PreservesListPosition` is in \(listPosition), `PreservesSession` in \(session)"
        )
    }

    /// Assertion 5 — balance (recorded). Recompute each bin's sum of the
    /// fixture medians under the workflow's assignment; assert the NAMED 1 dp
    /// rounding rule equals the recorded literals (and the 0.05 s tolerance),
    /// and — as a derived policy reminder — that max/min ≤ 1.3.
    @Test
    func testTheRecordedBinSumsMatchTheFixtureAndStayUnderTheRebalanceThreshold() throws {
        let blocks = try Self.uiTestsShardBlocks()
        let fixture = try Self.fixture()
        var sums: [String: Double] = [:]
        for block in blocks {
            var total = 0.0
            for entry in block.entries {
                guard let median = fixture.medians[entry] else {
                    throw PinFailure("no fixture median for `\(entry)` — the fixture and the lists disagree (issue #248)")
                }
                total += median
            }
            sums[block.name] = total
        }

        // A dropped key in the exact table must not silently disable that
        // bin's exact check (impl-lens 2 F4): the key sets move together.
        #expect(
            Set(Self.exactBinSums.keys) == Set(Self.expectedBinSums1dp.keys),
            "exactBinSums and expectedBinSums1dp must cover the same bins — a dropped key silently disables that bin's exact check (issue #248)"
        )

        for (name, literal) in Self.expectedBinSums1dp {
            guard let sum = sums[name] else {
                throw PinFailure("no computed sum for \(name) — re-derive this pin (issue #248)")
            }
            // The named 1 dp rounding rule.
            let rounded = (sum * 10).rounded() / 10
            #expect(
                rounded == literal,
                "\(name)'s full-precision median sum \(sum) s must round (1 dp) to \(literal) s (issue #248); got \(rounded)"
            )
            // The tolerance contract around the literal.
            #expect(
                abs(sum - literal) <= Self.binSumTolerance,
                "\(name)'s median sum \(sum) s drifted more than \(Self.binSumTolerance) s from the recorded \(literal) s — re-measure and refresh the fixture + literals (issue #248)"
            )
            if let exact = Self.exactBinSums[name] {
                #expect(
                    abs(sum - exact) <= 0.0005,
                    "\(name)'s median sum \(sum) s no longer equals the recorded exact \(exact) s — a fixture value changed (issue #248)"
                )
            }
        }

        if let maxSum = sums.values.max(), let minSum = sums.values.min(), minSum > 0 {
            #expect(
                maxSum / minSum <= Self.maxMinRatio + 1e-9,
                "the recorded assignment's max/min \(maxSum / minSum) exceeds the \(Self.maxMinRatio) rebalance threshold — re-derive the split via LPT instead of only refreshing the table (issue #248)"
            )
        }
    }

    /// Assertion 6 — provenance sanity. The fixture must carry at least three
    /// runs, each identifying the run, head and creation time, so a refresh
    /// that drops provenance reds.
    @Test
    func testTheFixtureProvenanceRecordsItsPopulation() throws {
        let fixture = try Self.fixture()
        #expect(
            fixture.methodCount == Self.expectedMethodCount,
            "the fixture's `method_count` must be \(Self.expectedMethodCount) (issue #248); found \(fixture.methodCount)"
        )
        #expect(
            fixture.runs.count >= 3,
            "the fixture must record at least three provenance runs (issue #248); found \(fixture.runs.count)"
        )
        for run in fixture.runs {
            #expect(
                !run.run.isEmpty && !run.head.isEmpty && !run.created.isEmpty,
                "every provenance run must carry run/head/created (issue #248); bad entry: \(run)"
            )
        }
    }

    // MARK: - UI-test allowlist (issue #362)

    private struct DeclaredMethod: Equatable {
        let identifier: String
        let platformGate: String?
    }

    private struct UnattributedDeclaration {
        let name: String
        let file: String
        let line: Int
    }

    private struct DeclarationScan {
        let attributed: [DeclaredMethod]
        let unattributed: [UnattributedDeclaration]
        let broadProbeTotal: Int
    }

    private struct Exemption {
        let id: String
        let category: String
        let reason: String
        let tracker: Int?
    }

    private struct AllowlistFixture {
        let exemptions: [Exemption]
    }

    /// One lexical type declaration; every kind is an attribution barrier.
    private struct TypeDeclaration {
        let name: String
        let kind: String
        let base: String?
        let bodyStart: Int
        let bodyEnd: Int
    }

    private static let allowlistPath = "scripts/ci/ui-test-allowlist.json"

    /// 124 = the declared universe at d98e3aa3 (18 `XCTestCase` classes) minus
    /// the #364 deletion of `VVTermUITests/testLaunchPerformance`.
    private static let expectedDeclaredMethodCount = 124

    /// 29 = the exemption ledger after #364 deleted `testLaunchPerformance`,
    /// quarantined three measured never-scheduled rows, re-categorised the
    /// #372 native float probe as `capabilityGated`, and scheduled four rows.
    private static let expectedExemptionCount = 29

    /// The six categories and their pinned counts (issue #362;
    /// `capabilityGated` restored by #372).
    private static let expectedExemptionCountsByCategory: [String: Int] = [
        "quarantined": 17,
        "capabilityGated": 1,
        "ciQuarantined": 5,
        "reproOnly": 3,
        "launchPerf": 2,
        "platformGated": 1,
    ]

    /// Categories whose resolution is owned by a live issue.
    private static let trackerRequiredCategories: Set<String> = [
        "quarantined",
        "capabilityGated",
        "ciQuarantined",
    ]

    /// Live trackers only (open at filing: #92 and #257 on 2026-10-04; #374 on
    /// 2026-10-05, the successor for the #372 native-float coverage gap). The
    /// pin cannot query GitHub: a closed tracker must name its successor here
    /// and in its reason, or assertion 8 reds.
    private static let liveTrackers: Set<Int> = [92, 257, 374]

    /// The 4 measured never-scheduled methods, frozen as exact
    /// `(id, category)` pairs so a category swap is visible (the native float
    /// probe is `capabilityGated` on #374; the other three are `quarantined`).
    private static let frozenNeverScheduledPairs: [(id: String, category: String)] = [
        ("VVTermUITests/TerminalKeyboardUITests/testFloatingKeyboardRoundTripDoesNotReloadInputViews", "quarantined"),
        ("VVTermUITests/TerminalKeyboardUITests/testPrivacyResumeRestoresDockedAccessoryDarkAppearance", "quarantined"),
        ("VVTermUITests/TerminalKeyboardUITests/testRepeatedSplitPaneFocusKeepsOneInputUISessionWithoutReloadLoop", "quarantined"),
        ("VVTermUITests/TerminalKeyboardUITests/testNativeFloatingKeyboardRoundTripDoesNotReloadInputViews", "capabilityGated"),
    ]

    /// Assertion 7 — declared = scheduled ⊎ exempt (name-exact). The scanner
    /// fails closed on any unattributed candidate, and the broad probe's match
    /// count is recomputed in a separate `numberOfMatches` pass and must equal
    /// attributed + unattributed — a classification-completeness guard against
    /// a candidate dropped between match and attribution, not a second regex
    /// miss check. Also pins the declared/exempt/per-category counts, the
    /// frozen 4 never-scheduled `(id, category)` pairs, and the
    /// scheduled-gate guard.
    @Test
    func testEveryDeclaredUITestIsScheduledOrExempt() throws {
        let scan = try Self.declaredUITestMethods()

        #expect(
            scan.unattributed.isEmpty,
            "every `func test…(` must sit inside a resolved `XCTestCase` body; declaration(s) outside a scanned XCTestCase body: \(scan.unattributed.map { "\($0.name) (\($0.file):\($0.line))" }.sorted()) — re-derive this pin (issue #362)"
        )
        #expect(
            scan.broadProbeTotal == scan.attributed.count + scan.unattributed.count,
            "classification-completeness guard: the broad `\\bfunc\\s+(test\\w*)\\s*\\(` probe matched \(scan.broadProbeTotal) declaration(s) in its own pass, but attributed \(scan.attributed.count) + unattributed \(scan.unattributed.count) — a candidate was dropped between match and attribution; re-derive this pin (issue #362)"
        )

        let declared = scan.attributed
        #expect(
            declared.count == Self.expectedDeclaredMethodCount,
            "the target must declare \(Self.expectedDeclaredMethodCount) `func test…(` methods — re-derive this pin (issue #362); found \(declared.count)"
        )
        let duplicateDeclared = Self.duplicates(in: declared.map(\.identifier))
        #expect(
            duplicateDeclared.isEmpty,
            "two same-named test classes would collide on `VVTermUITests/<Class>/<method>`; duplicates: \(duplicateDeclared.sorted()) — re-derive this pin (issue #362)"
        )

        let blocks = try Self.uiTestsShardBlocks()
        let scheduled = blocks.flatMap(\.entries)
        let fixture = try Self.allowlistFixture()
        let exempt = fixture.exemptions.map(\.id)

        #expect(
            exempt.count == Self.expectedExemptionCount,
            "the allowlist ledger must carry \(Self.expectedExemptionCount) exemptions — re-derive this pin (issue #362); found \(exempt.count)"
        )
        let duplicateExempt = Self.duplicates(in: exempt)
        #expect(
            duplicateExempt.isEmpty,
            "an exemption id must be unique; duplicates: \(duplicateExempt.sorted()) — re-derive this pin (issue #362)"
        )

        var categoryCounts: [String: Int] = [:]
        for row in fixture.exemptions {
            categoryCounts[row.category, default: 0] += 1
        }
        for (category, expected) in Self.expectedExemptionCountsByCategory {
            #expect(
                categoryCounts[category] == expected,
                "category `\(category)` must carry \(expected) exemptions — re-derive this pin (issue #362); found \(categoryCounts[category] ?? 0)"
            )
        }
        #expect(
            Set(categoryCounts.keys) == Set(Self.expectedExemptionCountsByCategory.keys),
            "unexpected exemption categor(y|ies): \(Set(categoryCounts.keys).subtracting(Self.expectedExemptionCountsByCategory.keys).sorted()); missing: \(Set(Self.expectedExemptionCountsByCategory.keys).subtracting(categoryCounts.keys).sorted()) — re-derive this pin (issue #362)"
        )

        let declaredSet = Set(declared.map(\.identifier))
        let scheduledSet = Set(scheduled)
        let exemptSet = Set(exempt)
        // Bind the partition to locals so Swift Testing expands only the Bool
        // (`partitionHolds → false`), not all three 100+-element sets.
        let setsAreDisjoint = scheduledSet.isDisjoint(with: exemptSet)
        let partitionHolds = scheduledSet.union(exemptSet) == declaredSet
        #expect(
            setsAreDisjoint,
            "a method must never be both scheduled and exempt; overlap: \(scheduledSet.intersection(exemptSet).sorted()) — re-derive this pin (issue #362)"
        )
        #expect(
            partitionHolds,
            "the declared methods must be exactly scheduled ∪ exempt (name-exact, issue #362); declared but neither scheduled nor exempt: \(declaredSet.subtracting(scheduledSet).subtracting(exemptSet).sorted()); scheduled/exempt but not declared (stale): \(scheduledSet.union(exemptSet).subtracting(declaredSet).sorted())"
        )

        for pair in Self.frozenNeverScheduledPairs {
            #expect(
                fixture.exemptions.contains { $0.id == pair.id && $0.category == pair.category },
                "the never-scheduled-runnable methods are frozen as exact (id, category) pairs (issue #362); missing `\(pair.id)` as `\(pair.category)`"
            )
        }

        var gatesByIdentifier: [String: String?] = [:]
        for method in declared {
            gatesByIdentifier[method.identifier] = method.platformGate
        }
        for entry in scheduled {
            guard let gate = gatesByIdentifier[entry] else { continue }  // stale scheduled is asserted above
            #expect(
                gate == nil || gate == "os(iOS)",
                "a scheduled method must compile on the iOS Simulator destination (only an exact `os(iOS)` gate proves it); `\(entry)` carries gate `\(gate ?? "nil")` — a macOS-only, negated or narrowed scheduled test silently runs zero coverage (issue #362)"
            )
        }
    }

    /// Assertion 8 — exemption hygiene. Every row carries a known category, a
    /// reason of at least 20 characters, a tracker iff the category requires
    /// one, a tracker that is in the pinned live set and named as `#N` in the
    /// reason, and an id that resolves to a declared method. `platformGated`
    /// is the only mechanism cross-check (the declaration's trimmed positive
    /// `os(macOS)` gate).
    @Test
    func testEveryExemptionCarriesAReasonAndResolvesToADeclaration() throws {
        let scan = try Self.declaredUITestMethods()
        var declarationsByIdentifier: [String: DeclaredMethod] = [:]
        for method in scan.attributed {
            declarationsByIdentifier[method.identifier] = method
        }
        let fixture = try Self.allowlistFixture()
        let knownCategories = Set(Self.expectedExemptionCountsByCategory.keys)

        for row in fixture.exemptions {
            let parts = row.id.components(separatedBy: "/")
            #expect(
                parts.count == 3 && parts[0] == "VVTermUITests" && parts[2].hasPrefix("test"),
                "exemption id `\(row.id)` must be `VVTermUITests/<Class>/<test…>` — re-derive this pin (issue #362)"
            )
            #expect(
                knownCategories.contains(row.category),
                "exemption `\(row.id)` has unknown category `\(row.category)` — re-derive this pin (issue #362)"
            )
            #expect(
                row.reason.count >= 20,
                "exemption `\(row.id)` needs a mechanism-accurate reason of at least 20 characters; found \(row.reason.count) — re-derive this pin (issue #362)"
            )
            if Self.trackerRequiredCategories.contains(row.category) {
                guard let tracker = row.tracker else {
                    throw PinFailure(
                        "exemption `\(row.id)` category `\(row.category)` requires a live `tracker` — re-derive this pin (issue #362)"
                    )
                }
                #expect(
                    Self.liveTrackers.contains(tracker),
                    "exemption `\(row.id)` tracker #\(tracker) is not in the pinned live-tracker set \(Self.liveTrackers.sorted()); a closed tracker must name its successor — re-derive this pin (issue #362)"
                )
                #expect(
                    row.reason.contains("#\(tracker)"),
                    "exemption `\(row.id)` reason must name its tracker as `#\(tracker)` — re-derive this pin (issue #362)"
                )
            } else {
                #expect(
                    row.tracker == nil,
                    "exemption `\(row.id)` category `\(row.category)` is structural and must not carry a tracker (found #\(row.tracker.map(String.init) ?? "?")) — re-derive this pin (issue #362)"
                )
            }
            #expect(
                declarationsByIdentifier[row.id] != nil,
                "exemption `\(row.id)` does not resolve to a declared `func test…(` — remove a stale row in the same PR that removes the method (issue #362)"
            )
            guard let declaration = declarationsByIdentifier[row.id] else { continue }
            if row.category == "platformGated" {
                #expect(
                    declaration.platformGate == "os(macOS)",
                    "`platformGated` exemption `\(row.id)` must carry the trimmed positive `os(macOS)` gate; found `\(declaration.platformGate ?? "nil")` — re-derive this pin (issue #362)"
                )
            }
        }
    }

    // MARK: - Allowlist declaration scanner (issue #362)

    /// Assertion 7/8 source scanner (plan v3 §3.2). Recursively reads
    /// `VVTermUITests/`, blanks comments and string interiors, line-scans the
    /// `#if` condition stack WITH polarity (`#else` flips, `#elseif`
    /// replaces), brace-matches every type declaration as an attribution
    /// barrier, and attributes each unanchored `\bfunc\s+`?(test\w*)`?\s*\(`
    /// candidate to its innermost enclosing declaration. A candidate whose
    /// innermost declaration is not a resolved `XCTestCase` class (direct or
    /// a transitive base chain within the scan) or an extension of one is
    /// returned UNATTRIBUTED and fails assertion 7 closed; `extension
    /// XCTestCase` is never a test class.
    private static func declaredUITestMethods() throws -> DeclarationScan {
        let directory = try repositoryRoot().appendingPathComponent(uiTestsDirectory)
        let files = try swiftFiles(under: directory)

        var declarationsByFile: [String: [TypeDeclaration]] = [:]
        var blankedByFile: [String: String] = [:]
        var classBases: [String: String?] = [:]

        for file in files {
            let source: String
            do {
                source = try String(contentsOf: file, encoding: .utf8)
            } catch {
                throw PinFailure("could not read \(file.path): \(error) — re-derive this pin (issue #362)")
            }
            let blanked = strippingCommentsAndStrings(source)
            blankedByFile[file.path] = blanked
            let declarations = typeDeclarations(in: blanked)
            declarationsByFile[file.path] = declarations
            for declaration in declarations where declaration.kind == "class" {
                if classBases[declaration.name] == nil {
                    classBases[declaration.name] = declaration.base
                }
            }
        }

        func resolvesToXCTestCase(_ name: String) -> Bool {
            var visited: Set<String> = []
            var current = name
            while true {
                guard current != "XCTestCase" else { return false }
                guard !visited.contains(current) else { return false }
                visited.insert(current)
                guard let base = classBases[current].flatMap({ $0 }) else { return false }
                if base == "XCTestCase" { return true }
                current = base
            }
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: #"\bfunc\s+`?(test\w*)`?\s*\("#)
        } catch {
            throw PinFailure("could not compile the declared-test probe: \(error) — re-derive this pin (issue #362)")
        }

        var attributed: [DeclaredMethod] = []
        var unattributed: [UnattributedDeclaration] = []
        var broadProbeTotal = 0

        for file in files {
            guard let blanked = blankedByFile[file.path] else { continue }
            let gates = try platformGatesByLine(in: blanked)
            let declarations = declarationsByFile[file.path] ?? []
            let nsText = blanked as NSString
            // Classification-completeness guard: count the broad probe's
            // matches in a SEPARATE pass, so a candidate dropped between
            // match and attribution reds even when `unattributed` is empty.
            broadProbeTotal += regex.numberOfMatches(
                in: blanked,
                range: NSRange(location: 0, length: nsText.length)
            )
            for match in regex.matches(in: blanked, range: NSRange(location: 0, length: nsText.length)) {
                let name = nsText.substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "`", with: "")
                let index = match.range.location
                let line = lineNumber(atUTF16Offset: index, in: nsText)
                let innermost = declarations
                    .filter { $0.bodyStart < index && index < $0.bodyEnd }
                    .max { $0.bodyStart < $1.bodyStart }
                let resolvedClass: String?
                if let innermost, innermost.kind == "class" || innermost.kind == "extension" {
                    resolvedClass = resolvesToXCTestCase(innermost.name) ? innermost.name : nil
                } else {
                    resolvedClass = nil
                }
                if let className = resolvedClass {
                    attributed.append(
                        DeclaredMethod(
                            identifier: "\(uiTestsDirectory)/\(className)/\(name)",
                            platformGate: gates[line]
                        )
                    )
                } else {
                    unattributed.append(
                        UnattributedDeclaration(
                            name: name,
                            file: file.lastPathComponent,
                            line: line
                        )
                    )
                }
            }
        }
        return DeclarationScan(
            attributed: attributed,
            unattributed: unattributed,
            broadProbeTotal: broadProbeTotal
        )
    }

    /// Per-line platform gate: the innermost POSITIVE `#if` frame whose
    /// trimmed condition contains `os(` or `targetEnvironment(`, after
    /// applying `#else` polarity. A method in the `#else` of `#if os(macOS)`
    /// compiles on the iOS Simulator, so it must not carry the macOS gate
    /// (re-lens-1 MINOR-1); `#if targetEnvironment(macCatalyst)` is recorded
    /// so the scheduled-gate guard reds instead of silently compiling out.
    /// `swift(`/`DEBUG` are deliberately not recorded (they do not exclude
    /// the destination); conditions with neither token are defeat (4).
    private static func platformGatesByLine(in blanked: String) throws -> [Int: String] {
        var gates: [Int: String] = [:]
        var stack: [(condition: String, positive: Bool)] = []
        for (offset, line) in blanked.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                let condition = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                stack.append((condition, true))
            } else if trimmed.hasPrefix("#elseif") {
                guard !stack.isEmpty else {
                    throw PinFailure("unbalanced `#elseif` while scanning \(uiTestsDirectory)/ — re-derive this pin (issue #362)")
                }
                let condition = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                stack[stack.count - 1] = (condition, true)
            } else if trimmed.hasPrefix("#else") {
                guard !stack.isEmpty else {
                    throw PinFailure("unbalanced `#else` while scanning \(uiTestsDirectory)/ — re-derive this pin (issue #362)")
                }
                let frame = stack[stack.count - 1]
                stack[stack.count - 1] = (frame.condition, false)
            } else if trimmed.hasPrefix("#endif") {
                guard !stack.isEmpty else {
                    throw PinFailure("unbalanced `#endif` while scanning \(uiTestsDirectory)/ — re-derive this pin (issue #362)")
                }
                stack.removeLast()
            }
            if let gate = stack.last(where: {
                $0.positive && ($0.condition.contains("os(") || $0.condition.contains("targetEnvironment("))
            })?.condition {
                gates[offset + 1] = gate
            }
        }
        return gates
    }

    /// Brace-match every lexical type declaration on the comment/string-blanked
    /// text. All kinds (`class`, `struct`, `enum`, `actor`, `protocol`,
    /// `extension`) are attribution barriers (re-lens-1 MAJOR-1); a class's
    /// base is the first identifier after its `:` clause.
    private static func typeDeclarations(in text: String) -> [TypeDeclaration] {
        let units = Array(text.utf16)
        let nsText = text as NSString
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(
                pattern: #"\b(extension|class|struct|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"#
            )
        } catch {
            return []
        }
        let reservedClassNames: Set<String> = ["func", "var", "let", "subscript", "init", "deinit", "case", "where"]
        var declarations: [TypeDeclaration] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let kind = nsText.substring(with: match.range(at: 1))
            let name = nsText.substring(with: match.range(at: 2))
            if kind == "class" && reservedClassNames.contains(name) { continue }
            let searchStart = match.range.location + match.range.length
            guard let bodyStart = nextBraceIndex(in: units, from: searchStart) else { continue }
            guard let bodyEnd = matchingBraceIndex(in: units, from: bodyStart) else { continue }
            var base: String?
            if kind == "class" {
                let clause = nsText.substring(with: NSRange(location: searchStart, length: bodyStart - searchStart))
                if let colon = clause.firstIndex(of: ":") {
                    base = firstIdentifier(in: String(clause[clause.index(after: colon)...]))
                }
            }
            declarations.append(
                TypeDeclaration(name: name, kind: kind, base: base, bodyStart: bodyStart, bodyEnd: bodyEnd)
            )
        }
        return declarations
    }

    private static func nextBraceIndex(in units: [UInt16], from start: Int) -> Int? {
        var index = max(0, start)
        while index < units.count {
            if units[index] == 0x7B { return index }
            index += 1
        }
        return nil
    }

    private static func matchingBraceIndex(in units: [UInt16], from open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < units.count {
            if units[index] == 0x7B {
                depth += 1
            } else if units[index] == 0x7D {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func firstIdentifier(in text: String) -> String? {
        guard let range = text.range(of: #"[A-Za-z_][A-Za-z0-9_]*"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }

    private static func lineNumber(atUTF16Offset offset: Int, in text: NSString) -> Int {
        var line = 1
        var cursor = 0
        while cursor < offset {
            let found = text.range(
                of: "\n",
                options: [],
                range: NSRange(location: cursor, length: offset - cursor)
            )
            if found.location == NSNotFound { break }
            line += 1
            cursor = found.location + found.length
        }
        return line
    }

    /// Blanks `//` and nested `/* */` comments plus string interiors while
    /// preserving the UTF-16 length (newlines are kept), so regex match
    /// offsets and line numbers stay aligned with the source. Hash-prefix
    /// aware: `#"…"#`, `##"…"##`, … close only on `"` + the same number of
    /// `#` (re-lens-1 MINOR-2). Scanner-local by design; the existing
    /// `strippingComments` (string contents kept) is untouched for assertion 3.
    private static func strippingCommentsAndStrings(_ source: String) -> String {
        let units = Array(source.utf16)
        let slash: UInt16 = 0x2F
        let star: UInt16 = 0x2A
        let newline: UInt16 = 0x0A
        let space: UInt16 = 0x20
        var result: [UInt16] = []
        result.reserveCapacity(units.count)
        var index = 0
        var inLineComment = false
        var blockDepth = 0
        while index < units.count {
            let unit = units[index]
            if inLineComment {
                if unit == newline {
                    inLineComment = false
                    result.append(unit)
                } else {
                    result.append(space)
                }
                index += 1
                continue
            }
            if blockDepth > 0 {
                if unit == slash, index + 1 < units.count, units[index + 1] == star {
                    blockDepth += 1
                    result.append(space)
                    result.append(space)
                    index += 2
                } else if unit == star, index + 1 < units.count, units[index + 1] == slash {
                    blockDepth -= 1
                    result.append(space)
                    result.append(space)
                    index += 2
                } else {
                    result.append(unit == newline ? newline : space)
                    index += 1
                }
                continue
            }
            if unit == slash, index + 1 < units.count, units[index + 1] == slash {
                inLineComment = true
                result.append(space)
                result.append(space)
                index += 2
                continue
            }
            if unit == slash, index + 1 < units.count, units[index + 1] == star {
                blockDepth = 1
                result.append(space)
                result.append(space)
                index += 2
                continue
            }
            if unit == 0x22 || unit == 0x23 {
                if let end = stringLiteralEnd(in: units, at: index) {
                    var cursor = index
                    while cursor < end {
                        result.append(units[cursor] == newline ? newline : space)
                        cursor += 1
                    }
                    index = end
                    continue
                }
            }
            result.append(unit)
            index += 1
        }
        return String(decoding: result, as: UTF16.self)
    }

    /// End (exclusive UTF-16 offset) of the string literal opening at `start`
    /// (a `"` or the first `#` of a raw prefix), or nil when `start` opens no
    /// literal. Unterminated literals run to EOF, which fails the count closed.
    private static func stringLiteralEnd(in units: [UInt16], at start: Int) -> Int? {
        let hash: UInt16 = 0x23
        let quote: UInt16 = 0x22
        let backslash: UInt16 = 0x5C
        var cursor = start
        var hashes = 0
        while cursor < units.count, units[cursor] == hash {
            hashes += 1
            cursor += 1
        }
        guard cursor < units.count, units[cursor] == quote else { return nil }
        let triple = cursor + 2 < units.count
            && units[cursor + 1] == quote
            && units[cursor + 2] == quote
        var index = cursor + (triple ? 3 : 1)
        while index < units.count {
            if hashes == 0, units[index] == backslash {
                index += 2
                continue
            }
            if units[index] == quote {
                if triple {
                    if index + 2 < units.count,
                       units[index + 1] == quote,
                       units[index + 2] == quote,
                       matchesHashSuffix(units, at: index + 3, count: hashes) {
                        return index + 3 + hashes
                    }
                } else if matchesHashSuffix(units, at: index + 1, count: hashes) {
                    return index + 1 + hashes
                }
            }
            index += 1
        }
        return units.count
    }

    private static func matchesHashSuffix(_ units: [UInt16], at index: Int, count: Int) -> Bool {
        guard count > 0 else { return true }
        guard index + count <= units.count else { return false }
        for offset in 0..<count where units[index + offset] != 0x23 {
            return false
        }
        return true
    }

    private static func allowlistFixture() throws -> AllowlistFixture {
        let url = try repositoryRoot().appendingPathComponent(allowlistPath)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PinFailure("could not read the allowlist fixture at \(url.path): \(error) — re-derive this pin (issue #362)")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PinFailure("the allowlist fixture at \(url.path) is not valid JSON: \(error) — re-derive this pin (issue #362)")
        }
        guard let root = object as? [String: Any],
              root["_provenance"] is [String: Any],
              let rows = root["exemptions"] as? [[String: Any]]
        else {
            throw PinFailure("the allowlist fixture at \(url.path) must have a `_provenance` object and an `exemptions` array — re-derive this pin (issue #362)")
        }
        var exemptions: [Exemption] = []
        for row in rows {
            guard let id = row["id"] as? String,
                  let category = row["category"] as? String,
                  let reason = row["reason"] as? String
            else {
                throw PinFailure("every exemption row must carry string `id`, `category` and `reason` — re-derive this pin (issue #362); bad row: \(row)")
            }
            var tracker: Int?
            if let rawTracker = row["tracker"] {
                guard let number = rawTracker as? Int else {
                    throw PinFailure("exemption `\(id)` must carry an integer `tracker` — re-derive this pin (issue #362)")
                }
                tracker = number
            }
            exemptions.append(Exemption(id: id, category: category, reason: reason, tracker: tracker))
        }
        return AllowlistFixture(exemptions: exemptions)
    }

    // MARK: - Matrix parsing

    private struct ShardBlock {
        let name: String
        let entries: [String]
    }

    /// Parse the four canonical `shard-N` blocks out of the `ui-tests` job's
    /// `matrix.shard` list, scoped to that job (comments stripped YAML-style
    /// first). Fails closed: a missing `ui-tests` job, a missing/misspelled
    /// `needs-fixture`, or an `only-testing:` that is not a single-line
    /// double-quoted scalar throws instead of returning a partial parse.
    private static func uiTestsShardBlocks() throws -> [ShardBlock] {
        let source = try workflowSource(workflowPath)
        let stripped = strippingYAMLComments(source)
        let lines = stripped.components(separatedBy: "\n")
        guard let jobStart = lines.firstIndex(where: {
            $0.range(of: #"^  ui-tests:\s*$"#, options: .regularExpression) != nil
        }) else {
            throw PinFailure("no `  ui-tests:` job in \(workflowPath) — re-derive this pin (issue #248)")
        }
        var jobEnd = lines.count
        var cursor = jobStart + 1
        while cursor < lines.count {
            if lines[cursor].range(of: #"^  [A-Za-z0-9_.-]+:\s*$"#, options: .regularExpression) != nil {
                jobEnd = cursor
                break
            }
            cursor += 1
        }
        let jobLines = Array(lines[jobStart..<jobEnd])
        try validateMatrixRegion(of: jobLines)

        var blocks: [ShardBlock] = []
        var index = 0
        while index < jobLines.count {
            let line = jobLines[index]
            guard let nameMatch = line.range(
                of: #"^          - name: (shard-[0-9]+)\s*$"#,
                options: .regularExpression
            ) else {
                index += 1
                continue
            }
            let name = String(line[nameMatch])
                .replacingOccurrences(of: "- name: ", with: "")
                .trimmingCharacters(in: .whitespaces)

            guard index + 1 < jobLines.count, jobLines[index + 1] == "            needs-fixture: true" else {
                throw PinFailure(
                    "\(name) must declare exactly `            needs-fixture: true` on the line after `- name:` — a `false` flip (or a quoted spelling) skips fixture provisioning and XCTSkips the gated tests green, so the shape guard fails closed (issue #248)"
                )
            }
            guard index + 2 < jobLines.count,
                  jobLines[index + 2].range(
                      of: #"^            only-testing: "[^"]*"$"#,
                      options: .regularExpression
                  ) != nil
            else {
                throw PinFailure(
                    "\(name) must carry exactly one single-line double-quoted `only-testing:` scalar — a multi-line/plain scalar parses differently and the shard silently resolves to an empty test set (issue #248)"
                )
            }
            // #248 F2: this scanner is first-wins (it reads `index + 2`), while
            // YAML loaders are last-wins — a duplicate `only-testing:` key in
            // the same mapping would let the shard run a list the pin never
            // checked. Scan the whole block mapping (up to the next `- name:` or
            // dedent below 12 spaces) and reject a second key.
            let blockMapping = uiTestsShardBlockMapping(startingAt: index + 1, in: jobLines)
            let onlyTestingKeys = blockMapping.filter {
                $0.range(of: #"^\s*only-testing\s*:"#, options: .regularExpression) != nil
            }
            guard onlyTestingKeys.count == 1 else {
                throw PinFailure(
                    "\(name) must carry exactly one `only-testing:` key in its mapping — found \(onlyTestingKeys.count); a duplicate key is read first-wins by this text scanner but last-wins by YAML, so the shard could run an unchecked list (issue #248)"
                )
            }
            let scalar = String(jobLines[index + 2])
                .replacingOccurrences(of: #"            only-testing: ""#, with: "")
                .dropLast()
            blocks.append(
                ShardBlock(
                    name: name,
                    entries: scalar.components(separatedBy: ",")
                )
            )
            index += 3
        }
        return blocks
    }

    /// Fail closed on a non-canonical shard source the 10-space scanner below
    /// cannot see (issue #248, F1). The `ui-tests` job's `matrix:` region must
    /// not carry an `include:`/`exclude:` key — a `matrix.include:` entry adds a
    /// real 5th shard, whether the key is bare or quoted (`"include":`) — and
    /// must not carry a YAML merge key (`<<: *anchor`) or bare `*alias` value
    /// that injects entries the scanner cannot see; and it must contain exactly
    /// four `- name:` entries at any indent, so a re-indented or extra entry
    /// reds rather than passing.
    private static func validateMatrixRegion(of jobLines: [String]) throws {
        guard let matrixStart = jobLines.firstIndex(where: {
            $0.range(of: #"^      matrix:\s*$"#, options: .regularExpression) != nil
        }) else {
            throw PinFailure(
                "no `      matrix:` block inside the `ui-tests` job — re-derive this pin (issue #248)"
            )
        }
        var region: [String] = []
        var cursor = matrixStart + 1
        while cursor < jobLines.count {
            let line = jobLines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !line.hasPrefix("        ") {
                break
            }
            region.append(line)
            cursor += 1
        }
        // A quoted key (`"include":` / `'exclude':`) is the same YAML key as
        // the bare spelling, so accept an optional quote around the key. A YAML
        // merge key (`<<: *anchor`, `- <<: *anchor`) or a bare `*alias` value
        // injects mapping entries the canonical scanner never sees, so it fails
        // closed too (issue #248, ND-2).
        if let nonCanonical = region.first(where: {
            $0.range(of: #"^\s*["']?(include|exclude)["']?\s*:"#, options: .regularExpression) != nil
        }) {
            throw PinFailure(
                "the `ui-tests` matrix carries a non-canonical `\(nonCanonical.trimmingCharacters(in: .whitespaces))` key — a `matrix.include:`/`exclude:` entry (bare or quoted) can add a real 5th shard the canonical 10-space scanner cannot see, so the shape guard fails closed (issue #248); re-derive this pin"
            )
        }
        if let mergeKey = region.first(where: {
            $0.range(of: #"^\s*-?\s*<<\s*:"#, options: .regularExpression) != nil
                || $0.range(of: #"^\s*\*\S+\s*$"#, options: .regularExpression) != nil
        }) {
            throw PinFailure(
                "the `ui-tests` matrix carries a YAML merge/alias line `\(mergeKey.trimmingCharacters(in: .whitespaces))` — a `<<: *anchor` merge key or a bare `*alias` value injects matrix entries the canonical scanner cannot see, so the shape guard fails closed (issue #248); re-derive this pin"
            )
        }
        let nameEntries = region.filter {
            $0.range(of: #"^\s*- name:"#, options: .regularExpression) != nil
        }
        guard nameEntries.count == 4 else {
            throw PinFailure(
                "the `ui-tests` matrix must carry exactly four `- name:` shard entries at any indent — found \(nameEntries.count); a differently-indented or extra entry can add a real 5th shard the canonical 10-space scanner cannot see (issue #248); re-derive this pin"
            )
        }
    }

    /// The mapping lines of one shard block: from `start` (the line after
    /// `- name:`) until the next non-blank line dedented below 12 spaces (the
    /// next `- name:` sits at 10 spaces).
    private static func uiTestsShardBlockMapping(startingAt start: Int, in jobLines: [String]) -> [String] {
        var mapping: [String] = []
        var cursor = start
        while cursor < jobLines.count {
            let line = jobLines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !line.hasPrefix("            ") {
                break
            }
            mapping.append(line)
            cursor += 1
        }
        return mapping
    }

    // MARK: - Fixture parsing

    private struct ProvenanceRun {
        let run: String
        let head: String
        let created: String
    }

    private struct Fixture {
        let medians: [String: Double]
        let runs: [ProvenanceRun]
        let methodCount: Int
    }

    private static func fixture() throws -> Fixture {
        let url = try repositoryRoot().appendingPathComponent(fixturePath)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PinFailure("could not read the fixture at \(url.path): \(error) — re-derive this pin (issue #248)")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PinFailure("the fixture at \(url.path) is not valid JSON: \(error) — re-derive this pin (issue #248)")
        }
        guard let root = object as? [String: Any],
              let provenance = root["_provenance"] as? [String: Any],
              let mediansObject = root["medians"] as? [String: Any]
        else {
            throw PinFailure("the fixture at \(url.path) must have `_provenance` and `medians` objects — re-derive this pin (issue #248)")
        }
        var medians: [String: Double] = [:]
        for (key, value) in mediansObject {
            guard let number = value as? Double else {
                throw PinFailure("fixture median for `\(key)` is not a number — re-derive this pin (issue #248)")
            }
            medians[key] = number
        }
        let runsObject = provenance["runs"] as? [[String: Any]] ?? []
        let runs = runsObject.map {
            ProvenanceRun(
                run: $0["run"] as? String ?? "",
                head: $0["head"] as? String ?? "",
                created: $0["created"] as? String ?? ""
            )
        }
        let methodCount = provenance["method_count"] as? Int ?? 0
        return Fixture(medians: medians, runs: runs, methodCount: methodCount)
    }

    // MARK: - Source resolution

    /// Locate `final class <ClassName>: XCTestCase` recursively under
    /// `VVTermUITests/`, strip comments, and return the class body (from the
    /// declaration to the next top-level `final class`, or EOF).
    private static func classBody(className: String, cache: inout [String: String]) throws -> String {
        let directory = try repositoryRoot().appendingPathComponent(uiTestsDirectory)
        for file in try swiftFiles(under: directory) {
            let source: String
            if let cached = cache[file.path] {
                source = cached
            } else {
                source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                cache[file.path] = source
            }
            guard !source.isEmpty else { continue }
            let stripped = strippingComments(source)
            let lines = stripped.components(separatedBy: "\n")
            guard let declaration = lines.firstIndex(where: {
                $0.range(
                    of: #"^final class \#(className): XCTestCase"#,
                    options: .regularExpression
                ) != nil
            }) else {
                continue
            }
            var end = lines.count
            var cursor = declaration + 1
            while cursor < lines.count {
                if lines[cursor].range(of: #"^final class [A-Za-z0-9_]+:"#, options: .regularExpression) != nil {
                    end = cursor
                    break
                }
                cursor += 1
            }
            return lines[declaration..<end].joined(separator: "\n")
        }
        throw PinFailure("could not locate `final class \(className): XCTestCase` under \(uiTestsDirectory)/ — the class was renamed/moved or the entry is stale (issue #248)")
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PinFailure("could not enumerate \(directory.path) — re-derive this pin (issue #248)")
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func className(of entry: String) -> String {
        let parts = entry.components(separatedBy: "/")
        return parts.count >= 2 ? parts[1] : entry
    }

    private static func duplicates(in entries: [String]) -> [String] {
        var seen: Set<String> = []
        var duplicated: Set<String> = []
        for entry in entries {
            if !seen.insert(entry).inserted {
                duplicated.insert(entry)
            }
        }
        return Array(duplicated)
    }

    // MARK: - Filesystem / shared idiom

    private struct PinFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }
    }

    private static func workflowSource(_ relativePath: String) throws -> String {
        let url = try repositoryRoot().appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PinFailure("could not read \(relativePath) at \(url.path): \(error)")
        }
    }

    private static func repositoryRoot() throws -> URL {
        // Counterfactual hook: the mutation runs point this at a copy of the
        // source with the workflow/fixture mutated.
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

    /// A YAML comment-stripped copy of `source`: a `#` that starts a comment
    /// (at line start or preceded by whitespace, outside a quoted scalar)
    /// blanks the rest of the line; newlines are preserved, so line anchors
    /// still resolve. Duplicated from the other workflow pin suites (each pin
    /// file is self-contained so it reverts independently until the shared
    /// helper extraction lands).
    private static func strippingYAMLComments(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        var inSingleQuoted = false
        var inDoubleQuoted = false
        var escaped = false
        var atLineStart = true
        var previousWasWhitespace = true
        while index < characters.count {
            let character = characters[index]
            if inSingleQuoted {
                result.append(character)
                index += 1
                if character == "'" {
                    if index < characters.count, characters[index] == "'" {
                        result.append("'")
                        index += 1
                    } else {
                        inSingleQuoted = false
                    }
                }
                atLineStart = false
                previousWasWhitespace = false
                continue
            }
            if inDoubleQuoted {
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
                if character == "\"" {
                    inDoubleQuoted = false
                }
                atLineStart = false
                previousWasWhitespace = false
                continue
            }
            if character == "#", atLineStart || previousWasWhitespace {
                while index < characters.count, characters[index] != "\n" {
                    result.append(" ")
                    index += 1
                }
                continue
            }
            if character == "\n" {
                result.append("\n")
                index += 1
                atLineStart = true
                previousWasWhitespace = true
                continue
            }
            if character == "'" {
                inSingleQuoted = true
            } else if character == "\"" {
                inDoubleQuoted = true
            }
            result.append(character)
            index += 1
            atLineStart = false
            previousWasWhitespace = character.isWhitespace
        }
        return result
    }

    /// A Swift comment-stripped copy of `source`: text inside `//` line
    /// comments and nested `/* … */` block comments becomes spaces; newlines
    /// are preserved. String contents are copied verbatim (so a `//` inside a
    /// literal is not read as a comment). Duplicated from
    /// `SSHShellLoopLivenessPinsTests` (each pin file is self-contained).
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
}
