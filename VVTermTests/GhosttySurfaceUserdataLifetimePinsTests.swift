// SPDX-License-Identifier: MIT
//
//  GhosttySurfaceUserdataLifetimePinsTests.swift
//  VVTermTests
//
//  Source pins for #310: a ghostty surface must never hold a raw pointer to a
//  `GhosttyTerminalView`. The surface's userdata is a retained
//  `Ghostty.SurfaceCallbackContext`; every callback resolves the view through
//  it, and both `ghostty_surface_free` paths invalidate it first.
//
//  #327 extends this file with P-E (the clipboard-confirmation resolve guards)
//  and P-F (prompt title + default-button parity), and with P-G (the
//  completion gate's captured-handle comparison). #329 extends it with P-H
//  (the teardown drain ordering, the completion's claim discipline, the
//  per-branch registration order, and the registry invariants).
//
//  WHAT THESE PINS ASSERT
//    P-A  repo-wide: no `Unmanaged<GhosttyTerminalView>` cast remains anywhere
//         under `VVTerm/` (the scan fails closed when it enumerates no files
//         or misses the `Ghostty.App.swift` sentinel).
//    P-B  every routing site resolves through the chosen helper
//         (`Ghostty.SurfaceCallbackContext.fromOpaque(`): three in
//         `Ghostty.App.swift` (action fallback, readClipboard, closeSurface)
//         and one per platform write callback; the single
//         `ghostty_surface_userdata(` read is paired with that helper; both
//         `setupSurface` bodies assign `surfaceConfig.userdata =
//         callbackContext.userdata` and keep the context alive across
//         `ghostty_surface_new` with `withExtendedLifetime`.
//    P-C  `Ghostty.Surface`: the initializer stores the context, and both free
//         paths (`free()`, `deinit`) call `callbackContext.invalidate()`
//         before `ghostty_surface_free`; the deferred `deinit` block retains
//         the context via `withExtendedLifetime(callbackContext)`.
//    P-D  both `setupWriteCallback` bodies pass `callbackContext.userdata` to
//         `ghostty_surface_set_write_callback`, unwrap the context, and carry
//         no `Unmanaged.passUnretained(self)` view cast.
//    P-E  (#327) `confirmReadClipboard`'s two `complete(surface:` call sites
//         are each preceded by their own `fromOpaque` resolve guard — the
//         ordering test 8 cannot observe with `state: nil`.
//    P-F  (#327 tripwire) both platform presenters take the prompt title from
//         `ClipboardConfirmationRequest.promptTitle` (no inlined literal) and
//         designate the paste action as the default button.
//    P-G  (#327) the confirmation completion `Task` resolves the context once,
//         compares the captured handle (`liveView.surface?.unsafeCValue ==
//         surface`) as the last check before the completion, and keeps the
//         drop-path `else` between them — the half the behavioural seam-death
//         test cannot discriminate (`cleanup()` invalidates the context first,
//         so deleting only the comparison stays green there).
//    P-H  (#329) both `Ghostty.Surface` free paths order invalidate → drain →
//         `ghostty_surface_free` (the deinit drain inside
//         `withExtendedLifetime(context)`); `complete` orders its nil-state
//         guard → non-optional-context claim → C call with the claim's guard
//         `else` between them; both `confirmReadClipboard` branches register
//         after their own resolve guard (the prompt branch also after the
//         payload copy); and `invalidate()` never clears the registry while
//         the drain never consults `isValid`, keeps the deny literal
//         arguments, and (tripwire, not a guarantee) no direct C completion
//         sits in the scanned `withLock` bodies. There is no behavioural
//         deinit-drain test: the deferred drain needs a real core-allocated
//         request state, and every available seam lets the completion Task
//         claim before the deferred free runs — coverage is the registry
//         invalidate-then-drain test plus the P-H1 ordering pin.
//
//  WHAT THEY DO NOT SEE. A renamed helper, an aliased userdata pointer, a
//  callback that unwraps the context and then casts the view through a new
//  spelling, or a behavioural regression in the context itself. Comments are
//  stripped before every scan, so a commented-out cast cannot satisfy a pin,
//  but a string literal containing the pinned text could. P-E and P-G see the
//  presence and order of the resolve/comparison tokens, not the semantics of
//  the guards they sit in; P-F is a parity tripwire, not a behaviour test — a
//  default button set by another mechanism would escape it.
//
//  MEASURED COUNTERFACTUALS (each pin red under a targeted mutation, run with
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>`):
//    P-A  re-add `Unmanaged<GhosttyTerminalView>` to the action fallback →
//         `offenders: ["Ghostty.App.swift"]`.
//    P-B  rename the `readClipboard` context route to a non-context helper →
//         `P-B: readClipboard must resolve through the context exactly once; found 0`
//         (and the file-level count drops to 2).
//    P-C  delete `callbackContext.invalidate()` from `free()` →
//         the invalidate-before-free order assertion fails.
//    P-D  revert the iOS write callback to `passUnretained(self)` →
//         `callbackContext.userdata` count 0 / `passUnretained(self)` present.
//    P-E  route the paste-branch resolve through a renamed helper (the scan is
//         exact-token: `fromOpaque(` must appear) → `routes.count → 1` and the
//         second `complete(surface:` site fails `precedingRoutes > index`.
//    P-F  inline `"Paste Unsafe Text?"` in the iOS presenter → the iOS
//         literal-absence assertion fails.
//    P-G  delete `, liveView.surface?.unsafeCValue == surface` from the
//         completion gate (keeping the resolve) → the comparison count drops
//         to 0.
//    P-H  (#329; each row names its harness — "pin" = the pin suite run
//         against a mutated source copy via `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT`,
//         "behavioural" = a rebuilt mutated copy): delete the free-path drain →
//         behavioural (seam-death test); move the drain after the free → pin
//         P-H1; delete the claim → behavioural (no-double-complete test, a
//         clean pre-teardown assertion since fold round 1); discard the claim
//         result with `_ =` → pin P-H2; make `complete`'s `context` parameter
//         optional again → pin P-H2 (the non-optional-context assertion);
//         delete the deny-branch registration → pin P-H3; delete the
//         prompt-branch registration → behavioural (seam-death test, CF-4);
//         move a registration above its resolve guard → pin P-H3
//         (non-minimal mutation; P-B/P-E also red on the extra route); make
//         `invalidate()` clear the registry → behavioural (registry test 3);
//         make the drain consult `isValid` → pin P-H4 (measured in fold round
//         1); move the drain's C call under `withLock` → pin P-H4 (synthetic
//         stand-in that inserts a C call into the lock body, not the real
//         relocation); change the drain's deny arguments → pin P-H4.

import Foundation
import Testing

@testable import VVTerm

struct GhosttySurfaceUserdataLifetimePinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/GhosttySurfaceUserdataLifetimePinsTests.swift`).
    ///
    /// Counterfactual hook: the mutation runs point this at a mutated tree to
    /// prove the pins fail there. Never set in CI. As with the other pin
    /// suites, the variable must reach the test process as
    /// `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT` in xcodebuild's environment (a
    /// plain env var is inert); alternatively hand-mutate the worktree and
    /// restore it.
    private func repositoryRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GhosttySurfaceUserdataLifetimePinsTests.swift
            .deletingLastPathComponent()  // VVTermTests/
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static let appSource = "VVTerm/GhosttyTerminal/Ghostty.App.swift"
    private static let surfaceSource = "VVTerm/GhosttyTerminal/Ghostty.Surface.swift"
    private static let contextSource = "VVTerm/GhosttyTerminal/Ghostty.SurfaceCallbackContext.swift"
    private static let renderingSetupSource = "VVTerm/GhosttyTerminal/GhosttyRenderingSetup.swift"
    private static let iOSViewSource = "VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift"
    private static let macOSViewSource = "VVTerm/GhosttyTerminal/GhosttyTerminalView+macOS.swift"
    private static let iOSClipboardConfirmationSource = "VVTerm/GhosttyTerminal/Ghostty.App+ClipboardConfirmation+iOS.swift"
    private static let macOSClipboardConfirmationSource = "VVTerm/GhosttyTerminal/Ghostty.App+ClipboardConfirmation+macOS.swift"

    /// The exact helper every routed callback must use.
    private static let contextRoute = "Ghostty.SurfaceCallbackContext.fromOpaque("

    // MARK: - P-A: no raw view casts repo-wide

    /// Repo-wide scan of `VVTerm/**/*.swift` for `Unmanaged<GhosttyTerminalView>`.
    /// This is the pin that makes the fix's core property structural: the
    /// surface userdata must never be unwrapped as the view again.
    @Test
    func testPANoSurfaceUserdataHoldsARawViewCast() throws {
        let scanRoot = repositoryRoot().appendingPathComponent("VVTerm")
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: scanRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }

        // Fail closed: an empty or wrong root must red the pin, not pass it.
        #expect(!files.isEmpty, "P-A: the scan must enumerate Swift files under VVTerm/")
        let sentinel = scanRoot.appendingPathComponent("GhosttyTerminal/Ghostty.App.swift").standardizedFileURL
        #expect(
            files.contains { $0.standardizedFileURL == sentinel },
            "P-A: the scan must include the Ghostty.App.swift sentinel"
        )

        var offenders: [String] = []
        for url in files {
            let text = Self.strippingComments(try String(contentsOf: url, encoding: .utf8))
            if !Self.occurrences(of: "Unmanaged<GhosttyTerminalView>", in: text).isEmpty {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(
            offenders.isEmpty,
            "P-A: no surface callback may cast the userdata to a raw view; offenders: \(offenders.sorted())"
        )
    }

    // MARK: - P-B: every routing site resolves through the context

    /// The app-level routing sites (action/readClipboard/closeSurface and the
    /// #327 confirmation callback's two branches) and the one-per-platform write
    /// callbacks all use the context helper, and the only
    /// `ghostty_surface_userdata(` read is the action fallback paired with it.
    @Test
    func testPBEveryRoutingSiteResolvesThroughTheContext() throws {
        let appText = Self.strippingComments(try source(Self.appSource))
        let appRoutes = Self.flexibleOccurrences(
            of: "Ghostty.SurfaceCallbackContext .fromOpaque(",
            in: appText
        )
        #expect(
            appRoutes.count == 5,
            "P-B: Ghostty.App.swift must route action/readClipboard/closeSurface and both confirmReadClipboard branches through the context; found \(appRoutes.count)"
        )
        #expect(
            Self.occurrences(of: "ghostty_surface_userdata(", in: appText).count == 1,
            "P-B: Ghostty.App.swift must read the surface userdata exactly once (the action fallback)"
        )
        #expect(
            Self.flexibleOccurrences(
                of: "Ghostty.SurfaceCallbackContext .fromOpaque(ghostty_surface_userdata(surface))",
                in: appText
            ).count == 1,
            "P-B: the action fallback must pair ghostty_surface_userdata(surface) with the context helper"
        )

        // Per-site anchors: the file-level count above can stay at 3 while one
        // site is left unrouted and another is routed twice (or a route moves
        // out of its function), so each of the three app routes is anchored to
        // its own function body.
        let appRoutingSites: [(name: String, anchor: String, expected: Int)] = [
            ("action fallback", "func action(", 1),
            ("readClipboard", "func readClipboard(", 1),
            ("closeSurface", "func closeSurface(", 1),
            ("clipboard confirmation", "func confirmReadClipboard(", 2),
        ]
        for site in appRoutingSites {
            let anchor = try #require(
                Self.occurrences(of: site.anchor, in: appText).first,
                "P-B: Ghostty.App.swift must keep \(site.name)"
            )
            let body = try Self.bracedBlock(after: anchor, in: appText)
            let routes = Self.flexibleOccurrences(
                of: "Ghostty.SurfaceCallbackContext .fromOpaque(",
                in: appText,
                range: body
            )
            #expect(
                routes.count == site.expected,
                "P-B: \(site.name) must resolve through the context \(site.expected) time(s); found \(routes.count)"
            )
        }

        // #327 non-negotiable 1: the confirmation completion runs after the
        // callback frame, so its Task closure must use the captured context and
        // never re-read the unretained userdata.
        let confirmAnchor = try #require(
            Self.occurrences(of: "func confirmReadClipboard(", in: appText).first,
            "P-B: Ghostty.App.swift must keep confirmReadClipboard"
        )
        let confirmBody = try Self.bracedBlock(after: confirmAnchor, in: appText)
        let taskAnchor = try #require(
            Self.occurrences(of: "Task ", in: appText, range: confirmBody).first,
            "P-B: the confirmation callback must dispatch its completion through a Task"
        )
        let taskBody = try Self.bracedBlock(after: taskAnchor, in: appText)
        #expect(
            Self.flexibleOccurrences(
                of: "Ghostty.SurfaceCallbackContext .fromOpaque(",
                in: appText,
                range: taskBody
            ).isEmpty,
            "P-B: the confirmation completion closure must use the captured context, never re-read userdata"
        )

        for file in [Self.iOSViewSource, Self.macOSViewSource] {
            let text = Self.strippingComments(try source(file))
            let routes = Self.flexibleOccurrences(
                of: "Ghostty.SurfaceCallbackContext .fromOpaque(",
                in: text
            )
            #expect(
                routes.count == 1,
                "P-B: \(file) must route its write callback through the context; found \(routes.count)"
            )
        }
    }

    /// Both `setupSurface` branches install the context as the userdata before
    /// `ghostty_surface_new` and keep it alive across the call (the core emits
    /// set_title/cell_size from inside `Surface.init`).
    @Test
    func testPBBothSetupSurfaceBranchesInstallTheContextUserdata() throws {
        let text = Self.strippingComments(try source(Self.renderingSetupSource))
        let anchors = Self.occurrences(of: "func setupSurface(", in: text)
        #expect(anchors.count == 2, "P-B: both platform setupSurface functions must exist")

        for anchor in anchors {
            let body = try Self.bracedBlock(after: anchor, in: text)
            #expect(
                Self.occurrences(of: "surfaceConfig.userdata = callbackContext.userdata", in: text, range: body).count == 1,
                "P-B: setupSurface must assign surfaceConfig.userdata = callbackContext.userdata exactly once"
            )
            #expect(
                Self.occurrences(of: "surfaceConfig.userdata = Unmanaged", in: text, range: body).count == 0,
                "P-B: setupSurface must not assign a raw Unmanaged pointer as userdata"
            )
            // Positive control: this is the real platform body (it still sets
            // the creation-time platform view pointer).
            #expect(
                Self.occurrences(of: "Unmanaged.passUnretained(view).toOpaque()", in: text, range: body).count == 1,
                "P-B: the resolved span must be a real setupSurface body with its platform view pointer"
            )

            let retain = try #require(
                Self.occurrences(of: "withExtendedLifetime(callbackContext", in: text, range: body).first,
                "P-B: setupSurface must keep the context alive across ghostty_surface_new"
            )
            let create = try #require(
                text.range(of: "ghostty_surface_new(", range: body),
                "P-B: setupSurface must call ghostty_surface_new"
            )
            #expect(
                retain.lowerBound < create.lowerBound,
                "P-B: the context must be retained across the ghostty_surface_new call"
            )
        }
    }

    // MARK: - P-C: invalidate before every free, retain across the deferred free

    /// `Ghostty.Surface` stores the context in its initializer, invalidates it
    /// before `ghostty_surface_free` on both free paths, and the deferred block
    /// keeps it alive with `withExtendedLifetime`.
    @Test
    func testPCSurfaceInvalidatesBeforeEveryFreeAndRetainsTheContext() throws {
        let text = Self.strippingComments(try source(Self.surfaceSource))

        let initAnchor = try #require(
            Self.occurrences(of: "init(cSurface: ghostty_surface_t, callbackContext: Ghostty.SurfaceCallbackContext)", in: text).first,
            "P-C: Surface must keep its context-carrying initializer"
        )
        let initBody = try Self.bracedBlock(after: initAnchor, in: text)
        #expect(
            Self.occurrences(of: "self.callbackContext = callbackContext", in: text, range: initBody).count == 1,
            "P-C: the initializer must store the callback context"
        )

        let freeAnchor = try #require(
            Self.occurrences(of: "func free()", in: text).first,
            "P-C: Surface must keep its synchronous free()"
        )
        let freeBody = try Self.bracedBlock(after: freeAnchor, in: text)
        let freeInvalidate = try #require(
            text.range(of: "callbackContext.invalidate()", range: freeBody),
            "P-C: free() must invalidate the context"
        )
        let freeCall = try #require(
            text.range(of: "ghostty_surface_free(", range: freeBody),
            "P-C: free() must call ghostty_surface_free"
        )
        #expect(
            freeInvalidate.lowerBound < freeCall.lowerBound,
            "P-C: free() must invalidate the context before ghostty_surface_free"
        )

        let deinitAnchors = Self.occurrences(of: "deinit", in: text)
        #expect(deinitAnchors.count == 1, "P-C: Surface must have exactly one deinit")
        let deinitBody = try Self.bracedBlock(after: try #require(deinitAnchors.first), in: text)
        let deinitInvalidate = try #require(
            text.range(of: "callbackContext.invalidate()", range: deinitBody),
            "P-C: deinit must invalidate the context"
        )
        let deinitFree = try #require(
            text.range(of: "ghostty_surface_free(", range: deinitBody),
            "P-C: deinit must call ghostty_surface_free"
        )
        #expect(
            deinitInvalidate.lowerBound < deinitFree.lowerBound,
            "P-C: deinit must invalidate the context before ghostty_surface_free"
        )

        #expect(
            Self.occurrences(of: "let context = callbackContext", in: text, range: deinitBody).count == 1,
            "P-C: deinit must bind a strong local for the deferred block to capture"
        )
        let asyncAnchor = try #require(
            text.range(of: "DispatchQueue.main.async", range: deinitBody),
            "P-C: deinit must defer the free to the main queue"
        )
        let asyncBody = try Self.bracedBlock(after: asyncAnchor, in: text)
        #expect(
            Self.occurrences(of: "withExtendedLifetime(context)", in: text, range: asyncBody).count == 1,
            "P-C: the deferred free block must retain the captured context with withExtendedLifetime(context)"
        )
        #expect(
            Self.occurrences(of: "ghostty_surface_free(", in: text, range: asyncBody).count == 1,
            "P-C: the deferred block must be the single ghostty_surface_free call"
        )
    }

    // MARK: - P-D: the write callbacks use the context userdata

    /// Both platform `setupWriteCallback` bodies pass `callbackContext.userdata`
    /// to the C API and unwrap the context, with no view-address userdata left.
    @Test
    func testPDWriteCallbacksUseTheContextUserdata() throws {
        for file in [Self.iOSViewSource, Self.macOSViewSource] {
            let text = Self.strippingComments(try source(file))
            let anchor = try #require(
                Self.occurrences(of: "func setupWriteCallback()", in: text).first,
                "P-D: \(file) must keep setupWriteCallback()"
            )
            let body = try Self.bracedBlock(after: anchor, in: text)

            #expect(
                Self.occurrences(of: "ghostty_surface_set_write_callback(", in: text, range: body).count == 1,
                "P-D: \(file) must install exactly one write callback"
            )
            #expect(
                Self.occurrences(of: "callbackContext.userdata", in: text, range: body).count == 1,
                "P-D: \(file) must pass the context userdata to the write callback"
            )
            #expect(
                Self.occurrences(of: Self.contextRoute, in: text, range: body).count == 1,
                "P-D: \(file) must resolve the write callback userdata through the context"
            )
            #expect(
                Self.occurrences(of: "Unmanaged.passUnretained(self).toOpaque()", in: text, range: body).count == 0,
                "P-D: \(file) must not pass the view address as write-callback userdata"
            )
            #expect(
                Self.occurrences(of: "Unmanaged<GhosttyTerminalView>", in: text, range: body).count == 0,
                "P-D: \(file) must not cast the write-callback userdata to the view"
            )
        }
    }

    // MARK: - P-E: resolve-before-complete ordering in confirmReadClipboard

    /// The ordering the #327 dead-surface routing test cannot observe with
    /// `state: nil`: every `complete(surface:` call site in
    /// `confirmReadClipboard` must be preceded by its own `fromOpaque` resolve
    /// guard. The k-th completion site needs at least k preceding routes, so
    /// deleting either the deny-branch resolve or the paste-branch resolve reds
    /// this pin (the callback may only be completed on a resolved live
    /// surface handle).
    @Test
    func testPEConfirmReadClipboardResolvesBeforeEveryCompletion() throws {
        let appText = Self.strippingComments(try source(Self.appSource))
        let confirmAnchor = try #require(
            Self.occurrences(of: "func confirmReadClipboard(", in: appText).first,
            "P-E: Ghostty.App.swift must keep confirmReadClipboard"
        )
        let confirmBody = try Self.bracedBlock(after: confirmAnchor, in: appText)

        let routes = Self.flexibleOccurrences(
            of: "Ghostty.SurfaceCallbackContext .fromOpaque(",
            in: appText,
            range: confirmBody
        )
        #expect(
            routes.count == 2,
            "P-E: confirmReadClipboard must resolve through the context in both branches; found \(routes.count)"
        )
        let completionSites = Self.flexibleOccurrences(
            of: "complete( surface:",
            in: appText,
            range: confirmBody
        )
        #expect(
            completionSites.count == 2,
            "P-E: confirmReadClipboard must route its two completions through complete(surface:); found \(completionSites.count)"
        )
        for (index, site) in completionSites.enumerated() {
            let precedingRoutes = routes.filter { $0.lowerBound < site.lowerBound }.count
            #expect(
                precedingRoutes > index,
                "P-E: completion site \(index + 1) in confirmReadClipboard must be preceded by its own fromOpaque resolve guard; found \(precedingRoutes) preceding route(s)"
            )
        }
    }

    // MARK: - P-F: prompt title and default-button parity

    /// #327 tripwire: the prompt title lives in one shared constant and each
    /// platform presenter designates the paste action as the default button.
    /// This freezes the parity contract the unit seam cannot observe (the
    /// presenters are never instantiated in tests).
    @Test
    func testPFPlatformPresentersShareTheTitleAndDefaultButton() throws {
        let iOS = Self.strippingComments(try source(Self.iOSClipboardConfirmationSource))
        let macOS = Self.strippingComments(try source(Self.macOSClipboardConfirmationSource))

        #expect(
            Self.occurrences(of: "title: ClipboardConfirmationRequest.promptTitle", in: iOS).count == 1,
            "P-F: the iOS presenter must take its alert title from the shared constant"
        )
        #expect(
            Self.occurrences(of: "alert.messageText = ClipboardConfirmationRequest.promptTitle", in: macOS).count == 1,
            "P-F: the macOS presenter must take its alert title from the shared constant"
        )
        for (name, text) in [("iOS", iOS), ("macOS", macOS)] {
            #expect(
                Self.occurrences(of: "\"Paste Unsafe Text?\"", in: text).isEmpty,
                "P-F: the \(name) presenter must not inline the prompt title"
            )
        }

        // Both platforms designate the paste action as the default button:
        // iOS via `preferredAction`, macOS via the Return key equivalent on
        // the first-added button.
        #expect(
            Self.occurrences(of: "preferredAction = pasteAction", in: iOS).count == 1,
            "P-F: the iOS paste action must be the alert's preferred (default) action"
        )
        #expect(
            Self.occurrences(of: "pasteButton.keyEquivalent = \"\\r\"", in: macOS).count == 1,
            "P-F: the macOS paste button must carry the Return key equivalent"
        )
        #expect(
            Self.occurrences(of: "cancelButton.keyEquivalent = \"\\u{1B}\"", in: macOS).count == 1,
            "P-F: the macOS cancel button must keep the Escape key equivalent"
        )
    }

    // MARK: - P-G: the completion gate compares the captured handle

    /// #327 hardening: the completion `Task` in `confirmReadClipboard` must end
    /// with the handle-comparison gate — one `context.resolve()` binding
    /// `liveView`, the captured handle compared with
    /// `liveView.surface?.unsafeCValue == surface`, and the guard's `else`
    /// drop path as the last thing before the completion. The behavioural
    /// seam-death test cannot discriminate this half: `cleanup()` invalidates
    /// the context first, so a mutation that keeps the resolve but deletes the
    /// comparison stays green there.
    @Test
    func testPGClipboardCompletionGateComparesTheCapturedHandle() throws {
        let appText = Self.strippingComments(try source(Self.appSource))
        let confirmAnchor = try #require(
            Self.occurrences(of: "func confirmReadClipboard(", in: appText).first,
            "P-G: Ghostty.App.swift must keep confirmReadClipboard"
        )
        let confirmBody = try Self.bracedBlock(after: confirmAnchor, in: appText)
        let taskAnchor = try #require(
            Self.occurrences(of: "Task ", in: appText, range: confirmBody).first,
            "P-G: the confirmation callback must dispatch its completion through a Task"
        )
        let taskBody = try Self.bracedBlock(after: taskAnchor, in: appText)

        let resolves = Self.occurrences(of: "context.resolve()", in: appText, range: taskBody)
        #expect(
            resolves.count == 1,
            "P-G: the completion Task must resolve the captured context exactly once; found \(resolves.count)"
        )
        let comparisons = Self.occurrences(
            of: "liveView.surface?.unsafeCValue == surface",
            in: appText,
            range: taskBody
        )
        #expect(
            comparisons.count == 1,
            "P-G: the completion gate must compare the captured surface handle exactly once, not merely resolve the view; found \(comparisons.count)"
        )
        let completions = Self.occurrences(of: "complete(", in: appText, range: taskBody)
        #expect(
            completions.count == 1,
            "P-G: the completion Task must complete the request exactly once; found \(completions.count)"
        )
        guard let resolve = resolves.first, let comparison = comparisons.first, let completion = completions.first else {
            return
        }
        #expect(
            resolve.lowerBound < comparison.lowerBound,
            "P-G: the resolve must bind the view the handle comparison reads"
        )
        #expect(
            comparison.lowerBound < completion.lowerBound,
            "P-G: the handle comparison must precede the completion"
        )

        // "Immediately before": the only code between the comparison and the
        // completion is the guard's `else` drop path (its log line and its
        // `return`), so a gate moved earlier — or reduced to a bare resolve —
        // cannot satisfy this pin.
        let between = String(appText[comparison.upperBound..<completion.lowerBound])
        #expect(
            Self.occurrences(of: "else {", in: between).count == 1,
            "P-G: the handle comparison must own a guard else-branch before the completion"
        )
        #expect(
            Self.occurrences(
                of: "clipboard confirmation completion skipped: surface no longer live",
                in: between
            ).count == 1,
            "P-G: the gate's drop path must sit between the comparison and the completion"
        )
        #expect(
            Self.occurrences(of: "context.resolve()", in: between).isEmpty,
            "P-G: no further resolve may sit between the handle comparison and the completion"
        )
    }

    // MARK: - P-H: the #329 teardown drain and its registry

    /// #329 ordering on both free paths: `callbackContext.invalidate()` <
    /// drain < `ghostty_surface_free`, and the deferred `deinit` drain sits
    /// inside the `withExtendedLifetime(context)` block. P-C already pins
    /// invalidate < free; this pin adds the drain that releases the in-flight
    /// clipboard request while the surface handle is still valid.
    @Test
    func testPHSurfaceDrainsPendingClipboardRequestsBeforeEveryFree() throws {
        let text = Self.strippingComments(try source(Self.surfaceSource))

        let freeAnchor = try #require(
            Self.occurrences(of: "func free()", in: text).first,
            "P-H: Surface must keep its synchronous free()"
        )
        let freeBody = try Self.bracedBlock(after: freeAnchor, in: text)
        let freeInvalidate = try #require(
            text.range(of: "callbackContext.invalidate()", range: freeBody),
            "P-H: free() must invalidate the context"
        )
        let freeDrain = try #require(
            text.range(of: "drainPendingClipboardRequests(", range: freeBody),
            "P-H: free() must drain the pending clipboard requests"
        )
        let freeCall = try #require(
            text.range(of: "ghostty_surface_free(", range: freeBody),
            "P-H: free() must call ghostty_surface_free"
        )
        #expect(
            freeInvalidate.lowerBound < freeDrain.lowerBound,
            "P-H: free() must invalidate before the teardown drain"
        )
        #expect(
            freeDrain.lowerBound < freeCall.lowerBound,
            "P-H: free()'s drain must run before ghostty_surface_free (the C completion needs the live surface handle)"
        )

        let deinitAnchor = try #require(
            Self.occurrences(of: "deinit", in: text).first,
            "P-H: Surface must keep its deinit"
        )
        let deinitBody = try Self.bracedBlock(after: deinitAnchor, in: text)
        let deinitInvalidate = try #require(
            text.range(of: "callbackContext.invalidate()", range: deinitBody),
            "P-H: deinit must invalidate the context"
        )
        let asyncAnchor = try #require(
            text.range(of: "DispatchQueue.main.async", range: deinitBody),
            "P-H: deinit must defer the free to the main queue"
        )
        let asyncBody = try Self.bracedBlock(after: asyncAnchor, in: text)
        let retainAnchor = try #require(
            text.range(of: "withExtendedLifetime(context)", range: asyncBody),
            "P-H: the deferred free block must retain the captured context"
        )
        let retainBody = try Self.bracedBlock(after: retainAnchor, in: text)
        let deinitDrain = try #require(
            text.range(of: "drainPendingClipboardRequests(", range: retainBody),
            "P-H: the deferred block must drain inside withExtendedLifetime(context)"
        )
        let deinitFree = try #require(
            text.range(of: "ghostty_surface_free(", range: retainBody),
            "P-H: the deferred block must call ghostty_surface_free inside withExtendedLifetime(context)"
        )
        #expect(
            deinitInvalidate.lowerBound < deinitDrain.lowerBound,
            "P-H: deinit must invalidate before the deferred drain"
        )
        #expect(
            deinitDrain.lowerBound < deinitFree.lowerBound,
            "P-H: the deferred drain must run before ghostty_surface_free"
        )
    }

    /// #329 claim discipline in `complete`: the nil-state guard precedes the
    /// claim, the claim's guard `else`/`return` sits between the claim and the
    /// C completion, the claim result is consumed (a `_ =` discard would let
    /// the double completion the claim exists to prevent), and the `context`
    /// parameter is non-optional (a `nil` context would bypass the claim).
    @Test
    func testPHCompletionClaimsBeforeTheCCompletion() throws {
        let appText = Self.strippingComments(try source(Self.appSource))
        let completeAnchor = try #require(
            Self.occurrences(of: "func complete(", in: appText).first,
            "P-H: Ghostty.App.swift must keep complete("
        )
        let completeBody = try Self.bracedBlock(after: completeAnchor, in: appText)

        let nilStateGuard = try #require(
            appText.range(of: "guard let state else", range: completeBody),
            "P-H: complete must keep its nil-state guard"
        )
        let claim = try #require(
            appText.range(of: "claimPendingClipboardRequest(", range: completeBody),
            "P-H: complete must claim the registered request"
        )
        let cCall = try #require(
            appText.range(of: "ghostty_surface_complete_clipboard_request(", range: completeBody),
            "P-H: complete must call the C completion"
        )

        #expect(
            nilStateGuard.lowerBound < claim.lowerBound,
            "P-H: the nil-state guard must precede the claim (never claim a nil state)"
        )
        #expect(
            claim.lowerBound < cCall.lowerBound,
            "P-H: the claim must precede the C completion"
        )

        let between = String(appText[claim.upperBound..<cCall.lowerBound])
        #expect(
            Self.occurrences(of: "else {", in: between).count == 1,
            "P-H: the claim must own a guard else-branch before the C completion"
        )
        #expect(
            Self.occurrences(of: "return", in: between).count >= 1,
            "P-H: a failed claim must return, never fall through to the C completion"
        )
        #expect(
            Self.occurrences(of: "_ =", in: appText, range: completeBody).isEmpty,
            "P-H: the claim result must be consumed by its guard, never discarded with `_ =`"
        )

        // The context parameter must stay non-optional: a `nil` context would
        // compile at a future call site and silently bypass the claim.
        let signatureEnd = try #require(
            appText[completeAnchor.upperBound...].firstIndex(of: "{"),
            "P-H: complete's declaration must open a body"
        )
        let signature = String(appText[completeAnchor.upperBound..<signatureEnd])
        #expect(
            Self.occurrences(of: "context: Ghostty.SurfaceCallbackContext", in: signature).count == 1,
            "P-H: complete must declare its context parameter"
        )
        #expect(
            Self.occurrences(of: "context: Ghostty.SurfaceCallbackContext?", in: signature).isEmpty,
            "P-H: complete's context parameter must be non-optional — a nil context would bypass the exactly-once claim"
        )
    }

    /// #329 registration per branch: the deny branch resolves its own context
    /// before it registers and completes; the prompt branch resolves, copies
    /// the payload, registers, then schedules the `Task`. P-E pins
    /// resolve-before-complete; this pin adds resolve-before-register, so a
    /// dead callback frame can never register a request that no surface free
    /// can drain.
    @Test
    func testPHClipboardRegistrationSitsAfterEachResolveGuard() throws {
        let appText = Self.strippingComments(try source(Self.appSource))
        let confirmAnchor = try #require(
            Self.occurrences(of: "func confirmReadClipboard(", in: appText).first,
            "P-H: Ghostty.App.swift must keep confirmReadClipboard"
        )
        let confirmBody = try Self.bracedBlock(after: confirmAnchor, in: appText)

        let routes = Self.flexibleOccurrences(
            of: "Ghostty.SurfaceCallbackContext .fromOpaque(",
            in: appText,
            range: confirmBody
        )
        #expect(
            routes.count == 2,
            "P-H: both confirm branches must resolve through the context; found \(routes.count)"
        )
        let registrations = Self.occurrences(
            of: "registerPendingClipboardRequest(",
            in: appText,
            range: confirmBody
        )
        #expect(
            registrations.count == 2,
            "P-H: both confirm branches must register their request; found \(registrations.count)"
        )
        let completions = Self.flexibleOccurrences(
            of: "complete( surface:",
            in: appText,
            range: confirmBody
        )
        #expect(
            completions.count == 2,
            "P-H: confirmReadClipboard must keep its two completion sites; found \(completions.count)"
        )
        let payloadCopy = try #require(
            Self.occurrences(of: "let payload = string.map", in: appText, range: confirmBody).first,
            "P-H: the prompt branch must copy the payload"
        )
        let taskAnchor = try #require(
            Self.occurrences(of: "Task ", in: appText, range: confirmBody).first,
            "P-H: the confirmation callback must dispatch its completion through a Task"
        )

        guard routes.count == 2, registrations.count == 2, completions.count == 2 else { return }

        // Deny branch: resolve → register → complete.
        #expect(
            routes[0].lowerBound < registrations[0].lowerBound,
            "P-H: the deny branch must resolve before it registers"
        )
        #expect(
            registrations[0].lowerBound < completions[0].lowerBound,
            "P-H: the deny branch must register before it completes"
        )

        // Prompt branch: resolve → copy → register → Task.
        #expect(
            routes[1].lowerBound < payloadCopy.lowerBound,
            "P-H: the prompt branch must resolve before it copies the payload"
        )
        #expect(
            payloadCopy.lowerBound < registrations[1].lowerBound,
            "P-H: the prompt branch must copy the payload before it registers"
        )
        #expect(
            registrations[1].lowerBound < taskAnchor.lowerBound,
            "P-H: the prompt branch must register before it schedules the Task"
        )
    }

    /// #329 registry invariants: `invalidate()` must not clear the registry
    /// (the deferred drain still owes each entry's release), the drain must not
    /// consult `isValid`, no C completion may sit inside a `withLock` body
    /// (tripwire, not a guarantee: a direct-call scan of the two files, not a
    /// loop-scoped proof — a C call behind a helper invoked in a lock body
    /// escapes it), and the drain's deny literal must stay
    /// `("", pending.state, true)` (also a file-scoped presence check: it does
    /// not prove the literal sits in the drain helper's body).
    @Test
    func testPHRegistryInvariants() throws {
        let contextText = Self.strippingComments(try source(Self.contextSource))
        let surfaceText = Self.strippingComments(try source(Self.surfaceSource))

        let invalidateAnchor = try #require(
            Self.occurrences(of: "func invalidate()", in: contextText).first,
            "P-H: SurfaceCallbackContext must keep invalidate()"
        )
        let invalidateBody = try Self.bracedBlock(after: invalidateAnchor, in: contextText)
        #expect(
            Self.occurrences(of: "pendingClipboardRequests", in: contextText, range: invalidateBody).isEmpty,
            "P-H: invalidate() must not clear the registry"
        )

        let drainAnchor = try #require(
            Self.occurrences(of: "func drainPendingClipboardRequests()", in: contextText).first,
            "P-H: SurfaceCallbackContext must keep drainPendingClipboardRequests()"
        )
        let drainBody = try Self.bracedBlock(after: drainAnchor, in: contextText)
        #expect(
            Self.occurrences(of: "isValid", in: contextText, range: drainBody).isEmpty,
            "P-H: the drain must ignore isValid (the deinit path invalidates before it drains)"
        )

        for (file, text) in [(Self.contextSource, contextText), (Self.surfaceSource, surfaceText)] {
            for lockAnchor in Self.occurrences(of: "withLock", in: text) {
                guard let lockBody = try? Self.bracedBlock(after: lockAnchor, in: text) else { continue }
                #expect(
                    Self.occurrences(
                        of: "ghostty_surface_complete_clipboard_request(",
                        in: text,
                        range: lockBody
                    ).isEmpty,
                    "P-H: no C completion may sit inside a withLock body in \(file)"
                )
            }
        }

        #expect(
            Self.occurrences(
                of: "ghostty_surface_complete_clipboard_request(surface, \"\", pending.state, true)",
                in: surfaceText
            ).count == 1,
            "P-H: the drain must release each entry with the deny literal (\"\", pending.state, true)"
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

    /// Every occurrence of `needle` in `text`, where `needle` is split on
    /// single spaces and each piece may be separated by any amount of
    /// whitespace (including a newline) or by none at all. This matches the
    /// pinned call expression whether the source keeps it on one line or wraps
    /// it across lines.
    private static func flexibleOccurrences(
        of needle: String,
        in text: String,
        range searchRange: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        let tokens = needle.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return [] }
        let bounds = searchRange ?? text.startIndex..<text.endIndex
        var result: [Range<String.Index>] = []
        var searchStart = bounds.lowerBound
        while let candidate = text.range(of: first, range: searchStart..<bounds.upperBound) {
            if let end = flexibleMatchEnd(tokens: tokens, in: text, after: candidate, limit: bounds.upperBound) {
                result.append(candidate.lowerBound..<end)
                searchStart = end
            } else {
                searchStart = text.index(after: candidate.lowerBound)
            }
        }
        return result
    }

    /// The end index of a match whose first token is `firstMatch`, or nil when
    /// the remaining tokens do not line up in order.
    private static func flexibleMatchEnd(
        tokens: [String],
        in text: String,
        after firstMatch: Range<String.Index>,
        limit: String.Index
    ) -> String.Index? {
        var upper = firstMatch.upperBound
        for token in tokens.dropFirst() {
            var cursor = upper
            while cursor < limit, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard let tokenRange = text.range(of: token, range: cursor..<limit),
                  tokenRange.lowerBound == cursor else { return nil }
            upper = tokenRange.upperBound
        }
        return upper
    }
}
