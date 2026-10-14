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
//  The `repositoryRoot()` / `VVTERM_PINS_SOURCE_ROOT` pin idiom now lives in
//  the shared `PinScan` support (`VVTermTests/PinScanSupport.swift`, issue
//  #450), so the ordinal copy framing is dropped.
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
            // Guard the extractor's signature-shape assumption (closure lens
            // NIT-5): the captured region must be the routing function, not a
            // default-argument closure inside its signature.
            #expect(count("TeleportSetupSheet(", in: setupSheetBody) == 1,
                    "\(path): functionRegion did not capture the teleportSetupSheet body")
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
        let url = try PinScan.repositoryRoot().appendingPathComponent(relativePath)
        do {
            return PinScan.strippingComments(try String(contentsOf: url, encoding: .utf8))
        } catch {
            throw PinFailure("could not read \(relativePath) at \(url.path): \(error)")
        }
    }

}
