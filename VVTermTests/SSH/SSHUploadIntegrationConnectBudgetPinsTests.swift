// SPDX-License-Identifier: MIT
//
//  SSHUploadIntegrationConnectBudgetPinsTests.swift
//  VVTermTests
//
//  Pins issue #356: the `teleport-e2e` upload legs' connect budget and the
//  production wiring that makes a widened budget effective.
//
//  THE DEFECT: `SSHClient.setConnectTimeout` replaced only the value the
//  outer `runWithTimeout` captured. The regular (raw-TCP) handshake path
//  hardcoded `libssh2_session_set_timeout(session, 30_000)` plus a
//  `35_000_000_000` ns watchdog, so the ~30.8 s `teleport-e2e` failures were
//  the *inner* cap right-censoring a stalled loopback handshake (`code=-9`),
//  not the stalled connect's length — widening only the outer budget would
//  not have reached them.
//
//  THE FIX (pinned here): `SSHClient.connect` passes its `connectTimeout`
//  into `SSHSessionConfig.connectionTimeout`; the regular handshake derives
//  `handshake = max(30, connect - 10)` / `watchdog = max(35, connect - 5)`
//  through `SSHSessionHandshakeBudget.forConnectTimeout` (the app default
//  30 s stays bit-identical: 30_000 ms / 35 s); the upload integration legs
//  connect with a measured `contendedConnectBudget` (90 s) instead of the
//  app default.
//
//  Why source pins: the derivation is a pure function and is asserted
//  directly, but the wiring — the config pass-through and the call inside
//  the regular branch — has no runtime seam without a live SSH server, so
//  those call sites are pinned as source scans. The budget value is pinned
//  against the live workflow allowance so the two cannot silently drift.
//
//  FORMATTING HEURISTIC, NOT A PROOF: the source scans read the files as
//  text. Comments are stripped before every scan, so a commented-out call
//  cannot satisfy (or trip) an assertion; string contents are copied
//  verbatim. The production-wiring scan binds the call *arguments*: the one
//  `libssh2_session_set_timeout(` call and the one handshake-region
//  `Task.sleep(` (label-checked) must reference the local bound from the one
//  `SSHSessionHandshakeBudget.forConnectTimeout(config.connectionTimeout)`
//  derivation, must match the `Int(<derived>.handshake * 1_000)` /
//  `UInt64(<derived>.watchdog * 1_000_000_000)` shape, and must carry no
//  other integer literal — so `30_000`, `30000`, `Int(30 * 1_000)`,
//  `35 * 1_000_000_000`, `UInt64(35 * 1_000_000_000)` and a second call
//  site all red; a same-named method on another receiver
//  (`Self.forConnectTimeout(…)`) reds too, because the derivation needle
//  carries its `SSHSessionHandshakeBudget.` receiver. Still defeated, stated
//  honestly: the scan is file-scoped (`SSHClient.swift` + the upload suite),
//  so a second `libssh2_session_set_timeout` call in another file is
//  invisible; and these admitted green shapes need binding/scope awareness
//  to close, not a better text scan: a same-name shadowing local (a
//  `do { let <derivedName> = SSHSessionHandshakeBudget.forConnectTimeout(30) … }`
//  after a dead derived binding supplies both the pinned name and a
//  hardcoded cap), the two-step client alias (`let t = SSHClient.self;
//  t.init()` — rejected inside `withConnection` by its bare `SSHClient` ban
//  but invisible in a leg), and an indirect `connectionTimeout` write the
//  scan cannot bind (e.g. `config[keyPath: \.connectionTimeout] = …`). A
//  watchdog that interrupts through an API other than
//  `atomicSocket.interrupt(` is likewise outside the scanned call surface.
//  An aliased derivation
//  (`let f = SSHSessionHandshakeBudget.forConnectTimeout`), a wrapping
//  helper, an argument assembled through an intermediate variable, or a
//  `var` binding red deliberately rather than passing. The `count == 1`
//  assertions are intentionally strict: a second client construction in any
//  `SSHClient(` / `SSHClient.init` (called or as a function reference) /
//  `SSHClient.self.init(` / bare `.init(` spelling, a second
//  `setConnectTimeout(` anywhere in the upload suite, a second
//  `handshake-watchdog` label or `atomicSocket.interrupt(` call anywhere in
//  `SSHClient.swift`, a post-construction `connectionTimeout =` write, or a
//  second `SSHSessionConfig(` / `SSHSessionConfig.init(` /
//  `SSHSessionConfig.self.init(` construction, must update this pin on
//  purpose — re-affirm the rule here when the shape changes.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the source scans at
//  a mutated tree (`TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<tree>` exported into
//  xcodebuild's own environment). Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

@MainActor
struct SSHUploadIntegrationConnectBudgetPinsTests {

