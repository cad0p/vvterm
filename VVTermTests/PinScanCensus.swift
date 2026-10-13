//  PinScanCensus.swift
//
//  The pure logic behind `PinScanCensusPinsTests`. Kept free of the Testing
//  framework so the same scan can be compiled and run standalone against a
//  mutated tree (the #450 mutation battery).
//
//  Defeat list (what this check does NOT prove):
//  - It is name-based. A residual copy that renames its helper (`func repoRoot`,
//    `func scan`) or inlines a lexer body passes.
//  - The comment stripper is the minimal line-based one below, not the
//    raw-string-aware `PinScan.strippingComments`: a declaration hidden in a
//    string literal is not found (a real declaration is always in code).
//  - It proves structure (no local copies; the hook is centralized), not
//    semantics. The golden lexer corpus is the semantic contract.

import Foundation

enum PinScanCensus {
    /// The census cohort at the #450 fold head: every `VVTermTests` file that
    /// declared one of the migrated helpers (or carried the inline resolver).
    /// After the migration each still routes through `PinScan.`.
    static let expectedCohort: Set<String> = [
        "VVTermTests/ClipboardListingMetadataOnlyPinsTests.swift",
        "VVTermTests/Core/CoreAppIsolatedDeinitPinsTests.swift",
        "VVTermTests/Features/FeaturesIsolatedDeinitPinsTests.swift",
        "VVTermTests/Features/Stats/StatsIsolatedDeinitReleaseTests.swift",
        "VVTermTests/Features/Teleport/TeleportBootstrapViewWiringTests.swift",
        "VVTermTests/Features/Teleport/TeleportCredentialPairPinsTests.swift",
        "VVTermTests/Features/Teleport/TeleportLoginDismissalWiringTests.swift",
        "VVTermTests/Features/Teleport/TeleportPhaseTransitionWaitBudgetPinsTests.swift",
        "VVTermTests/Features/Teleport/TeleportRedactionTests.swift",
        "VVTermTests/Features/Teleport/TeleportSetupSheetPinsTests.swift",
        "VVTermTests/Features/TerminalSessions/TerminalKeyboardCoordinatorPinsTests.swift",
        "VVTermTests/Features/TerminalSessions/TerminalSessionsIsolatedDeinitPinsTests.swift",
        "VVTermTests/GhosttyGeneratedConfigFixturePinsTests.swift",
        "VVTermTests/GhosttyIsolatedDeinitPinsTests.swift",
        "VVTermTests/GhosttyPatchQueuePinsTests.swift",
        "VVTermTests/GhosttyProcessEnvironmentTripwireTests.swift",
        "VVTermTests/GhosttySurfaceUserdataLifetimePinsTests.swift",
        "VVTermTests/KeyboardModeSwitchTapRecoveryPinsTests.swift",
        "VVTermTests/ServerNavigationUITestsWaitBudgetPinsTests.swift",
        "VVTermTests/SSH/SSHExecGateLivenessPinsTests.swift",
        "VVTermTests/SSH/SSHFSFTPLoopLivenessPinsTests.swift",
        "VVTermTests/SSH/SSHProbeShellPinsTests.swift",
        "VVTermTests/SSH/SSHProxyChannelFreePinsTests.swift",
        "VVTermTests/SSH/SSHShellLoopLivenessPinsTests.swift",
        "VVTermTests/SSH/SSHUploadChannelFreePinsTests.swift",
        "VVTermTests/SSH/SSHUploadIntegrationConnectBudgetPinsTests.swift",
        "VVTermTests/SSH/SSHUploadLoopLivenessPinsTests.swift",
        "VVTermTests/SSH/TeleportAgentForwardingPinsTests.swift",
        "VVTermTests/SSH/TeleportE2EPhaseFailureTests.swift",
        "VVTermTests/SSHErrorDiagnosticsTests.swift",
        "VVTermTests/SSHTLSTransportPumpFDCloserTests.swift",
        "VVTermTests/TerminalReconnectTapDeliveryPinsTests.swift",
        "VVTermTests/WorkflowArtifactDependencyClassGatePinsTests.swift",
        "VVTermTests/WorkflowArtifactDependencyPinsTests.swift",
        "VVTermTests/WorkflowPerPREventGatePinsTests.swift",
        "VVTermTests/WorkflowPrepareXcodeBuildPinsTests.swift",
        "VVTermTests/WorkflowShardSplitPinsTests.swift",
        "VVTermTests/WorkflowXcodebuildFlagPinsTests.swift",
    ]

    /// The shared support is the only legal home for the migrated helpers.
    static let supportFile = "VVTermTests/PinScanSupport.swift"

