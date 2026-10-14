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
//  - The mask is the compact scanner below, not a Swift parser. It models the
//    string and comment forms the corpus uses — `//`, nested `/* … */`, `"…"`,
//    `"""…"""`, raw strings (`#"…"#`, `##"…"##`, `#"""…"""#`) and
//    interpolations (`\( … )`, `\#( … )`) — and fails closed on anything it
//    cannot resolve: an unterminated block comment, string or interpolation
//    records a `cannot analyze` violation naming the file and opening line and
//    restores the tail verbatim. This closes CR-1 (the 120-line blind region
//    where a `/*` in a raw string was "closed" by a `*/` in another string) and
//    CR-2 (a `//` inside a string blanking a same-line declaration); the
//    joined-text declaration scan (CL-3) runs over the masked text, so CR-3's
//    cross-line literal false positive is gone too. Residual left on purpose:
//    a bare Swift regex literal (`/…/`) is not modeled, and the check is still
//    lexical, not semantic.
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
            let supportContent = try String(contentsOf: supportURL, encoding: .utf8)
            let supportMask = maskedCode(supportContent, blankingStringContents: true)
            if let offset = supportMask.unresolvedOffset {
                failures.append(unresolvedViolation(relative: supportFile, offset: offset, content: supportContent))
            }
            for helper in sharedHelpers
            where supportMask.text.range(of: "func\\s+" + helper + "\\s*\\(", options: .regularExpression) == nil {
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
            let codeMask = maskedCode(content, blankingStringContents: true)
            let hookMask = maskedCode(content, blankingStringContents: false)
            if let offset = codeMask.unresolvedOffset ?? hookMask.unresolvedOffset {
                failures.append(unresolvedViolation(relative: relative, offset: offset, content: content))
                continue
            }
            // The declaration scan runs on the string-blanked mask, so a
            // declaration-like token inside a literal is invisible and a `//`
            // inside a literal cannot blank the rest of the line (CR-1/CR-2).
            for helper in migratedHelpers where !allowed.contains(helper) {
                let pattern = "func\\s+" + helper + "\\s*\\("
                for lineNumber in declarationLineNumbers(in: codeMask.text, pattern: pattern) {
                    failures.append(
                        "unexpected declaration: \(relative):\(lineNumber) declares `func \(helper)(`. \(remedy(for: helper))"
                    )
                }
            }
            for (lineNumber, line) in lines(of: codeMask.text) {
                if line.range(of: "struct\\s+PinFailure\\b", options: .regularExpression) != nil {
                    failures.append(
                        "unexpected declaration: \(relative):\(lineNumber) declares `struct PinFailure`. Use the shared `PinFailure` in \(supportFile)."
                    )
                }
            }
            // The hook needle is a string-literal key, so this scan keeps string
            // contents (comments still blanked, string-aware) to catch a stray
            // `environment["VVTERM_PINS_SOURCE_ROOT"]` copy.
            for (lineNumber, line) in lines(of: hookMask.text) where line.contains(hookNeedle) {
                failures.append(
                    "unexpected hook use: \(relative):\(lineNumber) reads `\(hookNeedle)`. Route it through `PinScan.repositoryRoot()` (it is honored there), not a local copy."
                )
            }
        }

        for path in expectedCohort.sorted() {
            let url = repositoryRoot.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                failures.append("missing cohort file: \(path) no longer exists; update the #450 census cohort deliberately if it moved.")
                continue
            }
            let content = try String(contentsOf: url, encoding: .utf8)
            let codeMask = maskedCode(content, blankingStringContents: true)
            if let offset = codeMask.unresolvedOffset {
                failures.append(unresolvedViolation(relative: path, offset: offset, content: content))
                continue
            }
            if !codeMask.text.contains("PinScan.repositoryRoot(") && !codeMask.text.contains("PinScan.source(") {
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
    /// passes the joined, string-and-comment-masked text (`PinScanCensus.maskedCode`),
    /// so a `func` keyword and its name split across a line break are still
    /// caught (fold round 2, CL-3) while the same tokens inside a literal are
    /// invisible (fold round 3, CR-3).
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

    /// The `(1-based line, text)` pairs of `text`, for the per-line scans.
    private static func lines(of text: String) -> [(Int, String)] {
        text.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element) }
    }

    /// The fail-closed diagnostic for an input the mask could not resolve.
    private static func unresolvedViolation(relative: String, offset: Int, content: String) -> String {
        "cannot analyze: \(relative):\(lineNumber(at: offset, in: content)) opens an unterminated string, raw string or block comment; the census masks comments and strings and refuses to analyze past an unresolved construct — close the construct or record the residual deliberately (fail closed)."
    }

    /// The 1-based line containing the character `offset`.
    private static func lineNumber(at offset: Int, in content: String) -> Int {
        var line = 1
        var index = 0
        for character in content {
            if index >= offset { break }
            if character == "\n" { line += 1 }
            index += 1
        }
        return line
    }

    /// The string-and-comment-aware mask over `content`, with fail-closed
    /// uncertainty reporting. `blankingStringContents` blanks comment contents
    /// and (when true) string-literal interiors; the other mode keeps string
    /// interiors — including an interpolation body — verbatim so the
    /// `VVTERM_PINS_SOURCE_ROOT` key literal in a stray copy stays visible,
    /// while still blanking comments string-awarely. Newlines are always
    /// preserved, so line numbers and offsets stay aligned with the input.
    ///
    /// A construct the scanner cannot resolve (an unterminated block comment,
    /// string, raw string or interpolation at end-of-input) sets
    /// `unresolvedOffset`; the mask then restores the tail verbatim, so the
    /// census can never silently blank past an unresolved construct.
    struct MaskedCode {
        /// The masked text; same length and newline structure as the input.
        let text: String
        /// The character offset at which an unterminated construct opened, or
        /// nil when the whole input resolved.
        let unresolvedOffset: Int?
    }

    /// A Swift string delimiter: `N` `#`s followed by one or three `"`s.
    private struct StringDelimiter {
        let hashCount: Int
        let quoteCount: Int
        var length: Int { hashCount + quoteCount }
        var isRaw: Bool { hashCount > 0 }
    }

    static func maskedCode(_ content: String, blankingStringContents: Bool) -> MaskedCode {
        let characters = Array(content)
        var out: [Character] = []
        out.reserveCapacity(characters.count)
        var unresolved: Int? = nil
        _ = maskRange(characters, 0, characters.count, blankingStringContents, &out, &unresolved)
        if let offset = unresolved, offset < characters.count {
            // Never leave a construct we could not resolve blanked: restore the
            // tail verbatim so no code can hide behind the uncertainty.
            out.replaceSubrange(offset..<out.count, with: characters[offset..<characters.count])
        }
        return MaskedCode(text: String(out), unresolvedOffset: unresolved)
    }

    @discardableResult
    private static func maskRange(
        _ characters: [Character],
        _ start: Int,
        _ end: Int,
        _ blankingStringContents: Bool,
        _ out: inout [Character],
        _ unresolved: inout Int?
    ) -> Int {
        var index = start
        var inLineComment = false
        var blockDepth = 0
        var blockOpen = -1
        while index < end {
            let character = characters[index]
            if inLineComment {
                if character == "\n" {
                    out.append("\n")
                    inLineComment = false
                } else {
                    out.append(" ")
                }
                index += 1
                continue
            }
            if blockDepth > 0 {
                if character == "/", index + 1 < end, characters[index + 1] == "*" {
                    blockDepth += 1
                    out.append(" ")
                    out.append(" ")
                    index += 2
                    continue
                }
                if character == "*", index + 1 < end, characters[index + 1] == "/" {
                    blockDepth -= 1
                    out.append(" ")
                    out.append(" ")
                    index += 2
                    if blockDepth == 0 { blockOpen = -1 }
                    continue
                }
                out.append(character == "\n" ? "\n" : " ")
                index += 1
                continue
            }
            if character == "/", index + 1 < end, characters[index + 1] == "/" {
                inLineComment = true
                out.append(" ")
                out.append(" ")
                index += 2
                continue
            }
            if character == "/", index + 1 < end, characters[index + 1] == "*" {
                blockDepth = 1
                blockOpen = index
                out.append(" ")
                out.append(" ")
                index += 2
                continue
            }
            if stringDelimiter(at: index, in: characters, to: end) != nil {
                index = maskString(
                    characters,
                    at: index,
                    to: end,
                    blankingStringContents,
                    &out,
                    &unresolved
                )
                continue
            }
            out.append(character)
            index += 1
        }
        if blockDepth > 0, unresolved == nil { unresolved = blockOpen }
        return index
    }

    private static func stringDelimiter(
        at start: Int,
        in characters: [Character],
        to end: Int
    ) -> StringDelimiter? {
        var cursor = start
        while cursor < end, characters[cursor] == "#" { cursor += 1 }
        guard cursor < end, characters[cursor] == "\"" else { return nil }
        let hashCount = cursor - start
        let quoteCount = (cursor + 2 < end
            && characters[cursor + 1] == "\""
            && characters[cursor + 2] == "\"") ? 3 : 1
        return StringDelimiter(hashCount: hashCount, quoteCount: quoteCount)
    }

    /// Masks the string literal opening at `start`, blanking its interior when
    /// `blankingStringContents` is set and recursing into interpolation bodies
    /// (`\( … )` for quoted strings, `\#( … )` for raw strings) so their code
    /// stays visible. Returns the index just past the closing delimiter, or
    /// `end` for an unterminated literal (recorded in `unresolved`).
    private static func maskString(
        _ characters: [Character],
        at start: Int,
        to end: Int,
        _ blankingStringContents: Bool,
        _ out: inout [Character],
        _ unresolved: inout Int?
    ) -> Int {
        guard let delimiter = stringDelimiter(at: start, in: characters, to: end) else {
            return start
        }
        appendMasked(delimiter.length, blankingStringContents, from: characters, at: start, to: &out)
        var index = start + delimiter.length
        while index < end {
            if let closeLength = closingDelimiterLength(delimiter, at: index, in: characters, to: end) {
                appendMasked(closeLength, blankingStringContents, from: characters, at: index, to: &out)
                return index + closeLength
            }
            let character = characters[index]
            if character == "\\" {
                if delimiter.isRaw {
                    var cursor = index + 1
                    var hashes = 0
                    while cursor < end, hashes < delimiter.hashCount, characters[cursor] == "#" {
                        hashes += 1
                        cursor += 1
                    }
                    if hashes == delimiter.hashCount, cursor < end, characters[cursor] == "(" {
                        index = maskInterpolation(
                            characters,
                            openingBackslash: index,
                            bodyStart: cursor + 1,
                            to: end,
                            stringStart: start,
                            blankingStringContents,
                            &out,
                            &unresolved
                        )
                        continue
                    }
                    appendMasked(1, blankingStringContents, from: characters, at: index, to: &out)
                    index += 1
                    continue
                }
                if index + 1 < end, characters[index + 1] == "(" {
                    index = maskInterpolation(
                        characters,
                        openingBackslash: index,
                        bodyStart: index + 2,
                        to: end,
                        stringStart: start,
                        blankingStringContents,
                        &out,
                        &unresolved
                    )
                    continue
                }
                let count = min(2, end - index)
                appendMasked(count, blankingStringContents, from: characters, at: index, to: &out)
                index += count
                continue
            }
            appendMasked(1, blankingStringContents, from: characters, at: index, to: &out)
            index += 1
        }
        if unresolved == nil { unresolved = start }
        return end
    }

    private static func maskInterpolation(
        _ characters: [Character],
        openingBackslash: Int,
        bodyStart: Int,
        to end: Int,
        stringStart: Int,
        _ blankingStringContents: Bool,
        _ out: inout [Character],
        _ unresolved: inout Int?
    ) -> Int {
        guard let close = interpolationClose(characters, from: bodyStart, to: end) else {
            if unresolved == nil { unresolved = stringStart }
            appendMasked(
                end - openingBackslash,
                blankingStringContents,
                from: characters,
                at: openingBackslash,
                to: &out
            )
            return end
        }
        appendMasked(
            bodyStart - openingBackslash,
            blankingStringContents,
            from: characters,
            at: openingBackslash,
            to: &out
        )
        // The interpolation body is code: mask it recursively in the same mode.
        _ = maskRange(characters, bodyStart, close, blankingStringContents, &out, &unresolved)
        appendMasked(1, blankingStringContents, from: characters, at: close, to: &out)
        return close + 1
    }

    /// The length of the closing delimiter of `delimiter` at `start`, or nil.
    private static func closingDelimiterLength(
        _ delimiter: StringDelimiter,
        at start: Int,
        in characters: [Character],
        to end: Int
    ) -> Int? {
        let closeLength = delimiter.quoteCount + delimiter.hashCount
        guard start + closeLength <= end else { return nil }
        for offset in 0..<delimiter.quoteCount where characters[start + offset] != "\"" { return nil }
        for offset in 0..<delimiter.hashCount where characters[start + delimiter.quoteCount + offset] != "#" {
            return nil
        }
        return closeLength
    }

    /// The index of the `)` matching the interpolation whose body starts at
    /// `start`, or nil when it never closes. Strings inside the body are
    /// skipped so a `"` or `)` in a nested literal cannot close the outer
    /// interpolation.
    private static func interpolationClose(
        _ characters: [Character],
        from start: Int,
        to end: Int
    ) -> Int? {
        var depth = 0
        var index = start
        while index < end {
            let character = characters[index]
            if character == "(" || character == "[" || character == "{" {
                depth += 1
                index += 1
            } else if character == ")" {
                if depth == 0 { return index }
                depth -= 1
                index += 1
            } else if character == "]" || character == "}" {
                if depth > 0 { depth -= 1 }
                index += 1
            } else if let delimiter = stringDelimiter(at: index, in: characters, to: end) {
                guard let after = stringSkipEnd(characters, at: index, delimiter: delimiter, to: end) else {
                    return nil
                }
                index = after
            } else {
                index += 1
            }
        }
        return nil
    }

    /// The index just past the string literal opening at `start`, or nil when
    /// it is unterminated. Used only to skip nested literals.
    private static func stringSkipEnd(
        _ characters: [Character],
        at start: Int,
        delimiter: StringDelimiter,
        to end: Int
    ) -> Int? {
        var index = start + delimiter.length
        while index < end {
            if let closeLength = closingDelimiterLength(delimiter, at: index, in: characters, to: end) {
                return index + closeLength
            }
            let character = characters[index]
            if character == "\\" {
                if delimiter.isRaw {
                    var cursor = index + 1
                    var hashes = 0
                    while cursor < end, hashes < delimiter.hashCount, characters[cursor] == "#" {
                        hashes += 1
                        cursor += 1
                    }
                    if hashes == delimiter.hashCount, cursor < end, characters[cursor] == "(" {
                        guard let close = interpolationClose(characters, from: cursor + 1, to: end) else {
                            return nil
                        }
                        index = close + 1
                        continue
                    }
                    index += 1
                    continue
                }
                if index + 1 < end, characters[index + 1] == "(" {
                    guard let close = interpolationClose(characters, from: index + 2, to: end) else {
                        return nil
                    }
                    index = close + 1
                    continue
                }
                index += 2
                continue
            }
            index += 1
        }
        return nil
    }

    /// Appends `count` characters from `start`, blanking every non-newline one
    /// when `blanking` is set and copying them verbatim otherwise.
    private static func appendMasked(
        _ count: Int,
        _ blanking: Bool,
        from characters: [Character],
        at start: Int,
        to out: inout [Character]
    ) {
        guard count > 0 else { return }
        for offset in 0..<count {
            let character = characters[start + offset]
            if blanking {
                out.append(character == "\n" ? "\n" : " ")
            } else {
                out.append(character)
            }
        }
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