    // MARK: - The budgets

    /// Assertion 1: the app default survives — the fix must be inert for the
    /// app while making a widened caller budget effective.
    @Test
    func testAppDefaultConnectBudgetIsUnchanged() async {
        let client = SSHClient()
        let timeout = await client.connectTimeout
        #expect(
            timeout == .seconds(30),
            "SSHClient's app default connect budget must stay 30 s (issue #356); found \(timeout)"
        )
    }

    /// Assertion 2: pins the **chosen** upload-leg budget, not a floor — a
    /// 60 s budget would admit a value the derivation's rationale rejects
    /// (the slow-regime successes measured 20.28–29.69 s).
    @Test
    func testUploadLegContendedBudgetIsTheMeasuredValue() {
        #expect(
            SSHUploadIntegrationTests.contendedConnectBudget == .seconds(90),
            "the upload legs' contended connect budget must stay 90 s (3× the slow-regime 29.7 s success, issue #356); found \(SSHUploadIntegrationTests.contendedConnectBudget)"
        )
    }

    /// Assertion 3: the budget must leave the leg's own work at least 30 s of
    /// the workflow's per-test allowance — and the ceiling is *read* from the
    /// workflow (both invocations, which must agree) so the two move
    /// together. Precedent: `WorkflowXcodebuildFlagPinsTests`.
    @Test
    func testUploadLegBudgetLeavesTheWorkflowAllowanceHeadroom() throws {
        let workflow = Self.strippingYAMLComments(
            try Self.source(".github/workflows/teleport-e2e.yml")
        )
        let allowances = Self.executionAllowances(in: workflow)
        #expect(
            allowances.count == 2,
            "`teleport-e2e.yml` must still have both `-default-test-execution-time-allowance` invocations (the main leg and the MallocScribble leg); found \(allowances.count) — re-derive this pin (issue #356)"
        )
        #expect(
            Set(allowances).count == 1,
            "both `-default-test-execution-time-allowance` values must agree; found \(allowances) — re-derive this pin (issue #356)"
        )
        let allowance = try #require(
            allowances.first,
            "`teleport-e2e.yml` must carry a `-default-test-execution-time-allowance` value — re-derive this pin (issue #356)"
        )
        #expect(
            SSHUploadIntegrationTests.contendedConnectBudget + .seconds(30) <= .seconds(allowance),
            "the 90 s contended connect budget must leave at least 30 s of the workflow's per-test allowance for the upload + read-back (measured ~48 s in the slow regime): budget \(SSHUploadIntegrationTests.contendedConnectBudget) + 30 s > allowance \(allowance) s — move the workflow allowance and this pin together (issue #356)"
        )
    }

    /// Assertion 4: the factory that `withConnection` routes through applies
    /// the budget (the compiled counterpart of pin A).
    @Test
    func testUploadClientFactoryAppliesTheContendedBudget() async {
        let client = await SSHUploadIntegrationTests.makeUploadClient()
        let timeout = await client.connectTimeout
        #expect(
            timeout == SSHUploadIntegrationTests.contendedConnectBudget,
            "`makeUploadClient()` must apply `contendedConnectBudget`; found \(timeout) on the client (issue #356)"
        )
    }

    /// Assertion 5: the derivation, pinned as an `Equatable` struct so the
    /// rules hold without a live handshake. The app default (30 s) must equal
    /// today's hardcoded pair; the upload legs' 90 s must produce 80 s / 85 s.
    @Test
    func testHandshakeBudgetDerivation() {
        #expect(
            SSHSessionHandshakeBudget.forConnectTimeout(30)
                == SSHSessionHandshakeBudget(handshake: 30, watchdog: 35),
            "a 30 s connect budget must derive exactly today's 30 s / 35 s caps (issue #356)"
        )
        #expect(
            SSHSessionHandshakeBudget.forConnectTimeout(90)
                == SSHSessionHandshakeBudget(handshake: 80, watchdog: 85),
            "a 90 s connect budget must derive an 80 s session timeout and an 85 s handshake watchdog (issue #356)"
        )

        for connect in [30.0, 35.0, 40.0, 60.0, 90.0, 120.0] {
            let budget = SSHSessionHandshakeBudget.forConnectTimeout(connect)
            #expect(
                budget.handshake >= 30,
                "the derived session-I/O timeout must never fall below the 30 s floor (connect \(connect): \(budget.handshake))"
            )
            #expect(
                budget.watchdog >= 35,
                "the derived watchdog must never fall below the 35 s floor (connect \(connect): \(budget.watchdog))"
            )
            #expect(
                budget.handshake <= budget.watchdog,
                "the session-I/O timeout must not outlive the watchdog (connect \(connect): \(budget.handshake) vs \(budget.watchdog))"
            )
            if connect >= 40 {
                #expect(
                    budget.watchdog < connect,
                    "the watchdog must stay inside the outer connect budget (connect \(connect): watchdog \(budget.watchdog))"
                )
            }
        }
    }

    // MARK: - Pin A: the upload suite's call site

    /// Assertion 6: the upload suite must construct its client in exactly one
    /// place — the factory — and `withConnection` must call that factory
    /// rather than constructing or re-configuring a client itself. Every
    /// construction spelling counts (`SSHClient(`, `SSHClient.init(` and a
    /// bare contextually-typed `.init(`), so `SSHClient.init()` cannot slip
    /// past the scan; the factory is also the suite's only
    /// `setConnectTimeout(` site, so no leg can reset the budget after it.
    @Test
    func testUploadSuiteBuildsItsClientThroughTheFactory() throws {
        let text = Self.strippingComments(
            try Self.source("VVTermTests/SSHUploadIntegrationTests.swift")
        )

        let suiteAnchor = try #require(
            text.range(of: "struct SSHUploadIntegrationTests"),
            "the upload suite must keep its `struct SSHUploadIntegrationTests` declaration — re-derive this pin (issue #356)"
        )
        let suiteBody = try Self.bracedBlock(after: suiteAnchor, in: text)

        let helperAnchor = try #require(
            text.range(of: "private func withConnection<T>(", range: suiteBody),
            "the upload suite must keep its `withConnection` helper — re-derive this pin (issue #356)"
        )
        let helperBody = try Self.bracedBlock(after: helperAnchor, in: text)

        // Positive controls: the resolved span is `withConnection`'s body.
        for token in [
            "KnownHostsManager.shared.entry(",
            "client.connect(to: server",
            "await client.disconnect()"
        ] {
            #expect(
                text[helperBody].contains(token),
                "the resolved `withConnection` span must contain `\(token)` — re-derive this pin (issue #356)"
            )
        }

        let helperCalls = Self.occurrences(of: "makeUploadClient(", in: text, range: helperBody)
        #expect(
            helperCalls.count == 1,
            "`withConnection` must build its client through exactly one `makeUploadClient(` call; found \(helperCalls.count) — re-derive this pin (issue #356)"
        )
        // Any mention of the type in the helper is illegitimate:
        // construction, an initializer-reference alias (`let make =
        // SSHClient.init`), or a re-configuration would all bypass the
        // factory (closure lens F1).
        for forbidden in ["SSHClient", "setConnectTimeout("] {
            let found = Self.occurrences(of: forbidden, in: text, range: helperBody)
            #expect(
                found.isEmpty,
                "`withConnection` must not mention `\(forbidden)` (\(found.count) occurrence(s)): constructing, aliasing or re-configuring a client in the helper would bypass the factory — re-derive this pin (issue #356)"
            )
        }

        // Every construction spelling counts: `SSHClient(`, `SSHClient.init`
        // (called or as the paren-less function reference `= SSHClient.init`),
        // `SSHClient.self.init(` and a bare contextually-typed `.init(`. The
        // helper-body ban above plus this file-wide count are what keep
        // `makeUploadClient` the only site (impl lens 2 MINOR-1 + closure
        // lens F1).
        var constructions = Self.occurrences(of: "SSHClient(", in: text)
        constructions += Self.regexOccurrences(
            of: #"\bSSHClient\s*(?:\.\s*self)?\s*\.\s*init\b"#,
            in: text
        )
        constructions += Self.regexOccurrences(
            of: #"(?<![\w.])\.init\s*\("#,
            in: text
        )
        constructions.sort { $0.lowerBound < $1.lowerBound }
        #expect(
            constructions.count == 1,
            "the upload suite must have exactly one client construction site (any `SSHClient(`, `SSHClient.init`, `SSHClient.self.init(` or bare `.init(` spelling, inside `makeUploadClient`); found \(constructions.count) — re-derive this pin (issue #356)"
        )
        // The factory is the suite's only budget setter (closure lens
        // R2-3): a leg calling `client.setConnectTimeout(…)` inside its own
        // `withConnection` closure would silently reset the 90 s budget
        // while every construction pin stayed green.
        let budgetCalls = Self.occurrences(of: "setConnectTimeout(", in: text)
        #expect(
            budgetCalls.count == 1,
            "the upload suite must contain exactly one `setConnectTimeout(` call (inside `makeUploadClient`); a leg-level reset would bypass the factory budget — found \(budgetCalls.count) — re-derive this pin (issue #356)"
        )
        let factoryAnchor = try #require(
            text.range(of: "static func makeUploadClient()", range: suiteBody),
            "the upload suite must keep its `makeUploadClient` factory — re-derive this pin (issue #356)"
        )
        let factoryBody = try Self.bracedBlock(after: factoryAnchor, in: text)
        if let construction = constructions.first {
            #expect(
                Self.isInside(factoryBody, construction.lowerBound),
                "the suite's only client construction must live inside `makeUploadClient` — re-derive this pin (issue #356)"
            )
        }
        if let budgetCall = budgetCalls.first {
            #expect(
                Self.isInside(factoryBody, budgetCall.lowerBound),
                "the suite's only `setConnectTimeout(` call must live inside `makeUploadClient` — re-derive this pin (issue #356)"
            )
        }
    }

    // MARK: - Pin B: the production wiring

    /// Assertion 7: `SSHClient.connect` must pass its `connectTimeout` into
    /// the `SSHSessionConfig`, and `SSHSession.connect()`'s regular handshake
    /// must derive its session-I/O timeout + watchdog through
    /// `forConnectTimeout(config.connectionTimeout)` — with the old hardcoded
    /// literals gone.
    @Test
    func testProductionWiringDerivesSessionCapsFromTheConnectBudget() throws {
        let text = Self.strippingComments(try Self.source("VVTerm/Core/SSH/SSHClient.swift"))

        // The config construction passes the caller's budget through. Count
        // every construction spelling — Pin A's regex family:
        // `SSHSessionConfig(`, `SSHSessionConfig.init` (called or as the
        // paren-less function reference `= SSHSessionConfig.init`), and
        // `SSHSessionConfig.self.init(`.
        var configConstructions = Self.occurrences(of: "SSHSessionConfig(", in: text)
        configConstructions += Self.regexOccurrences(
            of: #"\bSSHSessionConfig\s*(?:\.\s*self)?\s*\.\s*init\b"#,
            in: text
        )
        configConstructions.sort { $0.lowerBound < $1.lowerBound }
        #expect(
            configConstructions.count == 1,
            "SSHClient.swift must keep exactly one `SSHSessionConfig(` / `SSHSessionConfig.init` / `SSHSessionConfig.self.init(` construction site; found \(configConstructions.count) — re-derive this pin (issue #356)"
        )
        let configConstruction = try #require(
            configConstructions.first,
            "the `SSHSessionConfig(` construction site must exist — re-derive this pin (issue #356)"
        )
        let pendingSession = try #require(
            text.range(
                of: "let pendingSession = SSHSession(",
                range: configConstruction.upperBound..<text.endIndex
            ),
            "the `SSHSessionConfig(` construction must be followed by `let pendingSession = SSHSession(` — re-derive this pin (issue #356)"
        )
        let constructionRegion = configConstruction.upperBound..<pendingSession.lowerBound
        for token in ["credentials: credentials", "teleportNodeName: server.name"] {
            #expect(
                text[constructionRegion].contains(token),
                "the resolved config-construction region must contain `\(token)` — re-derive this pin (issue #356)"
            )
        }
        #expect(
            Self.rangeOfWhitespaceFlexible(
                "connectionTimeout: SSHClient.timeInterval(from: connectTimeout)",
                in: text,
                range: constructionRegion
            ) != nil,
            "the `SSHSessionConfig(` site must pass `connectionTimeout: SSHClient.timeInterval(from: connectTimeout)` so the caller's connect budget reaches the session caps — re-derive this pin (issue #356)"
        )
        // The value must not be overwritten before the session captures it
        // (closure lens R2-1): `connectionTimeout` is a `var` on the struct,
        // so `config.connectionTimeout = min(…, 30)` between the construction
        // and `let pendingSession` would restore the hardcoded cap while every
        // other pin stayed green. The only permitted `connectionTimeout =`
        // write is the stored-property assignment in `SSHSessionConfig`'s own
        // initializer.
        let configWrites = Self.regexOccurrences(
            of: #"\bconnectionTimeout\s*="#,
            in: text
        )
        #expect(
            configWrites.count == 1,
            "SSHClient.swift must contain exactly one `connectionTimeout =` assignment (the stored-property write in `SSHSessionConfig.init`); a post-construction override would defeat the derived cap — found \(configWrites.count) — re-derive this pin (issue #356)"
        )

        // The regular handshake derives its caps from that config value.
        let actorAnchor = try #require(
            text.range(of: "actor SSHSession {"),
            "SSHClient.swift must keep the `actor SSHSession {` declaration — re-derive this pin (issue #356)"
        )
        let actorSpan = actorAnchor.upperBound..<text.endIndex
        let connectAnchor = try #require(
            text.range(of: "func connect() async throws", range: actorSpan),
            "`SSHSession` must keep its `connect()` function — re-derive this pin (issue #356)"
        )
        let connectBody = try Self.bracedBlock(after: connectAnchor, in: text)
        // The tokens are the call/function *openers*, not the adjacent
        // arguments: a formatter that wraps after `set_timeout(session,`
        // must not red as if the call vanished (closure lens F5).
        for token in [
            "ssh_handshake_begin",
            "libssh2_session_set_timeout("
        ] {
            #expect(
                text[connectBody].contains(token),
                "the resolved `SSHSession.connect()` span must contain `\(token)` — re-derive this pin (issue #356)"
            )
        }
        // The watchdog interrupt is unique file-wide and lives in this body:
        // a second, earlier watchdog in a helper outside `connect()` could
        // fire first with a hardcoded cap (closure lens F2). This is the
        // watchdog counterpart of the file-wide
        // `libssh2_session_set_timeout(` count below.
        let watchdogInterrupts = Self.occurrences(
            of: "atomicSocket.interrupt(\"handshake-watchdog\")",
            in: text
        )
        #expect(
            watchdogInterrupts.count == 1,
            "SSHClient.swift must contain exactly one `atomicSocket.interrupt(\"handshake-watchdog\")` call — a second watchdog outside `connect()` could fire first with a hardcoded cap; found \(watchdogInterrupts.count) — re-derive this pin (issue #356)"
        )
        // The label, not just the exact call spelling (closure lens R2-2): a
        // re-spelled call whose label still contains `handshake-watchdog`
        // (`atomicSocket.interrupt("early-handshake-watchdog")`) must red too.
        let watchdogLabels = Self.occurrences(of: "handshake-watchdog", in: text)
        #expect(
            watchdogLabels.count == 1,
            "SSHClient.swift must contain exactly one `handshake-watchdog` label — a second watchdog outside `connect()` could fire first with a hardcoded cap; found \(watchdogLabels.count) — re-derive this pin (issue #356)"
        )
        // And the interrupt surface itself, so a fully re-spelled label or a
        // re-spaced call still reds. The five sites today: abort,
        // handshake-watchdog, disconnect-outer, cleanup-libssh2,
        // cleanup-libssh2-2.
        let socketInterrupts = Self.regexOccurrences(
            of: #"atomicSocket\s*\.\s*interrupt\s*\("#,
            in: text
        )
        #expect(
            socketInterrupts.count == 5,
            "SSHClient.swift must keep exactly five `atomicSocket.interrupt(` sites (abort, handshake-watchdog, disconnect-outer, cleanup-libssh2, cleanup-libssh2-2) — a new watchdog site must update this pin on purpose; found \(socketInterrupts.count) — re-derive this pin (issue #356)"
        )
        if let watchdogInterrupt = watchdogInterrupts.first {
            #expect(
                Self.isInside(connectBody, watchdogInterrupt.lowerBound),
                "the single `atomicSocket.interrupt(\"handshake-watchdog\")` must stay inside `SSHSession.connect()` (positive control for the resolved span) — re-derive this pin (issue #356)"
            )
        }
        // Exactly one derivation in `connect()`, bound with `let` (a `var`
        // binding could be reassigned after the derivation). The local name is
        // read from the source, so renaming it is fine; the expression itself
        // is pinned *with its receiver*, so aliasing, wrapping or a same-named
        // method on another receiver (`Self.forConnectTimeout(…)`) reds
        // (closure lens F3).
        let derivationNeedle = "SSHSessionHandshakeBudget.forConnectTimeout(config.connectionTimeout)"
        let derivationExpressions = Self.occurrences(
            of: derivationNeedle,
            in: text,
            range: connectBody
        )
        #expect(
            derivationExpressions.count == 1,
            "the regular handshake must derive its caps through exactly one `\(derivationNeedle)` expression (a dead extra reference or a receiver swap must update this pin); found \(derivationExpressions.count) — re-derive this pin (issue #356)"
        )
        let derivationExpression = try #require(
            derivationExpressions.first,
            "the regular handshake must derive its caps through `\(derivationNeedle)` — re-derive this pin (issue #356)"
        )
        // The receiver must be the real type, and that type must declare the
        // derivation exactly once: a same-named actor-local twin with
        // hardcoded caps cannot be what the call site binds.
        let budgetTypeAnchor = try #require(
            text.range(of: "struct SSHSessionHandshakeBudget"),
            "`SSHClient.swift` must keep the `struct SSHSessionHandshakeBudget` declaration — re-derive this pin (issue #356)"
        )
        let budgetTypeBody = try Self.bracedBlock(after: budgetTypeAnchor, in: text)
        let typeDerivations = Self.occurrences(
            of: "func forConnectTimeout(",
            in: text,
            range: budgetTypeBody
        )
        #expect(
            typeDerivations.count == 1,
            "`SSHSessionHandshakeBudget` must declare exactly one `func forConnectTimeout(` (the caps' single source); found \(typeDerivations.count) — re-derive this pin (issue #356)"
        )
        let derivationPrefix = String(text[connectBody.lowerBound..<derivationExpression.lowerBound])
        let bindingName = try #require(
            Self.firstCapture(
                ofPattern: #"let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*$"#,
                in: derivationPrefix
            ),
            "`\(derivationNeedle)` must be bound by `let <name> =` immediately before it (a `var` binding could be reassigned after the derivation) — re-derive this pin (issue #356)"
        )
        #expect(
            Self.occurrences(
                of: "SSHSessionHandshakeBudget(",
                in: text,
                range: connectBody
            ).isEmpty,
            "`SSHSession.connect()` must not construct `SSHSessionHandshakeBudget(` directly — a shadowing construction could make `\(bindingName)` name a hardcoded cap (issue #356)"
        )

        // The single session-I/O cap call must *consume* the derived value —
        // file-wide, so a helper outside the scanned body cannot silently
        // override it (impl lens 1 bypass A).
        let sessionCalls = Self.occurrences(
            of: "libssh2_session_set_timeout(",
            in: text
        )
        #expect(
            sessionCalls.count == 1,
            "SSHClient.swift must contain exactly one `libssh2_session_set_timeout(` call (a second one, e.g. in a helper outside `connect()`, would override the derived cap); found \(sessionCalls.count) — re-derive this pin (issue #356)"
        )
        let sessionCall = try #require(
            sessionCalls.first,
            "the `libssh2_session_set_timeout(` call must exist — re-derive this pin (issue #356)"
        )
        #expect(
            Self.isInside(connectBody, sessionCall.lowerBound),
            "the single `libssh2_session_set_timeout(` call must stay inside `SSHSession.connect()`'s branch (positive control for the resolved span) — re-derive this pin (issue #356)"
        )
        let sessionArgument = try Self.parenthesizedArgument(
            after: sessionCall.upperBound,
            in: text
        )
        #expect(
            sessionArgument.text.contains("\(bindingName).handshake"),
            "the `libssh2_session_set_timeout(` argument must reference `\(bindingName).handshake`; found `\(sessionArgument.text.trimmingCharacters(in: .whitespacesAndNewlines))` — re-derive this pin (issue #356)"
        )
        let sessionLiterals = Self.numericLiteralTokens(in: sessionArgument.text)
            .filter { !Self.conversionScaleFactors.contains($0) }
        #expect(
            sessionLiterals.isEmpty,
            "the `libssh2_session_set_timeout(` argument must not carry a numeric literal (only the `1_000` conversion factor is allowed); found \(sessionLiterals) in `\(sessionArgument.text.trimmingCharacters(in: .whitespacesAndNewlines))` — the cap must derive from the connect budget (issue #356)"
        )
        #expect(
            Self.rangeOfWhitespaceFlexible(
                "Int(\(bindingName).handshake * 1_000)",
                in: text,
                range: sessionArgument.range
            ) != nil,
            "the `libssh2_session_set_timeout(` argument must be `Int(\(bindingName).handshake * 1_000)`, not `\(sessionArgument.text.trimmingCharacters(in: .whitespacesAndNewlines))` — re-derive this pin (issue #356)"
        )

        // The single handshake watchdog must consume the derived `watchdog`.
        // The count matches the `Task.sleep(` opener, not the adjacent
        // `nanoseconds:` label, so a formatter that wraps after the opener or
        // after the colon stays green (closure lens F5); the label itself is
        // asserted below.
        let watchdogSleeps = Self.regexOccurrences(
            of: #"(?<![A-Za-z0-9_])Task\s*\.\s*sleep\s*\("#,
            in: text,
            range: connectBody
        )
        #expect(
            watchdogSleeps.count == 1,
            "`SSHSession.connect()` must contain exactly one handshake-watchdog `Task.sleep(`; found \(watchdogSleeps.count) — re-derive this pin (issue #356)"
        )
        let watchdogSleep = try #require(
            watchdogSleeps.first,
            "the handshake watchdog's `Task.sleep(` must exist — re-derive this pin (issue #356)"
        )
        let watchdogArgument = try Self.parenthesizedArgument(
            after: watchdogSleep.upperBound,
            in: text
        )
        #expect(
            watchdogArgument.text.contains("nanoseconds:"),
            "the handshake watchdog's `Task.sleep(` must use the `nanoseconds:` label; found `\(watchdogArgument.text.trimmingCharacters(in: .whitespacesAndNewlines))` — re-derive this pin (issue #356)"
        )
        #expect(
            watchdogArgument.text.contains("\(bindingName).watchdog"),
            "the handshake watchdog's `Task.sleep(` argument must reference `\(bindingName).watchdog`; found `\(watchdogArgument.text.trimmingCharacters(in: .whitespacesAndNewlines))` — re-derive this pin (issue #356)"
        )
        let watchdogLiterals = Self.numericLiteralTokens(in: watchdogArgument.text)
            .filter { !Self.conversionScaleFactors.contains($0) }
        #expect(
            watchdogLiterals.isEmpty,
            "the watchdog `Task.sleep(nanoseconds:` argument must not carry a numeric literal (only the `1_000_000_000` conversion factor is allowed); found \(watchdogLiterals) in `\(watchdogArgument.text.trimmingCharacters(in: .whitespacesAndNewlines))` — the watchdog must derive from the connect budget (issue #356)"
        )
        #expect(
            Self.rangeOfWhitespaceFlexible(
                "UInt64(\(bindingName).watchdog * 1_000_000_000)",
                in: text,
                range: watchdogArgument.range
            ) != nil,
            "the watchdog argument must be `UInt64(\(bindingName).watchdog * 1_000_000_000)`, not `\(watchdogArgument.text.trimmingCharacters(in: .whitespacesAndNewlines))` — re-derive this pin (issue #356)"
        )

        for literal in ["30_000", "35_000_000_000"] {
            let found = Self.occurrences(of: literal, in: text, range: connectBody)
            #expect(
                found.isEmpty,
                "the hardcoded `\(literal)` must not return to `SSHSession.connect()` (\(found.count) occurrence(s)): the caps must derive from the connect budget — re-derive this pin (issue #356)"
            )
        }
    }

    // MARK: - The conversion

    /// Assertion 8: the `Duration` → `TimeInterval` bridge itself (closure
    /// lens R2-4). The wiring pin binds the *call* text, so a body that
    /// dropped the attoseconds term would leave every source scan green while
    /// a fractional budget silently truncated; assert the conversion
    /// directly (integral and fractional cases).
    @Test
    func testTimeIntervalConversionPreservesIntegralAndFractionalSeconds() {
        #expect(
            SSHClient.timeInterval(from: .seconds(90)) == 90.0,
            "an integral connect budget must convert exactly (90 s → 90.0)"
        )
        #expect(
            SSHClient.timeInterval(from: .seconds(1) + .milliseconds(500)) == 1.5,
            "a fractional connect budget must keep its attoseconds term (1.5 s → 1.5) — a dropped term returns 1.0 (issue #356)"
        )
    }

    // MARK: - Fixtures

    private struct PinFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }
    }

    /// The repository root, derived by walking up from this file's location
    /// (`VVTermTests/SSH/SSHUploadIntegrationConnectBudgetPinsTests.swift`)
    /// until `VVTerm.xcodeproj` is found.
    private static func repositoryRoot() throws -> URL {
        // Counterfactual hook: the mutation runs point this at a copy of the
        // source tree with a mutation applied. Never set in CI.
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
            "could not locate the repository root (no VVTerm.xcodeproj above \(#filePath)) — re-derive this pin (issue #356)"
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = try repositoryRoot().appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PinFailure("could not read \(relativePath) at \(url.path): \(error) — re-derive this pin (issue #356)")
        }
    }

    /// Every `-default-test-execution-time-allowance <seconds>` value in a
    /// YAML-comment-stripped workflow, in file order.
    private static func executionAllowances(in workflow: String) -> [Int] {
        var result: [Int] = []
        for line in workflow.components(separatedBy: "\n") {
            guard let range = line.range(
                of: #"-default-test-execution-time-allowance\s+(\d+)"#,
                options: .regularExpression
            ) else { continue }
            let match = String(line[range])
            if let value = Int(match.components(separatedBy: .whitespaces).last ?? "") {
                result.append(value)
            }
        }
        return result
    }

    // MARK: - Source helpers

    /// A comment-stripped copy of `source` for the token scans: characters
    /// inside `//` line comments and nested `/* … */` block comments become
    /// spaces; newlines are preserved, so slice anchors still resolve. String
    /// contents are copied verbatim. Duplicated from the merged pin suites
    /// (`SSHUploadChannelFreePinsTests`, `SSHProxyChannelFreePinsTests`) so
    /// each family's pin file is self-contained and reverts independently.
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

    /// A YAML comment-stripped copy of `source`: a `#` that starts a comment
    /// (at line start or preceded by whitespace, outside a quoted scalar)
    /// blanks the rest of the line; newlines are preserved, so line anchors
    /// still resolve. Single-quoted (`''` escapes) and double-quoted (`\`
    /// escapes) scalars are copied verbatim. Duplicated from
    /// `WorkflowXcodebuildFlagPinsTests` so each pin file is self-contained.
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

    /// The body span `{ … }` of the brace-delimited block that opens at
    /// `open`, found by a character-level depth walk.
    private static func bracedBlock(
        openingAt open: String.Index,
        in text: String
    ) throws -> Range<String.Index> {
        try #require(text[open] == "{", "the explicit block open must be a `{`")
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
    ///
    /// The anchor must be **brace-less** for the intended block to be the one
    /// it opens: `bracedBlock` binds the first `{` after the anchor.
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

    /// Whether `index` falls strictly inside the `block` span (the span
    /// returned by `bracedBlock` excludes the braces themselves).
    private static func isInside(_ block: Range<String.Index>, _ index: String.Index) -> Bool {
        block.lowerBound < index && index < block.upperBound
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

    /// Every match of the ICU regular expression `pattern` in `text`
    /// (optionally within `range`), in source order. Used for
    /// construction-spelling counts (`SSHClient.init(`, bare `.init(`) and
    /// the `Task.sleep(` watchdog-opener count, which literal substring scans
    /// cannot see.
    private static func regexOccurrences(
        of pattern: String,
        in text: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        let searchRange = range ?? text.startIndex..<text.endIndex
        var result: [Range<String.Index>] = []
        var searchStart = searchRange.lowerBound
        while searchStart < searchRange.upperBound,
              let found = text.range(
                  of: pattern,
                  options: .regularExpression,
                  range: searchStart..<searchRange.upperBound
              ) {
            result.append(found)
            searchStart = found.upperBound
        }
        return result
    }

    /// The first capture group of the first match of `pattern` in `text`.
    private static func firstCapture(
        ofPattern pattern: String,
        in text: String,
        group: Int = 1
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    /// The argument text of a call whose argument list opens before `start`,
    /// found by a character-level paren-depth walk. `start` is the index just
    /// after the enclosing `(` (or after a `label:` whose argument opens its
    /// own parenthesised conversion), and the walk starts at depth 1.
    private static func parenthesizedArgument(
        after start: String.Index,
        in text: String
    ) throws -> (text: String, range: Range<String.Index>) {
        var depth = 1
        var index = start
        var close: String.Index?
        while index < text.endIndex, close == nil {
            if text[index] == "(" {
                depth += 1
            } else if text[index] == ")" {
                depth -= 1
                if depth == 0 { close = index }
            }
            index = text.index(after: index)
        }
        let end = try #require(
            close,
            "the pinned call's parentheses must balance — re-derive this pin (issue #356)"
        )
        let range = start..<end
        return (String(text[range]), range)
    }

    /// Every integer-literal token in `text`; the lookarounds keep `UInt64`'
    /// and identifiers out. The budget arguments are integer conversions, so
    /// this is the numeric-literal ban the wiring pin needs.
    private static func numericLiteralTokens(in text: String) -> [String] {
        regexOccurrences(
            of: #"(?<![A-Za-z0-9_])[0-9][0-9_]*(?![A-Za-z0-9_])"#,
            in: text
        ).map { String(text[$0]) }
    }

    /// The only numeric literals allowed in the pinned call arguments: the
    /// seconds → milliseconds / nanoseconds conversion factors. Anything else
    /// (e.g. `30_000`, `30000`, `Int(30 * 1_000)`) reds the numeric ban.
    private static let conversionScaleFactors: Set<String> = ["1_000", "1_000_000_000"]

    /// The range of the first whitespace-flexible occurrence of `needle`
    /// within `text[searchRange]`. `needle` is split on single spaces, and
    /// each piece must occur in order, separated by at least one whitespace
    /// character in `text` — so this matches the call's exact *expression*
    /// while tolerating the source's line breaks. A dropped or reordered
    /// argument does not match.
    private static func rangeOfWhitespaceFlexible(
        _ needle: String,
        in text: String,
        range searchRange: Range<String.Index>
    ) -> Range<String.Index>? {
        let tokens = needle.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }
        var searchStart = searchRange.lowerBound
        while let candidate = text.range(of: first, range: searchStart..<searchRange.upperBound) {
            if let end = whitespaceFlexibleMatchEnd(
                tokens: tokens,
                in: text,
                after: candidate,
                limit: searchRange.upperBound
            ) {
                return candidate.lowerBound..<end
            }
            searchStart = text.index(after: candidate.lowerBound)
        }
        return nil
    }

    /// The end index of a match whose first token is `firstMatch`, or nil when
    /// the remaining tokens do not line up token-for-token.
    private static func whitespaceFlexibleMatchEnd(
        tokens: [String],
        in text: String,
        after firstMatch: Range<String.Index>,
        limit: String.Index
    ) -> String.Index? {
        var upper = firstMatch.upperBound
        for token in tokens.dropFirst() {
            var cursor = upper
            var consumedWhitespace = false
            while cursor < limit, text[cursor].isWhitespace {
                consumedWhitespace = true
                cursor = text.index(after: cursor)
            }
            guard consumedWhitespace else { return nil }
            guard let tokenRange = text.range(of: token, range: cursor..<limit),
                  tokenRange.lowerBound == cursor else { return nil }
            upper = tokenRange.upperBound
        }
        return upper
    }
}