    /// Names that must not be declared outside `supportFile`.
    static let migratedHelpers = [
        "repositoryRoot", "source", "workflowSource", "strippingComments",
        "strippingYAMLComments", "normalizedWhitespace", "isInside",
    ]

    /// Non-empty by design: the hash/interpolation-aware scanner stays local.
    static let allowlist: [String: Set<String>] = [
        "VVTermTests/SSH/SSHProbeShellPinsTests.swift": ["strippingComments"],
    ]

    static func violations(repositoryRoot: URL) throws -> [String] {
        var failures: [String] = []
        let testsRoot = repositoryRoot.appendingPathComponent("VVTermTests")
        let files = try swiftFiles(under: testsRoot, root: repositoryRoot)

        // A path that is neither the shared support nor the census machinery
        // itself is scanned for declarations and hook references.
        let censusFiles: Set<String> = [
            supportFile,
            "VVTermTests/PinScanCensus.swift",
            "VVTermTests/PinScanCensusPinsTests.swift",
        ]
        let hookNeedle = "VVTERM_PINS_" + "SOURCE_ROOT"

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            let relative = relativePath(file, root: repositoryRoot)
            if censusFiles.contains(relative) { continue }

            let allowed = allowlist[relative] ?? []
            for (lineNumber, line) in strippingLineComments(content) {
                for helper in migratedHelpers where !allowed.contains(helper) {
                    let pattern = "func\\s+" + helper + "\\s*\\("
                    if line.range(of: pattern, options: .regularExpression) != nil {
                        failures.append(
                            "unexpected declaration: \(relative):\(lineNumber) declares `func \(helper)(`. Migrate it to `PinScan.\(helper)` or allowlist it with a reason."
                        )
                    }
                }
                if line.range(of: "struct\\s+PinFailure\\b", options: .regularExpression) != nil {
                    failures.append(
                        "unexpected declaration: \(relative):\(lineNumber) declares `struct PinFailure`. Use the shared `PinFailure` in \(supportFile)."
                    )
                }
                if line.contains(hookNeedle) {
                    failures.append(
                        "unexpected hook use: \(relative):\(lineNumber) reads `\(hookNeedle)`. Route it through `PinScan.repositoryRoot()` (it is honored there), not a local copy."
                    )
                }
            }
        }

        for path in expectedCohort.sorted() {
            let url = repositoryRoot.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                failures.append("missing cohort file: \(path) no longer exists; update the #450 census cohort deliberately if it moved.")
                continue
            }
            let content = try String(contentsOf: url, encoding: .utf8)
            let code = strippingLineComments(content).map(\.1).joined(separator: "\n")
            if !code.contains("PinScan.") {
                failures.append(
                    "cohort file no longer routes through PinScan: \(path) has no `PinScan.` call in code; the migration for this file was reverted or rewritten."
                )
            }
        }

        return failures
    }

    /// A minimal line-based comment stripper: returns `(lineNumber, code)` with
    /// `//` line comments and `/* … */` block comments removed. It deliberately
    /// does NOT try to understand string literals — the census scans for
    /// declaration and environment-variable tokens that only ever appear in
    /// code, and a string-aware stripper (the shared lexer) can desynchronize
    /// on raw strings and silently hide code.
    private static func strippingLineComments(_ content: String) -> [(Int, String)] {
        var out: [(Int, String)] = []
        var inBlockComment = false
        for (index, raw) in content.components(separatedBy: "\n").enumerated() {
            var line = raw
            if inBlockComment {
                if let end = line.range(of: "*/") {
                    line = String(line[end.upperBound...])
                    inBlockComment = false
                } else {
                    out.append((index + 1, ""))
                    continue
                }
            }
            while true {
                let blockStart = line.range(of: "/*")
                let lineComment = line.range(of: "//")
                if let lc = lineComment, blockStart == nil || lc.lowerBound < blockStart!.lowerBound {
                    line = String(line[..<lc.lowerBound])
                    break
                }
                guard let bs = blockStart else { break }
                if let end = line.range(of: "*/", range: bs.upperBound..<line.endIndex) {
                    line = String(line[..<bs.lowerBound]) + String(line[end.upperBound...])
                    continue
                }
                line = String(line[..<bs.lowerBound])
                inBlockComment = true
                break
            }
            out.append((index + 1, line))
        }
        return out
    }

    private static func swiftFiles(under directory: URL, root: URL) throws -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let resolvedURL = url.resolvingSymlinksInPath().path
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        if resolvedURL.hasPrefix(prefix) {
            return String(resolvedURL.dropFirst(prefix.count))
        }
        return resolvedURL
    }
}
