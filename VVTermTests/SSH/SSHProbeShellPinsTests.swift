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
//  the whole `VVTerm/` tree (the behavioural route cannot run on iOS).
//
//  WHAT THESE PINS ASSERT (and what they do not see). Four pins, all
//  comment-stripping the source first:
//    A. a recursive `.swift` scan of `VVTerm/`: the sh-family login tokens
//       (`sh|bash|zsh|dash|ksh -lc`, whitespace-tolerant) may appear only in
//       the Mosh 4 / Tmux 3 / Bootstrap 3 file allowlist, and the login-shell
//       emitters (`defaultLoginShellCommand(`, `exec "${SHELL:-/bin/sh}" -l`)
//       only in the emitter allowlist; inside the three sh-family files the
//       token may appear only inside the enumerated function bodies, and the
//       emitter files have a per-function/occurrence/declaration allowlist of
//       their own.
//    B. a recursive `.swift` scan of `VVTerm/` for the bare identifier
//       `wrapPOSIXShellCommand`: the only files that may reference it are
//       `RemoteEnvironmentResolver` (2 calls in `launchPlan`),
//       `RemoteTmuxManager` (1 call in `createSessionCommand`) and
//       `RemoteTerminalBootstrap` (the declaration); a new function or a
//       file-scope binding inside an allowlisted file reddens, and the two
//       clipboard files that #324 converted must stay at zero.
//    C. the converted files: `wrapPOSIXProbeCommand(` occurrence counts are
//       exact per file (this covers the five `static let` commands and
//       multi-call functions), `wrapPOSIXShellCommand` is at zero, and every
//       true `func` builder named in `probeBuilders` still calls the non-login
//       wrapper. (`cpuSnapshotCommand`/`processDetailsCommand` build bodies
//       and never call the wrapper, so they are deliberately not builders.)
//    D. the wrapper itself: `wrapPOSIXProbeCommand`'s output keeps the
//       `sh -c '` prefix and carries the curated system PATH export
//       (`shellSystemPathExport()`), and its source body injects that export.
//
//  A renamed function reddens the exact-name comparisons (a deliberate
//  tripwire, not a silent pass); a token moved to a new function reddens the
//  set comparison and the occurrence-count pin. It is a tripwire, not a
//  proof. Remaining defeats: braces inside string literals are counted by the
//  block walk (balanced in these files today), a default-argument closure
//  would make the walk bind the wrong block, raw strings (`#"..."#`) are not
//  recognized by the comment stripper, comments inside an interpolation are
//  not stripped, a login-shell token assembled at runtime is invisible, an
//  aliased wrapper reference (`let wrap = …wrapPOSIXShellCommand; wrap(x)`)
//  is caught only at the binding, and a wrapper call built through a
//  dynamically constructed identifier is invisible. A commented-out token
//  cannot satisfy the pins (comments are stripped). Any intentional login
//  site added later must be added to the allowlists below deliberately.
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

    /// Every `.swift` file under `VVTerm/`, as repository-relative paths,
    /// recursively. The scan root and its subdirectories are the fail-closed
    /// scope: a new file anywhere in the app target must be consciously
    /// allowlisted before it can emit a login shell or reference the login
    /// wrapper.
    private func allSwiftFiles() -> [String] {
        let directory = repositoryRoot().appendingPathComponent("VVTerm")
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
            return []
        }
        var result: [String] = []
        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            result.append("VVTerm/\(relativePath)")
        }
        return result.sorted()
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
            "unwrapPOSIXShellInvocationIfNeeded",
            "wrapPOSIXShellCommand"
        ]
    ]

    /// Occurrence counts of the sh-family login tokens, the 9 sites of #323
    /// plan section 4.3: Mosh 110/112/134/154; Tmux 381/416/1062; Bootstrap
    /// 187/315 (the parser prefix array holds two tokens on one line).
    private static let expectedLoginShellOccurrences: [String: Int] = [
        "VVTerm/Core/SSH/RemoteMoshManager.swift": 4,
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": 3,
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 3
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
    ///   is the one allowed emitter reference outside a func body.
    private static let expectedLoginShellEmitterSites: [String: [String]] = [
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": ["launchPlan"],
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": [
            "createSessionCommand",
            "missingSessionCommand"
        ],
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": ["moshStartupScript"]
    ]

    /// Emitter occurrences inside function bodies (the `defaultLoginShellCommand`
    /// declaration is outside every body and counted separately below).
    private static let expectedLoginShellEmitterOccurrences: [String: Int] = [
        "VVTerm/Core/SSH/RemoteEnvironmentResolver.swift": 1,
        "VVTerm/Core/SSH/RemoteTmuxManager.swift": 2,
        "VVTerm/Core/SSH/RemoteTerminalBootstrap.swift": 1
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
    /// plain substring scan would miss.
    private static let loginShellEmitterPatterns = [
        #"defaultLoginShellCommand\("#,
        #"exec [^ ]*\$\{SHELL:-/bin/sh\}[^ ]* -l"#
    ]

    // MARK: - Pin B allowlists

    /// The functions allowed to call the *login* wrapper
    /// (`RemoteTerminalBootstrap.wrapPOSIXShellCommand`). A login *token*
    /// scan cannot see `wrapPOSIXShellCommand(body)`, so this is the allowlist
    /// that catches a new probe adopting the login wrapper. The scan looks for
    /// the bare identifier (not the `(`-suffixed form), so a
    /// `wrapPOSIXShellCommand (body)` spelling and a direct-form alias binding
    /// are visible too.
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

    // MARK: - Pins

    /// Pin A (#323/#324): login-shell tokens and emitters live only in the
    /// intentional-login allowlists, recursively across `VVTerm/`.
    @Test
    func testOnlyAllowlistedSitesEmitLoginShellTokensOrEmitters() throws {
        let files = try allSwiftFiles()

        // The recursive, fail-closed sweep: a new file (or a new literal in an
        // existing file) cannot adopt login semantics silently.
        for path in files {
            let text = Self.strippingComments(try source(path))
            let tokenCount = Self.shFamilyLoginTokenCount(in: text)
            if tokenCount > 0 {
                #expect(
                    Self.expectedLoginShellOccurrences[path] == tokenCount,
                    "\(path): \(tokenCount) sh-family login token(s); expected \(Self.expectedLoginShellOccurrences[path].map { String($0) } ?? "none") — a new login-shell literal must be consciously allowlisted"
                )
            }
            let emitterCount = Self.loginShellEmitterCount(in: text)
            if emitterCount > 0 {
                #expect(
                    Self.expectedLoginShellEmitterSites[path] != nil,
                    "\(path): \(emitterCount) login-shell emitter reference(s); the file is not in the emitter allowlist"
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
        let missing = knownFiles.subtracting(files)
        #expect(
            missing.isEmpty,
            "the recursive sweep missed known login-shell files \(missing.sorted()) — the sweep root is wrong, or a pinned file was moved"
        )
    }

    /// Pin B (#324): the only files that may reference the *login* wrapper are
    /// the three intentional-login files, and inside them only the enumerated
    /// functions may call it. This is the pin the literal-token scan cannot
    /// be: a new probe written as `wrapPOSIXShellCommand(body)` carries no
    /// literal `sh -lc`. The scan uses the bare identifier, so a whitespace
    /// variant or an alias binding is visible.
    @Test
    func testOnlyAllowlistedFilesAndFunctionsReferenceTheLoginWrapper() throws {
        let files = try allSwiftFiles()
        let knownFiles = Set(Self.expectedLoginWrapperSites.keys)
        let missing = knownFiles.subtracting(files)
        #expect(
            missing.isEmpty,
            "the recursive sweep missed known login-wrapper files \(missing.sorted()) — the sweep root is wrong, or a pinned file was moved"
        )

        for path in files {
            let text = Self.strippingComments(try source(path))
            if text.range(of: "wrapPOSIXShellCommand") != nil {
                #expect(
                    Self.expectedLoginWrapperSites[path] != nil,
                    "\(path): a login-wrapper reference must be consciously allowlisted"
                )
            }
        }

        for (path, allowed) in Self.expectedLoginWrapperSites {
            let text = Self.strippingComments(try source(path))
            let bodies = try Self.functionBodies(in: text)

            for name in allowed {
                #expect(
                    bodies.filter { $0.name == name }.count == 1,
                    "\(path): the allowlisted `\(name)` must resolve to exactly one function body"
                )
            }

            let callers = bodies
                .filter { text.range(of: "wrapPOSIXShellCommand", range: $0.body) != nil }
                .map(\.name)
                .sorted()
            #expect(
                callers == allowed.sorted(),
                "\(path): login-wrapper callers must be exactly \(allowed.sorted()), got \(callers)"
            )

            let insideBodyOccurrences = bodies.reduce(0) { count, body in
                count + Self.occurrences(
                    of: "wrapPOSIXShellCommand",
                    in: text,
                    range: body.body
                ).count
            }
            #expect(
                insideBodyOccurrences == Self.expectedLoginWrapperOccurrences[path],
                "\(path): the login-wrapper call count must stay \(Self.expectedLoginWrapperOccurrences[path] ?? -1)"
            )

            // The whole-file-vs-body mirror: a wrapper reference *outside* a
            // `func` body (a computed property, a file-scope binding) would
            // otherwise pass this pin and the recursive sweep, because the
            // file is already in the known-wrapper set. The only reference
            // legitimately outside a body is the declaration itself.
            let wholeFileOccurrences = Self.occurrences(
                of: "wrapPOSIXShellCommand",
                in: text
            ).count
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
            let text = Self.strippingComments(try source(path))
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
            let text = Self.strippingComments(try source(builder.path))
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

    // MARK: - Source helpers

    /// A comment-stripped copy of `source` for the token scans: characters
    /// inside `//` line comments and nested `/* … */` block comments become
    /// spaces; newlines are preserved, so slice anchors still resolve. String
    /// contents are copied verbatim (so a `//` inside a literal is not read as
    /// a comment); the scanner covers `"…"` (with `\` escapes) and `"""…"""`
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

    /// The sh-family login-token pattern. `\s+` keeps `sh  -lc` and `sh\n-lc`
    /// caught without a whitespace-collapsed copy; `\b` is a strict superset
    /// of the plan's `(^|[\s/])` prefix, so a token opening a string literal
    /// (`"sh -lc `) is caught as well as one after a path slash.
    private static let loginShellTokenPattern = #"\b(sh|bash|zsh|dash|ksh)\s+-lc\b"#

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
