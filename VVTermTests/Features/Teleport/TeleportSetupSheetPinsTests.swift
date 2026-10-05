// SPDX-License-Identifier: MIT
//
//  TeleportSetupSheetPinsTests.swift
//  VVTermTests
//
//  Source pin for issue #369: the Teleport phase-chain routing must stay
//  single-source. The two production hosts (`ServerSidebarView`,
//  `ServerListScreen`) present the shared `TeleportSetupSheet` and no longer
//  own a `switch readiness`; the shared sheet owns exactly one
//  `switch chain.phase`; the UI-test harness presents the shared sheet and
//  declares none of the old `PhaseChain*Sheet` wrappers.
//
//  Without this pin a re-inline (a host keeping the `TeleportSetupSheet(` call
//  but adding a bypass `switch chain.phase`, or a restored private wrapper)
//  would silently re-create the mirror #369 closed.
//
//  This is the sixth copy of the WORKFLOW-pin idiom (`repositoryRoot()`
//  honouring `VVTERM_PINS_SOURCE_ROOT` + YAML comment stripping) after
//  `WorkflowArtifactDependencyPinsTests`,
//  `WorkflowArtifactDependencyClassGatePinsTests`,
//  `WorkflowXcodebuildFlagPinsTests`, `WorkflowPerPREventGatePinsTests` and
//  `WorkflowShardSplitPinsTests`. Measured at the fold head: 6 `VVTermTests`
//  files call `strippingYAMLComments`, and the `VVTERM_PINS_SOURCE_ROOT`
//  override itself appears in 25 files across the other pin families.
//  Extraction is DELIBERATELY DEFERRED for the same reason
//  `WorkflowShardSplitPinsTests` deferred the fifth: the idiom is small, and
//  extraction would span six independent workflow-pin suites. Re-evaluate
//  when a seventh workflow-pin file lands.
//
//  COUNTERFACTUAL HOOK: `VVTERM_PINS_SOURCE_ROOT` points the scans at a copy
//  of the tree; set it from the test process by exporting
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<tree>` into xcodebuild's environment.
//  It is never set in CI, so the pin always scans the real tree there.
//
//  See:
//    - VVTerm/Features/Teleport/UI/TeleportSetupSheet.swift
//    - VVTerm/Features/Teleport/Application/TeleportPhaseChain.swift
//

import Foundation
import Testing
@testable import VVTerm

@Suite
@MainActor
struct TeleportSetupSheetPinsTests {

    private struct PinFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Paths

    private static let sidebarPath = "VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift"
    private static let iOSListPath = "VVTerm/App/iOS/ServerListScreen+iOS.swift"
    private static let formPath = "VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift"
    private static let sheetPath = "VVTerm/Features/Teleport/UI/TeleportSetupSheet.swift"
    private static let harnessPath = "VVTerm/App/iOS/TeleportPhaseChainUITestHarness+iOS.swift"

    // MARK: - Assertion 1: the two production hosts present the shared sheet

    @Test
    func productionHostsPresentTheSharedSheetAndOwnNoSwitch() throws {
        for path in [Self.sidebarPath, Self.iOSListPath] {
            let source = try strippedSource(at: path)

            #expect(count("TeleportSetupSheet(", in: source) == 1,
                    "\(path): expected exactly one TeleportSetupSheet( invocation")
            #expect(count("switch chain.phase", in: source) == 0,
                    "\(path): the phase switch must live only in TeleportSetupSheet.swift")
            #expect(count("case .needsBootstrap:", in: source) == 0,
                    "\(path): the old readiness switch must not return")
            #expect(count("case .needsRegistration:", in: source) == 0,
                    "\(path): the old readiness switch must not return")
            #expect(count("case .needsLogin:", in: source) == 0,
                    "\(path): the old readiness switch must not return")
            #expect(count("switch readiness", in: source) == 0,
                    "\(path): the old readiness switch must not return")

            // A bypass `switch chain.phase { case .bootstrap: … }` kept beside
            // the shared-sheet call (CF-8): none of the phase-case tokens may
            // appear in the `teleportSetupSheet` body. The scan is scoped to
            // that function so an unrelated future literal elsewhere in these
            // 900+-line hosts cannot false-red the pin.
            let setupSheetBody = try functionRegion(named: "teleportSetupSheet", in: source)
            for token in [".bootstrap", ".registration", ".login", ".ready"] {
                #expect(count(token, in: setupSheetBody) == 0,
                        "\(path): phase-case token \(token) must not appear in teleportSetupSheet")
            }

            // A direct wrapper call beside the shared-sheet call would bypass
            // the single routing switch (the `if readiness == …` re-inline
            // shape the token scan above cannot see).
            for wrapperCall in [
                "TeleportBootstrapSheet(", "TeleportRegistrationSheet(", "TeleportLoginSheet("
            ] {
                #expect(count(wrapperCall, in: source) == 0,
                        "\(path): direct \(wrapperCall) call bypasses the shared routing switch")
            }

            // The call-site composition shape: every invocation label once.
            for label in [
                "initialReadiness:", "reuseNotice:", "makeBootstrapCoordinator:",
                "makeRegistrationCoordinator:", "makeLoginCoordinator:",
                "persistHostLogin:", "onFinish:"
            ] {
                #expect(count(label, in: source) == 1,
                        "\(path): expected exactly one \(label) at the shared-sheet call site")
            }
        }
    }

    // MARK: - Assertion 2: the private wrappers are gone from the hosts

    @Test
    func productionFilesDeclareNoPrivatePhaseWrappers() throws {
        for path in [Self.sidebarPath, Self.iOSListPath, Self.formPath] {
            let source = try strippedSource(at: path)
            for wrapper in [
                "private struct TeleportBootstrapSheet",
                "private struct TeleportRegistrationSheet",
                "private struct TeleportLoginSheet"
            ] {
                #expect(count(wrapper, in: source) == 0,
                        "\(path): \(wrapper) must be deleted (the shared wrapper is internal)")
            }
        }
    }

    // MARK: - Assertion 3: the shared sheet owns the single switch

    @Test
    func sharedSheetOwnsTheSinglePhaseSwitch() throws {
        let source = try strippedSource(at: Self.sheetPath)

        #expect(count("switch chain.phase", in: source) == 1,
                "TeleportSetupSheet.swift: expected exactly one switch chain.phase")
        for wrapper in [
            "struct TeleportBootstrapSheet",
            "struct TeleportRegistrationSheet",
            "struct TeleportLoginSheet"
        ] {
            #expect(count(wrapper, in: source) == 1,
                    "TeleportSetupSheet.swift: expected exactly one \(wrapper)")
        }
        for phaseCase in ["case .bootstrap", "case .registration", "case .login", "case .ready"] {
            #expect(count(phaseCase, in: source) == 1,
                    "TeleportSetupSheet.swift: expected exactly one \(phaseCase)")
        }
    }

    // MARK: - Assertion 4: the harness presents the shared sheet

    @Test
    func harnessPresentsTheSharedSheetAndDeclaresNoMirror() throws {
        let source = try strippedSource(at: Self.harnessPath)

        #expect(count("TeleportSetupSheet(", in: source) == 1,
                "TeleportPhaseChainUITestHarness+iOS.swift: expected exactly one TeleportSetupSheet( invocation")
        #expect(count("switch chain.phase", in: source) == 0,
                "TeleportPhaseChainUITestHarness+iOS.swift: the harness must not re-implement the switch")
        for wrapper in [
            "private struct PhaseChainBootstrapSheet",
            "private struct PhaseChainRegistrationSheet",
            "private struct PhaseChainLoginSheet"
        ] {
            #expect(count(wrapper, in: source) == 0,
                    "TeleportPhaseChainUITestHarness+iOS.swift: \(wrapper) must be deleted")
        }
        for wrapperCall in [
            "TeleportBootstrapSheet(", "TeleportRegistrationSheet(", "TeleportLoginSheet("
        ] {
            #expect(count(wrapperCall, in: source) == 0,
                    "TeleportPhaseChainUITestHarness+iOS.swift: direct \(wrapperCall) call bypasses the shared routing switch")
        }
    }

    // MARK: - Helpers

    private func count(_ token: String, in source: String) -> Int {
        guard !token.isEmpty else { return 0 }
        var count = 0
        var searchRange = source.startIndex..<source.endIndex
        while let range = source.range(of: token, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<source.endIndex
        }
        return count
    }

    /// The brace-balanced body of `private func <name>(`, used to scope the
    /// phase-token scan to the routing function instead of the whole host file.
    private func functionRegion(named name: String, in source: String) throws -> String {
        guard let start = source.range(of: "private func \(name)(") else {
            throw PinFailure("could not find private func \(name)( in the source")
        }
        var depth = 0
        var sawBrace = false
        var index = start.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
                sawBrace = true
            } else if character == "}" {
                depth -= 1
                if sawBrace, depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            }
            index = source.index(after: index)
        }
        throw PinFailure("private func \(name)( is not brace-terminated")
    }

    private func strippedSource(at relativePath: String) throws -> String {
        let url = try Self.repositoryRoot().appendingPathComponent(relativePath)
        do {
            return Self.strippingComments(try String(contentsOf: url, encoding: .utf8))
        } catch {
            throw PinFailure("could not read \(relativePath) at \(url.path): \(error)")
        }
    }

    private static func repositoryRoot() throws -> URL {
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

    /// A Swift comment-stripped copy of `source`: `//` and `/* … */` comments
    /// are blanked (newlines preserved) while string-literal contents are kept.
    /// Duplicated from the other pin suites (each pin file is self-contained
    /// until the shared helper extraction lands).
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
