// SPDX-License-Identifier: MIT
//
//  SSHProbeShellPinsTests.swift
//  VVTermTests
//
//  Placement pins for #323 ("run the tmux/mosh capability probes in non-login
//  shells") and #324 ("run the remaining parsed probes in non-login shells"):
//  every parsed probe must be built by
//  `RemoteTerminalBootstrap.wrapPOSIXProbeCommand`, and the only remaining
//  login-shell emitters must sit in the intentional-login allowlists below.
//  This is the CI-enforced protection against a literal-token,
//  login-emitter, or login-wrapper recurrence of #121 -> #323 -> #324 across
//  every Swift source root of the `VVTerm` app target — `VVTerm/` and
//  `VVTermShared/` today, enumerated from `VVTerm.xcodeproj` rather than
//  hardcoded, so a new synchronized root is swept and reddens the roots pin
//  until it is consciously allowlisted (the behavioural route cannot run on
//  iOS).
//
//  WHAT THESE PINS ASSERT (and what they do not see). Five pins, all
//  stripped of comments first:
//    ROOTS. the app-target scan roots themselves: the `VVTerm` native
//       target's `fileSystemSynchronizedGroups` must be exactly `VVTerm/` +
//       `VVTermShared/`; a new synchronized root reddens here and is already
//       swept by `allSwiftFiles()`. Because a classic `PBXGroup` +
//       `Sources`-phase file would compile into the target *without* being
//       swept, this pin also asserts that the target's `Sources` phase has no
//       non-synchronized Swift file references and fails closed if one
//       appears — the scan root can never silently widen past the sweep.
//    A. a recursive `.swift` scan of every app-target root: the login tokens
//       (a shell name — or `$SHELL` / `${SHELL}` — followed by a login flag,
//       whitespace- and `\t`-escape-tolerant — this covers `sh -lc`,
//       `sh -l -c`, `sh --login -c`, `fish -lc`, `csh -lc`, `exec "$SHELL" -l`)
//       may appear only in the Mosh 4 / Tmux 3 / Bootstrap 7 file allowlist,
//       and the login-shell emitters (`defaultLoginShellCommand(`,
//       `exec "${SHELL:-/bin/sh}" -l`, the `$SHELL` exec fallback) only in the
//       emitter allowlist; inside the three login-shell files the token may
//       appear only inside the enumerated function bodies, and the emitter
//       files have a per-function/occurrence/declaration allowlist of their
//       own.
//    B. a recursive `.swift` scan of every app-target root for the call form
//       `wrapPOSIXShellCommand(` (whitespace-tolerant before the paren),
//       scanned after string contents are blanked out: the only files that
//       may call it are `RemoteEnvironmentResolver` (2 calls in
//       `launchPlan`), `RemoteTmuxManager` (1 call in
//       `createSessionCommand`) and `RemoteTerminalBootstrap` (the
//       declaration); a new function or a file-scope binding inside an
//       allowlisted file reddens, and the two clipboard files that #324
//       converted must stay at zero.
//    C. the converted files: `wrapPOSIXProbeCommand(` occurrence counts are
//       exact per file (this covers the five `static let` commands and
//       multi-call functions), `wrapPOSIXShellCommand` is at zero, and every
//       true `func` builder named in `probeBuilders` still calls the non-login
//       wrapper. (`cpuSnapshotCommand`/`processDetailsCommand` build bodies
//       and never call the wrapper, so they are deliberately not builders.)
//    D. the wrapper itself: `wrapPOSIXProbeCommand`'s output keeps the
//       `sh -c '` prefix and carries the curated system PATH export
//       (`shellSystemPathExport()`), and its source body injects that export.
//    E. the full user PATH (`shellPathExport()`, which puts
//       `$HOME/.local/bin` first): only the enumerated pre-#324 bodies may
//       self-export it; a body converted by #324 must not re-add it, or it
//       would re-promote `$HOME/.local/bin` ahead of the curated system dirs.
//
//  WHAT THE SCANNER CANNOT SEE. The pins are a tripwire, not a proof.
//  Comments are stripped everywhere. For the call-form pins (B, C, E) the
//  contents of string literals are blanked out as well — a string containing
//  `wrapPOSIXShellCommand(` therefore cannot satisfy a call pin — while
//  interpolation bodies are kept as code and scanned recursively, because a
//  real call inside an interpolation is the production pattern, not a decoy:
//  `\( … )` in a one-line or multi-line string, and `\#( … )` (the matching
//  hash count for `##" … "##`, …) in a raw string. The blanker is still not a
//  tokenizer: raw strings, one-line strings and multi-line strings are
//  recognized, but a default-argument closure in a `func` declaration can
//  still make the body walk bind the wrong block. Pin E sweeps the
//  string-verbatim copy for the hand-rolled `$HOME/.local/bin` literal and
//  the blanked copy for the `shellPathExport(` call, so neither spelling is
//  invisible to it. Remaining defeats: braces inside string literals are
//  counted by the block walk (balanced in these files today), a login-shell
//  token assembled at runtime is invisible, a wrapper *reference* bound
//  without a call (`let wrap = …wrapPOSIXShellCommand; wrap(x)`), a call text
//  assembled from concatenated identifier pieces
//  (`"wrapPOSIX" + "ShellCommand("`), a `shellPathExport` reference bound
//  without a call (`let e = …shellPathExport; e()`), a converted body that
//  composes a `$HOME/.local/bin` PATH export without spelling the literal (a
//  variable or an interpolation), and a dead-branch builder call
//  (`if false { _ = wrapPOSIXProbeCommand(body) }`) that satisfies pin C's
//  builder-call assertion as long as the file-level count is preserved. The
//  `$SHELL`/`SHELL` token branch requires a command-position boundary; the
//  shell-name branch keeps word-boundary semantics, so a shell name in a
//  non-exec context (`echo sh -lc`) is an accepted fail-closed over-match. A
//  commented-out token cannot satisfy the pins (comments are stripped). Any
//  intentional login site added later must be added to the allowlists below
//  deliberately.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the suite at a
//  mutated tree. Measured in `SSHExecGateLivenessPinsTests` on this runner: a
//  plain env var is inert; export
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` into xcodebuild's own
//  environment to reach the simulator test process (or hand-mutate the
//  worktree and restore it).
//

import Foundation
import Testing

@testable import VVTerm

struct SSHProbeShellPinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSH/SSHProbeShellPinsTests.swift`).
    private func repositoryRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHProbeShellPinsTests.swift
            .deletingLastPathComponent()  // SSH/
            .deletingLastPathComponent()  // VVTermTests/
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// The Swift source roots that compile into the `VVTerm` app target,
    /// enumerated live from `VVTerm.xcodeproj`: the root groups in the
    /// `VVTerm` native target's `fileSystemSynchronizedGroups`. Today this is
    /// exactly `["VVTerm", "VVTermShared"]`.
    /// `testAppTargetSweepRootsArePinned` fails closed when the set changes,
    /// and `allSwiftFiles()` sweeps every enumerated root, so a probe cannot
    /// enter the module through an unwatched root — the new root is swept
    /// before it is allowlisted. A non-synchronized Swift file (a classic
    /// `PBXGroup` reference in the target's `Sources` phase) is *not* under a
    /// root, so the same pin asserts there is none: the target's Sources
    /// phase is enumerated too and must contribute zero Swift files.
    private static let expectedAppTargetSourceRoots = ["VVTerm", "VVTermShared"]

    /// The app target's Swift source roots, read from the Xcode project. An
    /// empty result (project unreadable, target not found) fails the roots
    /// pin and the sweep's missing-file checks, never a vacuous pass.
    private func appTargetSourceRoots() -> [String] {
        let projectURL = repositoryRoot()
            .appendingPathComponent("VVTerm.xcodeproj/project.pbxproj")
        guard let project = try? String(contentsOf: projectURL, encoding: .utf8) else {
            return []
        }

        var pathsByGroupID: [String: String] = [:]
        for group in Self.pbxEntries(in: project, isa: "PBXFileSystemSynchronizedRootGroup") {
            guard let path = Self.pbxValue(forKey: "path", in: group.body) else { continue }
            pathsByGroupID[group.id] = path
        }

        for target in Self.pbxEntries(in: project, isa: "PBXNativeTarget") {
            guard Self.pbxValue(forKey: "name", in: target.body) == "VVTerm",
                  let groups = Self.pbxValue(forKey: "fileSystemSynchronizedGroups", in: target.body)
            else { continue }
            return Self.hexIdentifiers(in: groups)
                .compactMap { pathsByGroupID[$0] }
                .sorted()
        }
        return []
    }

    /// Every `id = { … }` entry in `project` whose body declares
    /// `isa = <isa>;`.
    private static func pbxEntries(
        in project: String,
        isa: String
    ) -> [(id: String, body: String)] {
        let pattern = #"([0-9A-F]{24})[^=]*= \{([^}]*)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(project.startIndex..<project.endIndex, in: project)
        return regex.matches(in: project, range: range).compactMap { match in
            guard let idRange = Range(match.range(at: 1), in: project),
                  let bodyRange = Range(match.range(at: 2), in: project)
            else { return nil }
            let body = String(project[bodyRange])
            guard body.contains("isa = \(isa);") else { return nil }
            return (String(project[idRange]), body)
        }
    }

    /// The value of a `key = value;` assignment inside a PBX entry body. The
    /// match must be preceded by a token boundary (start of body or
    /// whitespace), so `fileRef` cannot match the `fileReference` key and
    /// `name` cannot match a comment's `name` text.
    private static func pbxValue(forKey key: String, in body: String) -> String? {
        guard let exact = body.range(of: "\(key) = "),
              exact.lowerBound == body.startIndex
                || body[body.index(before: exact.lowerBound)].isWhitespace,
              let end = body[exact.upperBound...].firstIndex(of: ";")
        else { return nil }
        return String(body[exact.upperBound..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every 24-hex-character PBX identifier in `text`.
    private static func hexIdentifiers(in text: String) -> [String] {
        let pattern = #"[0-9A-F]{24}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - String-aware scanning

    /// A copy of `source` whose string-literal *contents* are blanked out
    /// (delimiters and newlines kept), on top of the comment stripping. The
    /// scan reads this so a string literal — including a call-form literal
    /// such as `"wrapPOSIXShellCommand("` — cannot satisfy pin B/C/E's
    /// call-form assertions. The blanker recognizes one-line, multi-line and
    /// raw strings, and keeps interpolation bodies as code by scanning them
    /// recursively — `\( … )` for the quoted strings and `\#( … )` (hash
    /// count matched) for raw strings — so a call interpolated into a command
    /// string is still counted.
    private static func strippingCommentsAndStrings(_ source: String) -> String {
        Self.scanning(source, blankingStringContents: true)
    }

    /// Every `.swift` file under every app-target source root (see
    /// `appTargetSourceRoots()`), as repository-relative paths, recursively,
    /// plus the target's non-synchronized `Sources`-phase Swift references
    /// (`appTargetNonSynchronizedSwiftFileReferences()`), which the roots pin
    /// requires to be empty. The paths are the fail-closed scope: a new file
    /// anywhere in the app target must be consciously allowlisted before it
    /// can emit a login shell or reference the login wrapper.
    private func allSwiftFiles() -> [ScannedFile] {
        var result: [ScannedFile] = []
        for root in appTargetSourceRoots() {
            let directory = repositoryRoot().appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
                continue
            }
            while let relativePath = enumerator.nextObject() as? String {
                guard relativePath.hasSuffix(".swift") else { continue }
                result.append(
                    ScannedFile(path: "\(root)/\(relativePath)", isSynchronized: true)
                )
            }
        }
        for path in appTargetNonSynchronizedSwiftFileReferences().paths {
            result.append(ScannedFile(path: path, isSynchronized: false))
        }
        return result.sorted { $0.path < $1.path }
    }

    /// One swept source file and whether it lives under a synchronized root.
    private struct ScannedFile {
        let path: String
        let isSynchronized: Bool
    }

    /// The target's non-synchronized `Sources`-phase Swift files plus whether
    /// the `Sources` phase resolved at all. The paths are the classic
    /// `PBXGroup` + `PBXBuildFile` references that compile into the `VVTerm`
    /// target without belonging to a `fileSystemSynchronizedGroups` root, so
    /// `allSwiftFiles()` would never sweep them. The roots pin requires the
    /// paths to be empty *and* `resolved` to be true: when the project, the
    /// target, its `buildPhases`, or the `PBXSourcesBuildPhase` entries cannot
    /// be read, the empty path list would otherwise fail open.
    private struct NonSynchronizedSources {
        let paths: [String]
        let resolved: Bool
    }

    private func appTargetNonSynchronizedSwiftFileReferences() -> NonSynchronizedSources {
        let projectURL = repositoryRoot()
            .appendingPathComponent("VVTerm.xcodeproj/project.pbxproj")
        guard let project = try? String(contentsOf: projectURL, encoding: .utf8) else {
            return NonSynchronizedSources(paths: [], resolved: false)
        }
        return Self.nonSynchronizedSwiftSourcePaths(in: project)
    }

    /// The parser behind `appTargetNonSynchronizedSwiftFileReferences()`,
    /// split out so the roots pin and the sweep share one resolution.
    private static func nonSynchronizedSwiftSourcePaths(in project: String) -> NonSynchronizedSources {
        var pathsByFileID: [String: String] = [:]
        for file in pbxEntries(in: project, isa: "PBXFileReference") {
            guard let path = pbxValue(forKey: "path", in: file.body) else { continue }
            pathsByFileID[file.id] = path
        }

        for target in pbxEntries(in: project, isa: "PBXNativeTarget") {
            guard pbxValue(forKey: "name", in: target.body) == "VVTerm" else { continue }
            guard let buildPhases = pbxValue(forKey: "buildPhases", in: target.body) else {
                return NonSynchronizedSources(paths: [], resolved: false)
            }

            var sourceFileIDs: [String] = []
            var resolvedSourcePhase = false
            for phaseID in hexIdentifiers(in: buildPhases) {
                guard let phase = pbxEntries(in: project, isa: "PBXSourcesBuildPhase")
                    .first(where: { $0.id == phaseID })
                else { continue }
                resolvedSourcePhase = true
                guard let files = pbxValue(forKey: "files", in: phase.body) else { continue }
                sourceFileIDs.append(contentsOf: hexIdentifiers(in: files))
            }
            guard resolvedSourcePhase else {
                return NonSynchronizedSources(paths: [], resolved: false)
            }

            let buildFilePaths = pbxEntries(in: project, isa: "PBXBuildFile")
                .filter { sourceFileIDs.contains($0.id) }
                .compactMap { pbxValue(forKey: "fileRef", in: $0.body) }
                .compactMap { fileRefValue -> String? in
                    // The value text is `ID /* name */`; keep the leading hex ID.
                    guard let id = hexIdentifiers(in: fileRefValue).first else { return nil }
                    return pathsByFileID[id]
                }
            let fileReferencePaths = sourceFileIDs.compactMap { pathsByFileID[$0] }
            return NonSynchronizedSources(
                paths: (buildFilePaths + fileReferencePaths)
                    .filter { $0.hasSuffix(".swift") }
                    .sorted(),
                resolved: true
            )
        }
        return NonSynchronizedSources(paths: [], resolved: false)
    }

    // MARK: - Pin A allowlists

    /// The only functions allowed to build `sh -lc` / `/bin/sh -lc` commands
    /// in the three files that construct remote commands. Login semantics are
    /// intended or required at every site:
    ///
    /// - `bootstrapCommand` — the mosh child startup deliberately launches the
    ///   user's login shell (lines 110 and 112 of the two wrapper layers).
    /// - `terminationCommand` — fire-and-forget server cleanup.
    /// - `installMoshServer` — user-initiated install action; it does
    ///   marker-parse, but keeps login semantics for package-manager
    ///   discovery (the residual hook-firing risk is accepted).
    /// - `installAndAttachScript` — the PTY install script, delivered via
    ///   `sendScript`, not an exec probe.
    /// - `cleanupLegacySessions` — fire-and-forget legacy cleanup.
    /// - `killSessionCommand` — fire-and-forget session kill.
    /// - `defaultLoginShellCommand` — the interactive `exec bash -l` /
    ///   `exec zsh -l` / `exec sh -l` fallback chain.
    /// - `wrapPOSIXShellCommand` — the intentional login wrapper itself.
    /// - `unwrapPOSIXShellInvocationIfNeeded` — parses those prefixes from a
    ///   user startup command; it is not an emitter.
    private static let expectedLoginShellSites: [String: [String]] = [
        "VVTerm/Core/SSH/RemoteMoshManager.swift": [
            "bootstrapCommand",
            "installMoshServer",
            "terminationCommand"
        ],
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": [
            "cleanupLegacySessions",
            "installAndAttachScript",
            "killSessionCommand"
        ],
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": [
            "defaultLoginShellCommand",
            "unwrapPOSIXShellInvocationIfNeeded",
            "wrapPOSIXShellCommand"
        ]
    ]

    /// Occurrence counts of the login tokens at the widened family: Mosh
    /// 110/112/134/154; Tmux 381/416/1062; Bootstrap 156 (`exec "$SHELL" -l`),
    /// 157/158/159 (`exec bash|zsh|sh -l` in `defaultLoginShellCommand`), 187
    /// (`/bin/sh -lc` in `wrapPOSIXShellCommand`), 327 (the parser prefix array
    /// holds two tokens on one line).
    private static let expectedLoginShellOccurrences: [String: Int] = [
        "VVTerm/Core/SSH/RemoteMoshManager.swift": 4,
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": 3,
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 7
    ]

    /// The login-shell emitters that are not `-lc` literals but still hand a
    /// command to the account's login shell. A file outside this allowlist
    /// that references one fails pin A's recursive sweep:
    ///
    /// - `RemoteEnvironmentResolver.launchPlan` — the user's interactive
    ///   launch plan (the intentional login site at `:38`).
    /// - `RemoteTmuxManager.createSessionCommand` — the tmux window's login
    ///   shell (`:623`); `missingSessionCommand` — the fallback
    ///   `exec "${SHELL:-/bin/sh}" -l` (`:475`).
    /// - `RemoteTerminalBootstrap.moshStartupScript` — the mosh startup
    ///   fallback (`:177`); the `defaultLoginShellCommand` declaration itself
    ///   is the one allowed emitter reference outside a func body, and
    ///   `defaultLoginShellCommand`'s own `exec "$SHELL" -l` fallback keeps
    ///   its body in this allowlist (the widened emitter family counts it).
    private static let expectedLoginShellEmitterSites: [String: [String]] = [
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": ["launchPlan"],
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": [
            "createSessionCommand",
            "missingSessionCommand"
        ],
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": [
            "defaultLoginShellCommand",
            "moshStartupScript"
        ]
    ]

    /// Emitter occurrences inside function bodies (the `defaultLoginShellCommand`
    /// declaration is outside every body and counted separately below).
    /// Bootstrap has two: the `exec "$SHELL" -l` fallback inside
    /// `defaultLoginShellCommand` and the `defaultLoginShellCommand()` call
    /// inside `moshStartupScript`.
    private static let expectedLoginShellEmitterOccurrences: [String: Int] = [
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": 1,
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": 2,
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 2
    ]

    /// The number of emitter references that legitimately sit *outside* a
    /// `func` body. Only the `defaultLoginShellCommand` declaration qualifies;
    /// a file-scope binding must redden the pin.
    private static let expectedLoginShellEmitterDeclarations: [String: Int] = [
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": 0,
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": 0,
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 1
    ]

    /// The emitter patterns. The second tolerates the Swift string-literal
    /// escaping of the embedded quotes (`exec \"…\"` in the source), which a
    /// plain substring scan would miss. The third covers the `$SHELL`
    /// non-parameter-expansion fallback (`exec "$SHELL" -l`), which is a
    /// login-shell emitter but is not part of the second pattern's `${SHELL:-…}`
    /// form; its `(?!:)` keeps the parameter-expansion form out so the two
    /// patterns cannot double-count one line.
    private static let loginShellEmitterPatterns = [
        #"defaultLoginShellCommand\("#,
        #"exec [^ ]*\$\{SHELL:-/bin/sh\}[^ ]* -l"#,
        #"\bexec ?["\' ]*(?:\$SHELL|\$\{SHELL\}|SHELL)(?!:)["\']*[ \t]+-[A-Za-z]*l"#
    ]

    // MARK: - Pin B allowlists

    /// The functions allowed to call the *login* wrapper
    /// (`RemoteTerminalBootstrap.wrapPOSIXShellCommand`). A login *token*
    /// scan cannot see `wrapPOSIXShellCommand(body)`, so this is the allowlist
    /// that catches a new probe adopting the login wrapper. The scan looks for
    /// the call form `wrapPOSIXShellCommand(` (whitespace-tolerant before the
    /// paren) in a copy whose string contents are blanked out, so neither a
    /// bare-identifier literal nor a call-form literal can stand in for a
    /// call; a reference bound without a call and a call text assembled from
    /// concatenated identifier pieces remain defeats (see the header).
    ///
    /// - `RemoteTmuxManager.createSessionCommand` — builds the interactive
    ///   terminal window's login shell (the intentional login site at
    ///   `RemoteTmuxManager.swift:622`).
    /// - `RemoteEnvironmentResolver.launchPlan` — the user's interactive
    ///   launch plan (default login shell / startup command), two calls.
    /// - `RemoteTerminalBootstrap` — the declaration itself, no calls.
    private static let expectedLoginWrapperSites: [String: [String]] = [
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": ["launchPlan"],
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": [],
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": ["createSessionCommand"]
    ]

    /// Login-wrapper call occurrences inside function bodies (the declaration
    /// and doc mentions are outside every body and do not count), so a second
    /// call inside an allowlisted function still reddens the pin.
    private static let expectedLoginWrapperOccurrences: [String: Int] = [
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": 2,
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 0,
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": 1
    ]

    /// The number of `wrapPOSIXShellCommand` references that legitimately sit
    /// *outside* a `func` body. Only the declaration itself qualifies; a
    /// reference anywhere else — a computed property, a file-scope binding —
    /// must redden pin B, because the file is already in the known-wrapper set
    /// and the recursive sweep therefore lets it through.
    private static let expectedLoginWrapperDeclarations: [String: Int] = [
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": 0,
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 1,
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": 0
    ]

    /// Pin B's reference form: the call, tolerating Swift-legal whitespace
    /// before the open paren. Scanning the call form (rather than the bare
    /// identifier) stops a bare-identifier string literal from satisfying the
    /// occurrence pins, and blanking string contents first stops a
    /// call-form literal as well; a reference bound without a call and a call
    /// text assembled from concatenated identifier pieces are the remaining
    /// defeats (see the header).
    private static let loginWrapperCallPattern = #"wrapPOSIXShellCommand\s*\("#

    // MARK: - Pin C allowlists

    /// Every file converted to the non-login wrapper by #323/#324, with its
    /// exact `wrapPOSIXProbeCommand(` occurrence count. A file-level count is
    /// deliberate: it covers the five `static let` commands, multi-call
    /// functions, and a partial re-inline that a per-function check would
    /// miss.
    private static let expectedProbeWrapperOccurrences: [String: Int] = [
        "VVTerm/Core/SSH/TerminalRichPasteCoordinator.swift": 3,
        "VVTerm/Core/SSH/RemoteClipboardTransferService.swift": 3,
        "VVTerm/Features/TerminalSessions/Infrastructure/SSHETBootstrapExecutor.swift": 1,
        "VVTerm/Features/Stats/Infrastructure/StorageHealthTargetResolver.swift": 6,
        "VVTerm/Features/Stats/Infrastructure/StorageHealthProbe.swift": 3,
        "VVTerm/Features/Stats/Infrastructure/Platforms/DarwinStatsCollector.swift": 7,
        "VVTerm/Features/Stats/Infrastructure/Platforms/LinuxStatsCollector.swift": 4,
        "VVTerm/Features/Stats/Infrastructure/Platforms/UnixProcessTelemetry.swift": 2
    ]

    /// Every true `func` whose body must call `wrapPOSIXProbeCommand`, plus
    /// the file each lives in. The first five were converted by #323; the rest
    /// by #324. Property sites and body-only helpers
    /// (`cpuSnapshotCommand`/`processDetailsCommand`) are covered by the
    /// file-level counts above and are deliberately absent here.
    private static let probeBuilders: [(path: String, function: String)] = [
        ("VVTerm/Core/SSH/RemoteMoshManager.swift", "availabilityProbeCommand"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "sessionPresenceProbeCommand"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "listSessionCommands"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "currentPathCommand"),
        ("VVTerm/Core/SSH/RemoteTmuxManager.swift", "tmuxAvailabilityProbeCommand"),
        ("VVTerm/Core/SSH/TerminalRichPasteCoordinator.swift", "clipboardSeedCommand"),
        ("VVTerm/Core/SSH/TerminalRichPasteCoordinator.swift", "unixClipboardProbeCommand"),
        ("VVTerm/Core/SSH/TerminalRichPasteCoordinator.swift", "darwinClipboardProbeCommand"),
        ("VVTerm/Core/SSH/RemoteClipboardTransferService.swift", "temporaryPathCommand"),
        ("VVTerm/Core/SSH/RemoteClipboardTransferService.swift", "scheduleStaleFileSweepIfNeeded"),
        ("VVTerm/Core/SSH/RemoteClipboardTransferService.swift", "deleteRemoteFileIfNeeded"),
        ("VVTerm/Features/TerminalSessions/Infrastructure/SSHETBootstrapExecutor.swift", "remoteBootstrapCommand"),
        ("VVTerm/Features/Stats/Infrastructure/StorageHealthTargetResolver.swift", "linuxResolutionCommand"),
        ("VVTerm/Features/Stats/Infrastructure/StorageHealthTargetResolver.swift", "btrfsDiscoveryCommand"),
        ("VVTerm/Features/Stats/Infrastructure/StorageHealthTargetResolver.swift", "zfsDiscoveryCommand"),
        ("VVTerm/Features/Stats/Infrastructure/StorageHealthTargetResolver.swift", "linuxDeviceResolutionCommand"),
        ("VVTerm/Features/Stats/Infrastructure/StorageHealthTargetResolver.swift", "darwinResolutionCommand"),
        ("VVTerm/Features/Stats/Infrastructure/StorageHealthTargetResolver.swift", "bsdResolutionCommand"),
        ("VVTerm/Features/Stats/Infrastructure/StorageHealthProbe.swift", "linuxCommand"),
        ("VVTerm/Features/Stats/Infrastructure/StorageHealthProbe.swift", "darwinCommand"),
        ("VVTerm/Features/Stats/Infrastructure/StorageHealthProbe.swift", "bsdCommand"),
        ("VVTerm/Features/Stats/Infrastructure/Platforms/DarwinStatsCollector.swift", "collectProfile"),
        ("VVTerm/Features/Stats/Infrastructure/Platforms/DarwinStatsCollector.swift", "volumeMetadata"),
        ("VVTerm/Features/Stats/Infrastructure/Platforms/LinuxStatsCollector.swift", "collectProfile"),
        ("VVTerm/Features/Stats/Infrastructure/Platforms/LinuxStatsCollector.swift", "collectStats"),
        ("VVTerm/Features/Stats/Infrastructure/Platforms/LinuxStatsCollector.swift", "volumeMetadata"),
        ("VVTerm/Features/Stats/Infrastructure/Platforms/UnixProcessTelemetry.swift", "collect")
    ]

    // MARK: - Pin E allowlists

    /// The only functions allowed to call the *full* `shellPathExport()` — the
    /// PATH that puts `$HOME/.local/bin` first. Since #324 the wrapper injects
    /// only the curated *system* PATH, so a parsed-probe body that needs a
    /// user-local binary must self-export deliberately. The policy (plan
    /// §3.1) is that only bodies which predate the wrapper's PATH injection
    /// may do so:
    ///
    /// - the #323-converted tmux/mosh probe builders that resolve
    ///   `mosh-server`/`tmux` candidates
    ///   (`RemoteMoshManager.availabilityProbeCommand`;
    ///   `RemoteTmuxManager.sessionPresenceProbeCommand`,
    ///   `tmuxAvailabilityProbeCommand`, `listSessionCommands`,
    ///   `currentPathCommand`) plus
    ///   `RemoteEnvironmentResolver.posixEnvironmentProbeCommand`;
    /// - `SSHETBootstrapExecutor.remoteBootstrapCommand` (`etterminal` lives
    ///   in `$HOME/.local/bin`);
    /// - the interactive / install / bootstrap scripts that are not
    ///   wrapper-built parsed probes (`RemoteMoshManager.bootstrapCommand`,
    ///   `installScript`; `RemoteTmuxManager.installAndAttachScript`,
    ///   `cleanupLegacySessions`, `attachExistingBody`, `killSessionCommand`;
    ///   `RemoteTerminalTypeResolver.probeCommand`, `installCommand`).
    ///
    /// A body converted by #324 must not be added: re-adding the export would
    /// re-promote `$HOME/.local/bin` ahead of the system dirs for a probe that
    /// does not need it — the exact defect the wrapper's system-only PATH
    /// closes.
    private static let expectedShellPathExportSites: [String: [String]] = [
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": ["posixEnvironmentProbeCommand"],
        "VVTerm/Core/SSH/RemoteMoshManager.swift": [
            "availabilityProbeCommand",
            "bootstrapCommand",
            "installScript"
        ],
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": [],
        "VVTerm/Core/SSH/RemoteTerminalTypeResolver.swift": [
            "installCommand",
            "probeCommand"
        ],
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": [
            "attachExistingBody",
            "cleanupLegacySessions",
            "currentPathCommand",
            "installAndAttachScript",
            "killSessionCommand",
            "listSessionCommands",
            "sessionPresenceProbeCommand",
            "tmuxAvailabilityProbeCommand"
        ],
        "VVTerm/Features/TerminalSessions/Infrastructure/SSHETBootstrapExecutor.swift": [
            "remoteBootstrapCommand"
        ]
    ]

    /// `shellPathExport(` occurrences inside the enumerated function bodies —
    /// `listSessionCommands` builds three candidate commands, everything else
    /// one.
    private static let expectedShellPathExportOccurrences: [String: Int] = [
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": 1,
        "VVTerm/Core/SSH/RemoteMoshManager.swift": 3,
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 0,
        "VVTerm/Core/SSH/RemoteTerminalTypeResolver.swift": 2,
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": 10,
        "VVTerm/Features/TerminalSessions/Infrastructure/SSHETBootstrapExecutor.swift": 1
    ]

    /// `shellPathExport(` references that legitimately sit *outside* a `func`
    /// body: only the declaration itself. A computed property or file-scope
    /// binding must redden the pin.
    private static let expectedShellPathExportDeclarations: [String: Int] = [
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 1
    ]

    // MARK: - Pins

    /// The roots pin (fail-closed scan scope): the sweep must cover every
    /// Swift root that compiles into the `VVTerm` app target. If the Xcode
    /// project grows a synchronized root, this reddens and `allSwiftFiles()`
    /// already sweeps it — the new root is scanned before it is trusted. A
    /// classic `PBXGroup` + `Sources`-phase file is not under any root, so it
    /// must fail this pin instead: the target must contribute zero
    /// non-synchronized Swift sources (the header states this choice), and the
    /// assertion fails closed if the target's `buildPhases` or its
    /// `PBXSourcesBuildPhase` cannot be resolved at all.
    @Test
    func testAppTargetSweepRootsArePinned() {
        let roots = appTargetSourceRoots()
        #expect(
            roots == Self.expectedAppTargetSourceRoots,
            "the VVTerm app target's synchronized Swift roots are \(roots); a new root must be consciously added to expectedAppTargetSourceRoots (it is already swept, this is the tripwire)"
        )

        let nonSynchronized = appTargetNonSynchronizedSwiftFileReferences()
        #expect(
            nonSynchronized.resolved,
            "the VVTerm app target's `buildPhases`/`PBXSourcesBuildPhase` could not be resolved from VVTerm.xcodeproj, so the non-synchronized-sources assertion cannot run; failing closed because the Sources phase is the scan-scope tripwire"
        )
        #expect(
            nonSynchronized.paths.isEmpty,
            "the VVTerm app target compiles non-synchronized Swift source(s) \(nonSynchronized.paths); a plain PBXGroup reference is outside every synchronized scan root, so it must either move under a synchronized root or the roots/sweep design must be widened deliberately"
        )
    }

    /// Pin A (#323/#324): login-shell tokens and emitters live only in the
    /// intentional-login allowlists, recursively across every app-target root.
    @Test
    func testOnlyAllowlistedSitesEmitLoginShellTokensOrEmitters() throws {
        let files = allSwiftFiles()

        // The recursive, fail-closed sweep: a new file (or a new literal in an
        // existing file) cannot adopt login semantics silently.
        for file in files {
            let text = Self.strippingComments(try source(file.path))
            let tokenCount = Self.shFamilyLoginTokenCount(in: text)
            if tokenCount > 0 {
                #expect(
                    Self.expectedLoginShellOccurrences[file.path] == tokenCount,
                    "\(file.path): \(tokenCount) sh-family login token(s); expected \(Self.expectedLoginShellOccurrences[file.path].map { String($0) } ?? "none") — a new login-shell literal must be consciously allowlisted"
                )
            }
            let emitterCount = Self.loginShellEmitterCount(in: text)
            if emitterCount > 0 {
                #expect(
                    Self.expectedLoginShellEmitterSites[file.path] != nil,
                    "\(file.path): \(emitterCount) login-shell emitter reference(s); the file is not in the emitter allowlist"
                )
            }
        }

        // The sh-family file allowlist is exact: the enumerated functions, the
        // in-body occurrence count, and the whole-file count must all hold.
        for (path, allowed) in Self.expectedLoginShellSites {
            let text = Self.strippingComments(try source(path))
            let bodies = try Self.functionBodies(in: text)

            for name in allowed {
                #expect(
                    bodies.filter { $0.name == name }.count == 1,
                    "\(path): the allowlisted `\(name)` must resolve to exactly one function body"
                )
            }

            var tokenBodies: [FunctionBody] = []
            for body in bodies where Self.shFamilyLoginTokenCount(in: text, range: body.body) > 0 {
                tokenBodies.append(body)
            }
            let tokenNames = tokenBodies.map(\.name).sorted()
            #expect(
                tokenNames == allowed.sorted(),
                "\(path): login-shell emitters must be exactly \(allowed.sorted()), got \(tokenNames)"
            )

            var insideBodyOccurrences = 0
            for body in tokenBodies {
                insideBodyOccurrences += Self.shFamilyLoginTokenCount(in: text, range: body.body)
            }
            let totalOccurrences = Self.shFamilyLoginTokenCount(in: text)
            #expect(
                totalOccurrences == insideBodyOccurrences,
                "\(path): every sh-family login token must sit inside an enumerated function body"
            )
            #expect(
                totalOccurrences == Self.expectedLoginShellOccurrences[path],
                "\(path): the sh-family login-token count must stay \(Self.expectedLoginShellOccurrences[path] ?? -1)"
            )
        }

        // The emitter allowlist: per-function set + in-body count + the
        // declaration-only allowance (the `defaultLoginShellCommand`
        // declaration is the one emitter reference outside a func body).
        for (path, allowed) in Self.expectedLoginShellEmitterSites {
            let text = Self.strippingComments(try source(path))
            let bodies = try Self.functionBodies(in: text)

            for name in allowed {
                #expect(
                    bodies.filter { $0.name == name }.count == 1,
                    "\(path): the allowlisted `\(name)` must resolve to exactly one function body"
                )
            }

            let emitterCallers = bodies
                .filter { Self.loginShellEmitterCount(in: text, range: $0.body) > 0 }
                .map(\.name)
                .sorted()
            #expect(
                emitterCallers == allowed.sorted(),
                "\(path): login-shell emitter functions must be exactly \(allowed.sorted()), got \(emitterCallers)"
            )

            var insideBodyOccurrences = 0
            for body in bodies {
                insideBodyOccurrences += Self.loginShellEmitterCount(in: text, range: body.body)
            }
            #expect(
                insideBodyOccurrences == Self.expectedLoginShellEmitterOccurrences[path],
                "\(path): the in-body emitter count must stay \(Self.expectedLoginShellEmitterOccurrences[path] ?? -1)"
            )

            let wholeFileOccurrences = Self.loginShellEmitterCount(in: text)
            #expect(
                wholeFileOccurrences - insideBodyOccurrences
                    == Self.expectedLoginShellEmitterDeclarations[path],
                "\(path): \(wholeFileOccurrences - insideBodyOccurrences) emitter reference(s) outside a func body; only the defaultLoginShellCommand declaration is allowed"
            )
        }

        let knownFiles = Set(Self.expectedLoginShellSites.keys)
            .union(Self.expectedLoginShellEmitterSites.keys)
        let sweptPaths = Set(files.map(\.path))
        let missing = knownFiles.subtracting(sweptPaths)
        #expect(
            missing.isEmpty,
            "the recursive sweep missed known login-shell files \(missing.sorted()) — the sweep root is wrong, or a pinned file was moved"
        )
    }

    /// Pin B (#324): the only files that may call the *login* wrapper are the
    /// three intentional-login files, and inside them only the enumerated
    /// functions may call it. This is the pin the literal-token scan cannot
    /// be: a new probe written as `wrapPOSIXShellCommand(body)` carries no
    /// literal `sh -lc`. The scan uses the call form
    /// `wrapPOSIXShellCommand(` (whitespace-tolerant before the paren) in a
    /// copy whose string contents are blanked, so neither a bare-identifier
    /// nor a call-form string literal can stand in for a call (see the header
    /// for the defeats that remain).
    @Test
    func testOnlyAllowlistedFilesAndFunctionsReferenceTheLoginWrapper() throws {
        let files = allSwiftFiles()
        let knownFiles = Set(Self.expectedLoginWrapperSites.keys)
        let sweptPaths = Set(files.map(\.path))
        let missing = knownFiles.subtracting(sweptPaths)
        #expect(
            missing.isEmpty,
            "the recursive sweep missed known login-wrapper files \(missing.sorted()) — the sweep root is wrong, or a pinned file was moved"
        )

        for file in files {
            let text = Self.strippingCommentsAndStrings(try source(file.path))
            if Self.loginWrapperCallCount(in: text) > 0 {
                #expect(
                    Self.expectedLoginWrapperSites[file.path] != nil,
                    "\(file.path): a login-wrapper call must be consciously allowlisted"
                )
            }
        }

        for (path, allowed) in Self.expectedLoginWrapperSites {
            let text = Self.strippingCommentsAndStrings(try source(path))
            let bodies = try Self.functionBodies(in: text)

            for name in allowed {
                #expect(
                    bodies.filter { $0.name == name }.count == 1,
                    "\(path): the allowlisted `\(name)` must resolve to exactly one function body"
                )
            }

            let callers = bodies
                .filter { Self.loginWrapperCallCount(in: text, range: $0.body) > 0 }
                .map(\.name)
                .sorted()
            #expect(
                callers == allowed.sorted(),
                "\(path): login-wrapper callers must be exactly \(allowed.sorted()), got \(callers)"
            )

            let insideBodyOccurrences = bodies.reduce(0) { count, body in
                count + Self.loginWrapperCallCount(in: text, range: body.body)
            }
            #expect(
                insideBodyOccurrences == Self.expectedLoginWrapperOccurrences[path],
                "\(path): the login-wrapper call count must stay \(Self.expectedLoginWrapperOccurrences[path] ?? -1)"
            )

            // The whole-file-vs-body mirror: a wrapper call *outside* a
            // `func` body (a computed property, a file-scope binding) would
            // otherwise pass this pin and the recursive sweep, because the
            // file is already in the known-wrapper set. The only reference
            // legitimately outside a body is the declaration itself.
            let wholeFileOccurrences = Self.loginWrapperCallCount(in: text)
            #expect(
                wholeFileOccurrences - insideBodyOccurrences
                    == Self.expectedLoginWrapperDeclarations[path],
                "\(path): \(wholeFileOccurrences - insideBodyOccurrences) login-wrapper reference(s) outside a func body; only the declaration in RemoteTerminalBootstrap.swift is allowed (a computed property or file-scope binding must be pinned explicitly)"
            )
        }
    }

    /// Pin C (#324): the converted files must use the non-login wrapper at
    /// exactly the expected number of sites and must not call the login
    /// wrapper, and every named builder must keep calling it. File-level
    /// counts cover the property sites and multi-call functions; the builder
    /// loop names the functions so a regression has a readable failure.
    @Test
    func testConvertedProbeFilesUseTheNonLoginWrapperAtEverySite() throws {
        for (path, expected) in Self.expectedProbeWrapperOccurrences {
            let text = Self.strippingCommentsAndStrings(try source(path))
            let probeCount = Self.occurrences(of: "wrapPOSIXProbeCommand(", in: text).count
            #expect(
                probeCount == expected,
                "\(path): expected \(expected) `wrapPOSIXProbeCommand(` site(s), got \(probeCount) — a re-inlined login wrapper or a dropped conversion"
            )
            #expect(
                text.range(of: "wrapPOSIXShellCommand") == nil,
                "\(path): a converted probe file must not reference the login wrapper"
            )
        }

        for builder in Self.probeBuilders {
            let text = Self.strippingCommentsAndStrings(try source(builder.path))
            let bodies = try Self.functionBodies(in: text)
            let matches = bodies.filter { $0.name == builder.function }
            #expect(
                matches.count == 1,
                "\(builder.path) must keep exactly one `\(builder.function)`"
            )
            let body = try #require(matches.first)
            #expect(
                text.range(of: "wrapPOSIXProbeCommand(", range: body.body) != nil,
                "\(builder.path): \(builder.function) must build its command with wrapPOSIXProbeCommand"
            )
        }
    }

    /// Pin D (#324): the non-login wrapper is the single construction point
    /// for every parsed probe, so the curated *system* PATH export
    /// (`shellSystemPathExport()`) is injected there rather than by each body.
    /// The wrapper's output must carry the export and keep the `sh -c '`
    /// prefix, and its source body must reference `shellSystemPathExport()` —
    /// a body-level `shellPathValue()` prepend cannot satisfy this pin.
    @Test
    func testProbeWrapperInjectsTheCuratedSystemPathExport() throws {
        let path = "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift"
        let command = RemoteTerminalBootstrap.wrapPOSIXProbeCommand("printf 'marker'")

        #expect(command.hasPrefix("sh -c '"))
        #expect(command.contains(RemoteTerminalBootstrap.shellSystemPathExport()))
        #expect(!command.contains("$HOME/.local/bin"))

        let text = Self.strippingComments(try source(path))
        let bodies = try Self.functionBodies(in: text)
        let matches = bodies.filter { $0.name == "wrapPOSIXProbeCommand" }
        #expect(
            matches.count == 1,
            "\(path) must keep exactly one `wrapPOSIXProbeCommand`"
        )
        let body = try #require(matches.first)
        #expect(
            text.range(of: "shellSystemPathExport()", range: body.body) != nil,
            "\(path): wrapPOSIXProbeCommand must inject shellSystemPathExport() itself"
        )
    }

    /// Pin E (#324): the full user PATH export (`shellPathExport()`, which
    /// puts `$HOME/.local/bin` first) is allowed only in the enumerated
    /// pre-#324 bodies. The wrapper injects the curated system PATH; a body
    /// converted by #324 that re-adds `shellPathExport()` would re-promote
    /// `$HOME/.local/bin` ahead of the system dirs, which is the defect this
    /// pin keeps closed. The file-level sweep fires on both spellings: the
    /// `shellPathExport(` call text is counted in the string-blanked copy,
    /// and a hand-rolled `$HOME/.local/bin` literal — which can only live
    /// inside a string literal — is counted in the comment-stripped,
    /// string-verbatim copy, so the same defect cannot be reintroduced by
    /// either form. Documented defeats: a reference bound without a call
    /// (`let e = RemoteTerminalBootstrap.shellPathExport; e()`) and a PATH
    /// string that reaches `$HOME/.local/bin` without spelling the literal (a
    /// variable or an interpolation) remain invisible to this scan.
    @Test
    func testOnlyAllowlistedBodiesSelfExportTheUserLocalPath() throws {
        let files = allSwiftFiles()
        let knownFiles = Set(Self.expectedShellPathExportSites.keys)
        let sweptPaths = Set(files.map(\.path))
        let missing = knownFiles.subtracting(sweptPaths)
        #expect(
            missing.isEmpty,
            "the recursive sweep missed known self-exporting files \(missing.sorted()) — the sweep root is wrong, or a pinned file was moved"
        )

        for file in files {
            let fileText = try source(file.path)
            // The call form is invisible inside a blanked string literal, so
            // the reference count reads the string-blanked copy; the
            // `$HOME/.local/bin` literal can only live inside a string, so its
            // sweep reads the comment-stripped, string-verbatim copy.
            let text = Self.strippingCommentsAndStrings(fileText)
            let references = Self.occurrences(of: "shellPathExport(", in: text).count
            let handRolled = Self.occurrences(
                of: "$HOME/.local/bin",
                in: Self.strippingComments(fileText)
            ).count
            if references > 0 || handRolled > 0 {
                #expect(
                    Self.expectedShellPathExportSites[file.path] != nil,
                    "\(file.path): \(references) shellPathExport() reference(s) and \(handRolled) hand-rolled $HOME/.local/bin literal(s); only an allowlisted pre-#324 body may self-export the user-local PATH — it re-promotes $HOME/.local/bin ahead of the system dirs"
                )
            }
        }

        for (path, allowed) in Self.expectedShellPathExportSites {
            let text = Self.strippingCommentsAndStrings(try source(path))
            let bodies = try Self.functionBodies(in: text)

            for name in allowed {
                #expect(
                    bodies.filter { $0.name == name }.count == 1,
                    "\(path): the allowlisted `\(name)` must resolve to exactly one function body"
                )
            }

            let callers = bodies
                .filter { Self.occurrences(of: "shellPathExport(", in: text, range: $0.body).isEmpty == false }
                .map(\.name)
                .sorted()
            #expect(
                callers == allowed.sorted(),
                "\(path): shellPathExport() callers must be exactly \(allowed.sorted()), got \(callers)"
            )

            let insideBodyOccurrences = bodies.reduce(0) { count, body in
                count + Self.occurrences(of: "shellPathExport(", in: text, range: body.body).count
            }
            #expect(
                insideBodyOccurrences == Self.expectedShellPathExportOccurrences[path],
                "\(path): the in-body shellPathExport() call count must stay \(Self.expectedShellPathExportOccurrences[path] ?? -1)"
            )

            let wholeFileOccurrences = Self.occurrences(of: "shellPathExport(", in: text).count
            #expect(
                wholeFileOccurrences - insideBodyOccurrences
                    == (Self.expectedShellPathExportDeclarations[path] ?? 0),
                "\(path): \(wholeFileOccurrences - insideBodyOccurrences) shellPathExport() reference(s) outside a func body; only the declaration in RemoteTerminalBootstrap.swift is allowed"
            )
        }
    }

    // MARK: - Source helpers

    /// A comment-stripped copy of `source` for the token scans: characters
    /// inside `//` line comments and nested `/* … */` block comments become
    /// spaces; newlines are preserved, so slice anchors still resolve. String
    /// contents are copied verbatim (so a `//` inside a literal is not read as
    /// a comment); the scanner covers `"…"` (with `\` escapes), `"""…"""`,
    /// raw strings (`#"…"#`, any hash count) and interpolation brackets. A
    /// comment that sits inside an interpolation is preserved along with the
    /// rest of the interpolation; the call-form scan
    /// (`strippingCommentsAndStrings`) is the one that strips it.
    private static func strippingComments(_ source: String) -> String {
        scanning(source, blankingStringContents: false)
    }

    /// The single scanner behind the two views of a source file:
    /// `strippingComments` (strings verbatim, for the login-token scan) and
    /// `strippingCommentsAndStrings` (string contents blanked, for the
    /// call-form scans). Comments become spaces in both; newlines are
    /// preserved, so slice anchors and range arithmetic still resolve.
    ///
    /// When blanking string contents, an interpolation (`\( … )`) is kept as
    /// code — its body is scanned recursively, because a real call inside an
    /// interpolation (the production pattern: `"\(RemoteTerminalBootstrap
    /// .shellPathExport()); …"`) is not a string decoy. When copying strings
    /// verbatim the whole literal, interpolation included, is kept as text, so
    /// the login-token scan keeps seeing tokens inside interpolated literals.
    private static func scanning(
        _ source: String,
        blankingStringContents: Bool
    ) -> String {
        let characters = Array(source)
        var result: [Character] = []
        result.reserveCapacity(characters.count)
        result.append(contentsOf: scan(
            characters,
            from: 0,
            to: characters.count,
            blankingStringContents: blankingStringContents
        ))
        return String(result)
    }

    /// The recursive worker behind `scanning(_:blankingStringContents:)`.
    private static func scan(
        _ characters: [Character],
        from start: Int,
        to end: Int,
        blankingStringContents: Bool
    ) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(end - start)
        var index = start
        var blockCommentDepth = 0
        var inLineComment = false
        while index < end {
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
                if character == "/", index + 1 < end, characters[index + 1] == "*" {
                    blockCommentDepth += 1
                    result.append(contentsOf: "  ")
                    index += 2
                } else if character == "*", index + 1 < end, characters[index + 1] == "/" {
                    blockCommentDepth -= 1
                    result.append(contentsOf: "  ")
                    index += 2
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index += 1
                }
                continue
            }
            if character == "/", index + 1 < end, characters[index + 1] == "/" {
                inLineComment = true
                result.append(contentsOf: "  ")
                index += 2
                continue
            }
            if character == "/", index + 1 < end, characters[index + 1] == "*" {
                blockCommentDepth = 1
                result.append(contentsOf: "  ")
                index += 2
                continue
            }
            if let delimiter = Self.stringDelimiter(at: index, in: characters, to: end) {
                if blankingStringContents {
                    let scanned = Self.scannedString(
                        characters,
                        openingAt: index,
                        delimiter: delimiter
                    )
                    result.append(contentsOf: scanned.characters)
                    index = scanned.afterDelimiter
                } else {
                    let close = Self.stringEnd(from: index, delimiter: delimiter, in: characters)
                    result.append(contentsOf: characters[index..<close.index])
                    index = close.index
                }
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// The string-delimiter sequence beginning at `start` (`"`, `"""`, `#"`,
    /// `##"`, …), or nil when the characters there do not open a string.
    private static func stringDelimiter(
        at start: Int,
        in characters: [Character],
        to end: Int
    ) -> String? {
        var cursor = start
        while cursor < end, characters[cursor] == "#" {
            cursor += 1
        }
        guard cursor < end, characters[cursor] == "\"" else { return nil }
        let hashes = String(repeating: "#", count: cursor - start)
        if cursor + 2 < end, characters[cursor + 1] == "\"", characters[cursor + 2] == "\"" {
            return hashes + "\"\"\""
        }
        return hashes + "\""
    }

    /// A copy of the string literal that opens at `start`: the content is
    /// blanked while interpolation bodies are scanned recursively so their
    /// calls stay visible — `\( … )` for the quoted strings and `\#( … )`
    /// (the delimiter's hash count) for raw strings — and the closing
    /// delimiter is preserved. Returns the copy and the index just past the
    /// literal.
    private static func scannedString(
        _ characters: [Character],
        openingAt start: Int,
        delimiter: String
    ) -> (characters: [Character], afterDelimiter: Int) {
        var result: [Character] = []
        result.append(contentsOf: characters[start..<(start + delimiter.count)])
        let contentStart = start + delimiter.count
        let close = Self.stringEnd(from: start, delimiter: delimiter, in: characters)
        var cursor = contentStart
        // Raw-string delimiters are hash-*prefixed* (`#"`, `##"`, `#"""`),
        // so raw-ness is `hasPrefix`, not `hasSuffix`.
        let isRaw = delimiter.hasPrefix("#")
        let hashCount = delimiter.filter { $0 == "#" }.count
        while cursor < close.contentEnd {
            let character = characters[cursor]
            if character == "\\" {
                var escapeIndex = cursor + 1
                if isRaw {
                    var hashes = 0
                    while escapeIndex < close.contentEnd, characters[escapeIndex] == "#" {
                        hashes += 1
                        escapeIndex += 1
                    }
                    guard hashes == hashCount else {
                        // Fewer/more hashes than the delimiter: literal text,
                        // blanked with the rest of the content.
                        result.append(" ")
                        cursor += 1
                        continue
                    }
                }
                if escapeIndex < close.contentEnd, characters[escapeIndex] == "(" {
                    let interpolation = Self.interpolationEnd(
                        in: characters,
                        from: escapeIndex + 1,
                        to: close.contentEnd
                    )
                    result.append(contentsOf: characters[cursor...escapeIndex])
                    result.append(contentsOf: scan(
                        characters,
                        from: interpolation.openDepth,
                        to: interpolation.closeDepth,
                        blankingStringContents: true
                    ))
                    result.append(")")
                    cursor = interpolation.closeDepth + 1
                    continue
                }
                if !isRaw, cursor + 1 < close.contentEnd {
                    result.append(character)
                    result.append(contentsOf: Self.blanked(characters, from: cursor + 1, to: min(cursor + 2, close.contentEnd)))
                    cursor += 2
                    continue
                }
            }
            result.append(character == "\n" ? "\n" : " ")
            cursor += 1
        }
        result.append(contentsOf: characters[close.contentEnd..<close.index])
        return (result, close.index)
    }

    /// The end of an interpolation whose body starts at `start`: the body
    /// (returned as `openDepth..<closeDepth`) ends at the matching `)` at
    /// bracket depth zero; a `)` inside a string literal inside the body does
    /// not close it, and a nested interpolation is skipped along with its own
    /// string. A body that never closes runs to `end` and returns an empty
    /// span (fail-closed: nothing is executed, the text stays blanked).
    private static func interpolationEnd(
        in characters: [Character],
        from start: Int,
        to end: Int
    ) -> (openDepth: Int, closeDepth: Int) {
        var cursor = start
        var depth = 0
        while cursor < end {
            let character = characters[cursor]
            if character == "(" || character == "[" || character == "{" {
                depth += 1
                cursor += 1
            } else if character == ")" {
                if depth == 0 {
                    return (start, cursor)
                }
                depth -= 1
                cursor += 1
            } else if character == "]" || character == "}" {
                if depth > 0 { depth -= 1 }
                cursor += 1
            } else if let delimiter = Self.stringDelimiter(at: cursor, in: characters, to: end) {
                cursor = Self.stringEnd(from: cursor, delimiter: delimiter, in: characters).index
            } else {
                cursor += 1
            }
        }
        return (end, end)
    }

    /// The end of the string literal that opens at `start`, where the opening
    /// delimiter is `delimiter` (one quote plus its hash prefix, three quotes,
    /// or one quote). `contentEnd` is the index just past the content (where
    /// the closing sequence begins); `closing` is that sequence (the quote or
    /// `"""` suffix); `index` is the first character after it. A raw string
    /// has no escapes; a non-raw one treats a backslash as escaping the next
    /// character — including `\(`, whose interpolation contents are scanned
    /// with a bracket stack (and any string inside them skipped) so a `"` or
    /// `)` inside an interpolation cannot terminate the outer literal.
    private static func stringEnd(
        from start: Int,
        delimiter: String,
        in characters: [Character]
    ) -> (contentEnd: Int, closing: [Character], index: Int) {
        let isRaw = delimiter.hasPrefix("#")
        let quoteCount = delimiter.filter { $0 == "\"" }.count
        let hashes = delimiter.filter { $0 == "#" }.count
        var cursor = start + delimiter.count
        var bracketStack: [Character] = []
        while cursor < characters.count {
            if isRaw {
                let closingLength = quoteCount + hashes
                if cursor + closingLength <= characters.count,
                   Array(characters[cursor..<(cursor + closingLength)])
                    == Array(repeating: "\"", count: quoteCount)
                        + Array(repeating: "#", count: hashes) {
                    return (cursor, Array(characters[cursor..<(cursor + closingLength)]), cursor + closingLength)
                }
                cursor += 1
            } else if quoteCount == 3 {
                if cursor + 3 <= characters.count,
                   characters[cursor] == "\"",
                   characters[cursor + 1] == "\"",
                   characters[cursor + 2] == "\"" {
                    return (cursor, Array("\"\"\""), cursor + 3)
                }
                cursor += 1
            } else if characters[cursor] == "\\" {
                if cursor + 1 < characters.count, characters[cursor + 1] == "(" {
                    cursor = Self.interpolationEnd(in: characters, from: cursor + 2, to: characters.count).closeDepth + 1
                } else {
                    cursor += 2
                }
            } else if characters[cursor] == "\"" {
                return (cursor, Array("\""), cursor + 1)
            } else if bracketStack.isEmpty {
                cursor += 1
            } else {
                let character = characters[cursor]
                if character == "(" || character == "[" || character == "{" {
                    bracketStack.append(character)
                } else if character == ")" || character == "]" || character == "}" {
                    if Self.matches(closing: character, opening: bracketStack.last) {
                        bracketStack.removeLast()
                    }
                }
                cursor += 1
            }
        }
        return (characters.count, [], characters.count)
    }

    /// Whether a closing bracket matches the current top of the interpolation
    /// bracket stack.
    private static func matches(closing: Character, opening: Character?) -> Bool {
        switch closing {
        case ")": return opening == "("
        case "]": return opening == "["
        case "}": return opening == "{"
        default: return false
        }
    }

    /// `characters[from..<to]` with every non-newline character replaced by a
    /// space (newlines are preserved so the scan keeps line structure).
    private static func blanked(
        _ characters: [Character],
        from: Int,
        to: Int
    ) -> [Character] {
        guard from < to else { return [] }
        return characters[from..<to].map { $0 == "\n" ? "\n" : " " }
    }

    /// The login-token pattern: a shell name — or a `$SHELL` / `${SHELL}`
    /// parameter expansion — followed by a login flag, either a short-flag
    /// cluster containing `l` (`-lc`, `-l`, `-il`, …) or `--login`. The gap
    /// tolerates the Swift string-literal escaping of whitespace (`sh\t-lc`,
    /// `sh\n-lc`) and of a surrounding quote (`exec \"$SHELL\" -l`), plus an
    /// optional closing quote/bracket between the token and the flag, so an
    /// emulated shell line is caught in both the raw and the escaped spelling.
    /// The identifier branch keeps its `\b` word-boundary semantics (`sh`, not
    /// `flush`), while the `$SHELL` branch uses a negative lookbehind so
    /// `MY_SHELL`/`$SHELLX` cannot match; controls `ls -l`, `grep -l`,
    /// `tail -l`, `flush -l` stay unmatched (their `sh` prefix is not a word,
    /// and a quote/backslash gap requires a real token before the flag). A
    /// token opening a string literal (`"sh -lc `) is caught, as is one after
    /// a path slash (`/bin/sh -lc`). The `$SHELL`/`SHELL` branch additionally
    /// requires a command-position boundary — string start, after `;`/newline/
    /// `|`/`&`/`(` (with optional spaces/tabs), after `exec`, or after a quote
    /// or backslash — so `echo $SHELL -l` no longer matches; the shell-name
    /// branch keeps word-boundary semantics, so `echo sh -lc` remains an
    /// accepted fail-closed over-match.
    private static let loginShellTokenPattern =
        #"(?:(?<![A-Za-z0-9_])(?:sh|bash|zsh|dash|ksh|fish|csh|tcsh)|(?<![A-Za-z0-9_$])(?<=(?:^|[;\n|&()])[ \t]{0,8}|exec[ \t]{0,8}|["'\\])(?:\$\{SHELL\}|\$SHELL|SHELL))(?:["\'\]][ \t]|[ \t]|\\[tnr]|\\["\'])+[\"\'\]]?(?:-[A-Za-z]*l[A-Za-z]*\b|--login\b)"#

    /// The number of regex matches for `pattern` in `text` (optionally inside
    /// `range`), in source order.
    private static func patternCount(
        _ pattern: String,
        in text: String,
        range: Range<String.Index>? = nil
    ) -> Int {
        let searchRange = range ?? text.startIndex..<text.endIndex
        var count = 0
        var searchStart = searchRange.lowerBound
        while let found = text.range(
            of: pattern,
            options: .regularExpression,
            range: searchStart..<searchRange.upperBound
        ) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    /// The number of sh-family login tokens in `text` (optionally inside
    /// `range`).
    private static func shFamilyLoginTokenCount(
        in text: String,
        range: Range<String.Index>? = nil
    ) -> Int {
        Self.patternCount(Self.loginShellTokenPattern, in: text, range: range)
    }

    /// The number of login-shell emitter references in `text` (optionally
    /// inside `range`).
    private static func loginShellEmitterCount(
        in text: String,
        range: Range<String.Index>? = nil
    ) -> Int {
        Self.loginShellEmitterPatterns.reduce(0) { count, pattern in
            count + Self.patternCount(pattern, in: text, range: range)
        }
    }

    /// The number of login-wrapper calls in `text` (optionally inside
    /// `range`): the call form, whitespace-tolerant before the open paren.
    private static func loginWrapperCallCount(
        in text: String,
        range: Range<String.Index>? = nil
    ) -> Int {
        Self.patternCount(Self.loginWrapperCallPattern, in: text, range: range)
    }

    /// A `func` declaration's body span and its name.
    private struct FunctionBody {
        let name: String
        let body: Range<String.Index>
    }

    /// Every `func` declaration's body in `text`, in source order. The scan
    /// keys off the literal `func ` keyword (shell function definitions inside
    /// string literals do not carry it) and binds the first brace block after
    /// the declaration name. `nonisolated static func`, `private func`, and
    /// `@Test`-less declarations all match; a default-argument closure would
    /// bind the wrong block (documented defeat list).
    private static func functionBodies(in text: String) throws -> [FunctionBody] {
        var result: [FunctionBody] = []
        for declaration in occurrences(of: "func ", in: text) {
            var cursor = declaration.upperBound
            let nameStart = cursor
            while cursor < text.endIndex,
                  text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "_" {
                cursor = text.index(after: cursor)
            }
            guard cursor > nameStart else { continue }
            let name = String(text[nameStart..<cursor])
            let body = try bracedBlock(after: nameStart..<cursor, in: text)
            result.append(FunctionBody(name: name, body: body))
        }
        return result
    }

    /// The body span `{ … }` of the brace-delimited block that opens at
    /// `open`, found by a character-level depth walk.
    private static func bracedBlock(
        openingAt open: String.Index,
        in text: String
    ) throws -> Range<String.Index> {
        try #require(text[open] == "{", "the pin block open must be a `{`")
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

    /// Every occurrence of `needle` in `text` (optionally within `range`),
    /// in source order.
    private static func occurrences(
        of needle: String,
        in text: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        let searchRange = range ?? text.startIndex..<text.endIndex
        var result: [Range<String.Index>] = []
        var searchStart = searchRange.lowerBound
        while let found = text.range(of: needle, range: searchStart..<searchRange.upperBound) {
            result.append(found)
            searchStart = found.upperBound
        }
        return result
    }
}
