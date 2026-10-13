// SPDX-License-Identifier: MIT
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
//    raw-string-aware `PinScan.strippingComments`. The unterminated-`/*`-inside-
//    a-string-literal desync is closed (fold round 2, CL-1): a `/*` starts a
//    block comment only when a closing `*/` exists later in the file, so an
//    unterminated one cannot swallow the remainder, and the declaration scan
//    runs over the joined stripped text (CL-3), so a `func` and its name split
//    across a line break are still caught. Residuals left on purpose: a `/*`
//    inside a string literal that *is* later "closed" by any `*/` in the file
//    still enters block mode and can hide the lines in between, and a `//`-like
//    sequence inside a string still blanks the rest of that line; a real
//    declaration is always in code, and the golden lexer corpus carries the
//    string-aware semantic contract.
//  - It cannot see the pre-existing inline depth-based root resolvers that
//    never declared a migrated name and never read the hook
//    (`TeleportLoginClientErrorShapeTests`, `StartupDeadlineTests`,
//    `TerminfoResourcesTests`, `LoopbackTLSServerTestSupport`); they are
//    outside the declared #450 universe (plan §1), not a regression.
//  - It proves structure (no local copies; the hook is centralized), not
//    semantics. The golden lexer corpus is the semantic contract.
//  - The cohort list is a deliberate record: `PinScanCensusPinsTests` asserts
//    its size and digest, so editing `expectedCohort` is not a silent defeat.

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

    /// Helpers the shared support declares, and the only names a local copy
    /// may not redeclare. Each must exist in `supportFile` (asserted below), so
    /// deleting the shared definition cannot pass.
    static let sharedHelpers = [
        "repositoryRoot", "source", "strippingComments",
        "strippingYAMLComments", "normalizedWhitespace", "isInside",
    ]

    /// Names that must not be redeclared locally but have no shared
    /// replacement to migrate to: `workflowSource` becomes `PinScan.source(_:)`
    /// and the two `strippingCommentsAndStrings` scanners stay per-suite.
    static let localOnlyHelpers = ["workflowSource", "strippingCommentsAndStrings"]

    /// Every name the scan forbids outside `supportFile`.
    static var migratedHelpers: [String] { sharedHelpers + localOnlyHelpers }

    /// The recorded size of `expectedCohort`; the change-detector baseline for
    /// `expectedCohortDigest`. Editing the cohort list must update both.
    static let expectedCohortCount = 38

    /// The recorded FNV-1a fingerprint of the sorted, newline-joined cohort
    /// list. A change-detector: any edit to `expectedCohort` must update this
    /// value deliberately, so dropping a cohort file cannot pass silently.
    static let expectedCohortDigest = "bdc45b4f51478bbe"

    /// The fingerprint of the current `expectedCohort` (FNV-1a 64 over the
    /// sorted, newline-joined paths, as 16-digit lowercase hex).
    static func cohortDigest() -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in expectedCohort.sorted().joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// An allowlisted local declaration: the names excused in that file and the
    /// reason, interpolated into any new-copy diagnostic in another file.
    struct AllowlistEntry {
        let helpers: Set<String>
        let reason: String
    }

    /// Non-empty by design: the hash/interpolation-aware scanners stay local.
    static let allowlist: [String: AllowlistEntry] = [
        "VVTermTests/SSH/SSHProbeShellPinsTests.swift": AllowlistEntry(
            helpers: ["strippingComments", "strippingCommentsAndStrings"],
            reason: "its hash/interpolation-aware `strippingComments` is provably not equivalent to the canonical `PinScan.strippingComments` (the raw-string cases in the differential and the golden corpus), and its `strippingCommentsAndStrings` call-form scanner is a genuinely different per-suite lexer"
        ),
        "VVTermTests/WorkflowShardSplitPinsTests.swift": AllowlistEntry(
            helpers: ["strippingCommentsAndStrings"],
            reason: "its `strippingCommentsAndStrings` call-form scanner is a genuinely different per-suite lexer that the canonical `PinScan.strippingComments` does not replace"
        ),
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

        // The support file must itself declare every shared helper. The
        // declaration scan below only proves absence *elsewhere*, so deleting
        // the shared definition would otherwise stay green.
        let supportURL = repositoryRoot.appendingPathComponent(supportFile)
        if FileManager.default.fileExists(atPath: supportURL.path) {
            let supportCode = strippingLineComments(
                try String(contentsOf: supportURL, encoding: .utf8)
            ).map(\.1).joined(separator: "\n")
            for helper in sharedHelpers
            where supportCode.range(of: "func\\s+" + helper + "\\s*\\(", options: .regularExpression) == nil {
                failures.append(
                    "missing shared declaration: \(supportFile) does not declare `func \(helper)(`. The shared helper was deleted or renamed; restore it or update the census deliberately."
                )
            }
        } else {
            failures.append(
                "missing shared support: \(supportFile) does not exist; the shared pin-scan helpers have no home."
            )
        }

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            let relative = relativePath(file, root: repositoryRoot)
            if censusFiles.contains(relative) { continue }

            let allowed = allowlist[relative]?.helpers ?? []
            let strippedLines = strippingLineComments(content)
            let joinedCode = strippedLines.map(\.1).joined(separator: "\n")
            for helper in migratedHelpers where !allowed.contains(helper) {
                let pattern = "func\\s+" + helper + "\\s*\\("
                for lineNumber in declarationLineNumbers(in: joinedCode, pattern: pattern) {
                    failures.append(
                        "unexpected declaration: \(relative):\(lineNumber) declares `func \(helper)(`. \(remedy(for: helper))"
                    )
                }
            }
            for (lineNumber, line) in strippedLines {
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
            if !code.contains("PinScan.repositoryRoot(") && !code.contains("PinScan.source(") {
                failures.append(
                    "cohort file no longer resolves its root through PinScan: \(path) has neither a `PinScan.repositoryRoot(` nor a `PinScan.source(` call in code; the migration for this file was reverted or rewritten."
                )
            }
        }

        return failures
    }

    /// The migration remedy for a redeclared helper, plus (for a genuinely
    /// local scanner) the reason its existing allowlisted copy stays local.
    /// `workflowSource` points at `PinScan.source(_:)` because there is no
    /// `PinScan.workflowSource` to migrate to.
    private static func remedy(for helper: String) -> String {
        let migration: String
        if sharedHelpers.contains(helper) {
            migration = "Migrate it to `PinScan.\(helper)`"
        } else if helper == "workflowSource" {
            migration = "Migrate it to `PinScan.source(_:)` (there is no `PinScan.workflowSource`)"
        } else {
            migration = "Keep it only if it is a genuinely different scanner"
        }
        let existing = allowlist
            .filter { $0.value.helpers.contains(helper) }
            .map { "\($0.key) is allowlisted because \($0.value.reason)" }
            .sorted()
            .first
        let note = existing.map { " The existing copy in \($0)." } ?? ""
        return "\(migration).\(note) Otherwise allowlist this file with a reason."
    }

    /// The 1-based line numbers in `code` where `pattern` matches. The caller
    /// passes the joined, comment-stripped text (the same form as the
    /// support-file presence check), so a `func` keyword and its name split
    /// across a line break are still caught (fold round 2, CL-3). The pattern
    /// is not string-aware, so a literal `"func <helper>("` would be a false
    /// positive — the fail-closed direction the census wants.
    private static func declarationLineNumbers(in code: String, pattern: String) -> [Int] {
        var lineNumbers: [Int] = []
        var searchStart = code.startIndex
        while searchStart < code.endIndex,
              let match = code.range(of: pattern, options: .regularExpression, range: searchStart..<code.endIndex) {
            let lineNumber = code[..<match.lowerBound].reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
            lineNumbers.append(lineNumber)
            searchStart = match.upperBound
        }
        return lineNumbers
    }

    /// A minimal line-based comment stripper: returns `(lineNumber, code)` with
    /// `//` line comments and `/* … */` block comments removed. It deliberately
    /// does NOT try to understand string literals — the census scans for
    /// declaration and environment-variable tokens that only ever appear in
    /// code, and a string-aware stripper (the shared lexer) can desynchronize
    /// on raw strings and silently hide code. An unterminated `/*` (including
    /// one inside a string literal) starts a block comment only when a `*/`
    /// exists later in the file; otherwise it is left as literal text, so it
    /// cannot swallow the rest of the file (fold round 2, CL-1).
    private static func strippingLineComments(_ content: String) -> [(Int, String)] {
        let lines = content.components(separatedBy: "\n")
        var out: [(Int, String)] = []
        var inBlockComment = false
        for (index, raw) in lines.enumerated() {
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
                // No `*/` on this line: only a block that actually closes later in
                // the file may swallow the following lines. An unterminated `/*`
                // (e.g. inside a string literal) is left as literal text and must
                // not hide the rest of the file.
                let tail = String(line[bs.upperBound...]) + "\n"
                    + lines[(index + 1)...].joined(separator: "\n")
                if tail.contains("*/") {
                    line = String(line[..<bs.lowerBound])
                    inBlockComment = true
                }
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
