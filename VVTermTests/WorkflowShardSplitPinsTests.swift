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
//  41-run qualifying population plus its provenance. Without this pin, a list
//  that silently drops a method, names a method that no longer exists, splits
//  the #227 pair, or drifts away from the recorded fixture is invisible —
//  the workflow is prose the compiler cannot check.
//
//  PRECISION CONTRACT (lens 2 P1 / lens 1 F6 / closure F10). The fixture
//  stores the per-method medians at 3 dp. The pin computes each bin sum from
//  those values at FULL precision and asserts the NAMED 1 dp rounding rule:
//  `(sum * 10).rounded() / 10` equals the recorded literals
//  555.4 / 612.9 / 681.7 / 549.6. The exact sums are
//  555.408 / 612.882 / 681.724 / 549.557 s, so the |sum − literal| deltas are
//  0.008 / 0.018 / 0.024 / 0.043 — small but non-zero, recorded here so a
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
//  change), so a refactor of four pin suites would be an unrelated risk. Any
//  parser/comment-strip fix for the shared idiom must be applied to all five
//  files until the extraction lands.
//
//  REFRESH PATH (adding or removing a scheduled method). A PR that schedules
//  a new method — or removes one — must, in the SAME PR: update
//  `scripts/ci/shard-split-medians.json` (adding the method's 3 dp median and
//  a provenance run), update the four 1 dp sum literals plus the exact sums
//  below, and refresh the workflow comment above `matrix.shard`. A new
//  method's median comes from a calibration measurement: the first green
//  attempt-1 run after the change, whose run id is appended to
//  `_provenance.runs`. Removals are additionally caught by the literal
//  88-method count and the per-class counts below, which are asserted so an
//  existing method cannot be dropped coherently from the fixture and the
//  lists at once.
//
//  FORMATTING HEURISTIC, NOT A PROOF. This pin parses the workflow as text.
//  Defeat list, stated honestly: (1) a reorder inside a list stays green by
//  design (the assertions are order-free); (2) the pin is a CONSISTENCY LOCK,
//  not a measurement-freshness check — a coherently edited fixture+lists pair
//  passes, but a median edit reds unless its net effect on a bin sum is
//  ≤ 0.0005 s (the 1 dp literals tolerate ±0.05 s, yet the exact-sum assertion
//  is ≤ 0.0005 s), so only sub-0.0005 s or compensating edits pass; (3) the
//  workflow comment itself is prose this pin cannot verify; (4) a new UI test
//  added to the target but never scheduled is NOT detected (the follow-up
//  issue for the 8 currently-ungated unlisted methods owns that); (5) the
//  shape guard fails CLOSED on a malformed or non-canonical matrix shape —
//  a missing/misspelled `needs-fixture`, a multi-line `only-testing:`, a
//  duplicate `only-testing:` key, an `include:`/`exclude:` key in the matrix
//  region, or a `- name:` entry at a non-canonical indent all red with a
//  re-derive message rather than passing on a partial parse; (6) a `shard-N`
//  block appended OUTSIDE the `ui-tests` job is NOT detected — the parser is
//  scoped to that job, so a 5th shard must be added INSIDE its `matrix:` to be
//  caught (the counterfactual (g) recipe was corrected for exactly this).
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

    /// 88 = the four lists' total; the last `only-testing` change is #236.
    private static let expectedMethodCount = 88

    /// The four `only-testing` list lengths.
    private static let expectedEntriesPerShard: [String: Int] = [
        "shard-0": 20,
        "shard-1": 24,
        "shard-2": 24,
        "shard-3": 20,
    ]

    /// The recorded per-bin median sums, 1 dp (the NAMED rounding rule).
    private static let expectedBinSums1dp: [String: Double] = [
        "shard-0": 555.4,
        "shard-1": 612.9,
        "shard-2": 681.7,
        "shard-3": 549.6,
    ]

    /// The same sums at the fixture's full precision (recorded for the
    /// refresh path; deltas to the 1 dp literals are in the header).
    private static let exactBinSums: [String: Double] = [
        "shard-0": 555.408,
        "shard-1": 612.882,
        "shard-2": 681.724,
        "shard-3": 549.557,
    ]

    /// Tolerance around the 1 dp literal; wider than the current deltas
    /// (≤0.043 s) so a refresh has room, narrower than any real method move.
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
        "TeleportReadinessIOSUITests": 6,
        "TeleportReadinessUITests": 5,
        "TeleportUITests": 24,
        "TerminalKeyboardUITests": 16,
        "TerminalLinkTapUITests": 2,
        "TerminalReconnectUITests": 5,
        "TerminalScreenAwakeUITests": 1,
        "TerminalZenModeUITests": 8,
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
    /// carry no `include:`/`exclude:` key and exactly four `- name:` entries at
    /// any indent, so a well-formed 5th shard the 10-space scanner would miss
    /// (e.g. `matrix.include:`, or a differently-indented `- name:`) still fails
    /// the suite with a re-derive message rather than passing on a partial parse.
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

    /// Assertion 2 — partition + coverage. The four lists total 88 entries,
    /// per-list 20/24/24/20, all unique; their union equals the fixture key
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
    /// recursively under `VVTermUITests/` (37 of the 88 live under
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
            // check. An attribute on the preceding line (`@MainActor`, `@Test`)
            // is fine — only `func` must start the whitespace-trimmed line.
            let declaration = #"(?m)^[ \t]*func \#(NSRegularExpression.escapedPattern(for: method))\("#
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
    /// real 5th shard — and must contain exactly four `- name:` entries at any
    /// indent, so a re-indented or extra entry reds rather than passing.
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
        if let nonCanonical = region.first(where: {
            $0.range(of: #"^\s*(include|exclude)\s*:"#, options: .regularExpression) != nil
        }) {
            throw PinFailure(
                "the `ui-tests` matrix carries a non-canonical `\(nonCanonical.trimmingCharacters(in: .whitespaces))` key — a `matrix.include:`/`exclude:` entry can add a real 5th shard the canonical 10-space scanner cannot see, so the shape guard fails closed (issue #248); re-derive this pin"
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
