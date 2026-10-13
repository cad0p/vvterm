// SPDX-License-Identifier: MIT
//
//  WorkflowPrepareXcodeBuildPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #109's DerivedData cache-provenance diagnostic in
//  `.github/actions/prepare-xcode-build/action.yml`. This is the first pin in
//  the repo that reads a composite action rather than a workflow (every other
//  pin reads `.github/workflows/*.yml` or `scripts/ci/*.sh`).
//
//  The measured defect: the OTA `ota-archive` arm restores its own previous
//  Release/device DerivedData entry and still recompiles the full set. Three
//  same-image restore chains of the immediate predecessor's entry (images
//  `20261006.0244.1`, `20261006.0244.1`, and `20260928.0222.1`) all compiled
//  183 `CompileC` / 96 `SwiftCompile` / 44 `PrecompileModule` (archives 645 /
//  567 / 681 s), while the Debug/simulator `build` arm restoring the same way
//  is warm (0 `CompileC`, jobs 113479048536 / 113567365173). The diagnostic
//  this PR lands makes every run self-describing: the runner image, the
//  cache-restore key, the cache's self-reported provenance (a marker written
//  into the cached DerivedData by the previous run), the `*.sdkstatcache`
//  positive control, and the restored `.o` count — the one datum that splits
//  "the cache carried no objects" from "the objects were invalidated".
//
//  Pinned properties (plan v3 §3.5):
//    A1 (order): exactly one source-mtime restore step, irgaly cache step,
//       provenance/restore-completeness step, marker-write step, PCM-clear
//       step and Metal step, in that order, each resolving to a *distinct*
//       step: merging the read step and the write step fails closed (a
//       write executed before the read would make a cold cache log `same`).
//       Mutation reds: deleting the provenance step, moving it before the
//       cache step, merging the marker write into the provenance step.
//    A2 (paths): the provenance step reads and the marker-write step writes
//       the same `$RUNNER_TEMP/DerivedData/.vvterm-cache-provenance` path.
//    A3 (inputs): the OTA workflow's `prepare-xcode-build` step still passes
//       `xcode27-ota-deriveddata` / `xcode27-ota-deriveddata-` (the Debug
//       prefix never matches the OTA entry).
//    A4 (flags): the OTA archive invocation keeps its four measured flags,
//       each exactly once (xcodebuild option parsing is last-wins).
//    A5 (miss-safe write): the stale-marker `rm -f`, the guarded `mkdir -p`
//       (`2>/dev/null || true`) and the guarded redirect
//       (`2>/dev/null || echo "marker write skipped"`).
//    A6 (miss-safe probes): the `.o` probe guarded by the `Build/` directory
//       test with a cold `absent` branch, the full `.o` count payload
//       (`find … -type f -name '*.o' | wc -l`), the `find | head -1`
//       pipeline carrying the measured `|| true` SIGPIPE guard, the
//       sdkstatcache `stat` guarded (`compgen -G` + `2>/dev/null || true`),
//       and the remaining guard idioms (`sw_vers`, `imagedata.json` `cat`,
//       `xcodebuild -version -sdk iphoneos`, the marker `head -1`, the
//       `[[ -f "$marker" ]]` condition).
//    A7 (id + datum): the irgaly step keeps `id: xcode-cache` and the
//       provenance step echoes `steps.xcode-cache.outputs.restored-key`
//       (without the id the echo silently degrades to an empty key).
//    A8 (verdict): the `same` verdict requires both marker components to be
//       non-empty **and** equal — an empty saved component must not read as
//       `same`.
//    A9 (OBJROOT): the OTA archive step sets
//       `OBJROOT="$RUNNER_TEMP/DerivedData/Build/OTAIntermediates"` exactly
//       once and keeps `-derivedDataPath "$RUNNER_TEMP/DerivedData"` — the
//       #422 fix for the measured ArchiveIntermediates wipe (without it a
//       same-image restore recompiles the full set).
//    A10 (SPM coherence): the cache step's SPM configuration is all-or-none
//       coherent — the explicit `sourcepackages-directory`, the full
//       `swiftpm-cache-key` `Package.resolved` expression and the
//       `swiftpm-cache-restore-keys` `xcode27-spm-` value are either all
//       present-and-exact at the `with:`-child indent (the wired arm) or all
//       absent (the deleted arm), never the pre-#418 mixed state (key +
//       restore-keys present, directory absent — the SPM half was inert
//       while the DerivedData tar carried the checkouts). The container
//       check requires the input lines at the 8-space `with:` child indent
//       (the block-scalar value at 10), so relocating one to the step-field
//       indent or `env:` reds. The `sourcepackages-directory` value is bound
//       relationally to `deriveddata-directory` + `/SourcePackages`, and
//       both SPM keys are duplicate-guarded (YAML is last-wins). If
//       upstream's glob default ever starts matching this layout, re-derive
//       this pin deliberately (the one-line removal this test forbids is
//       then a legitimate clean delete of all three) — never delete one
//       line to make a red go away. Mutation reds: base mixed state, removed
//       line, wrong path, renamed key, dropped `hashFiles`/`Package.resolved`
//       term, restore-key suffix `xcode27-spm-debug-`, duplicate key,
//       `deriveddata-directory` drift, `with:`-child misindent, duplicate
//       `deriveddata-directory:`, duplicate block-scalar value line.
//       (issue #418)
//    A11 (products): the OTA archive keeps its Swift-product materialization
//       inside the cached DerivedData root — `CONFIGURATION_BUILD_DIR` to
//       `Build/OTAProducts/Release-iphoneos` and `DWARF_DSYM_FOLDER_PATH`
//       back to the default products path (the archive stages the
//       `.xcarchive` dSYMs only from there). Each exact token and each bare
//       assignment is bound exactly once (build settings are last-wins),
//       `-derivedDataPath "$RUNNER_TEMP/DerivedData"` is kept and bound by
//       count, and no `SYMROOT=`/`BUILD_DIR=` assignment is allowed —
//       asserted at a token boundary, because `CONFIGURATION_BUILD_DIR=`
//       contains `BUILD_DIR=` and a trimmed line-prefix check would miss
//       `export BUILD_DIR=…`/mid-line spellings, and the `env:` key
//       spelling (`SYMROOT:`/`BUILD_DIR:`) is rejected at the step and at
//       every workflow indent, because xcodebuild reads build settings from
//       the environment. A11 deliberately
//       re-asserts A9's `OBJROOT` token and kept `-derivedDataPath` line:
//       the #427 relocation is only valid on top of the #422 one.
//       (issue #427)
//
//  The `find | head -1 | while … done || true` guard is a measured deviation
//  from the plan's verbatim probe block: under the runner's composite bash
//  (`-e -o pipefail`), the verbatim block exits 141 on a warm `Build/` tree
//  because `head -1` closes the pipe and `find` takes SIGPIPE (measured
//  2026-10-08 locally: verbatim rc=141, guarded rc=0 on the same tree, 5/5
//  repeats; cold rc=0). A required `build` job must not be reddable by its
//  own diagnostic, so the guard is pinned here and recorded in the walk note.
//
//  Scanner: a small `runs:`/`steps:` text scanner. It fails closed unless the
//  composite has exactly one top-level `runs:` key, exactly one `steps:` key
//  under it, exactly one step per content signature, and no non-list content
//  at the step indent; the OTA scanner fails closed unless the workflow has
//  exactly one `  ota-archive:` job key. Content signatures (not step names)
//  identify the steps, so a benign rename/reformat of a step stays green.
//
//  FORMATTING HEURISTIC, NOT A PROOF: these pins parse YAML as text. A real
//  YAML parse would be sounder, but a YAML toolchain (`yq`/`jq`) is not
//  guaranteed on the `xcode-27` runner and a required job must not take a
//  network dependency for a lint. Comments are stripped YAML-style before
//  every scan (and cut again per line), so a commented-out diagnostic line
//  cannot satisfy an assertion.
//
//  Defeat list, stated honestly:
//  - This is a text-consistency lock. A coherent edit of the diagnostic *and*
//    this pin passes; a runtime regression that keeps the pinned spellings
//    (e.g. the marker written with a stale value, the probe counting the
//    wrong objects) is invisible here. The runtime acceptance is the PR's OTA
//    run `cache-provenance:` / `restored-object-count:` / `xcode-cache-restored-key:`
//    lines plus the recorded cold-path execution of the two step bodies
//    (`assets/vvterm-issue109-evidence/`), not this pin.
//  - It cannot execute the shell: it cannot prove `compgen`, `${saved%%|*}`
//    or `find -type f -name '*.o'` behave at runtime; the cold-path transcript
//    is the manual runtime oracle for the fail-safe branches.
//  - It parses `${{ … }}` expressions as literal text and cannot prove GitHub
//    resolves `steps.xcode-cache.outputs.restored-key` to a non-empty value.
//  - A2 binds the two literal paths but not that no *other* path is also
//    written; A8 binds the `same` condition line but not the surrounding
//    branch structure.
//  - Presence-only assertions (locked but not mutation-proven by the
//    battery): the `.o` cold-branch `absent` echo, the A8 verdict log
//    shapes, the A7 restored-key echo, and three of the four A4 flags
//    (only `CODE_SIGNING_ALLOWED=NO` is mutated; the four share one count
//    loop, so the red path is implied but not separately recorded).
//  - The OTA flags are bound by count within the archive step, not by the
//    xcodebuild option semantics; a flag moved into another step would red.
//  - A9 binds the exact OBJROOT token and the kept `-derivedDataPath` line,
//    but cannot prove xcodebuild honors OBJROOT at runtime; the E1
//    same-image OTA sample is that runtime oracle.
//  - A11 binds the exact product/dSYM tokens, the count-bound
//    `-derivedDataPath`, and the token-boundary `SYMROOT=`/`BUILD_DIR=`
//    absence, but cannot prove xcodebuild honors
//    `CONFIGURATION_BUILD_DIR`/`DWARF_DSYM_FOLDER_PATH` at runtime; the E1
//    same-image OTA sample plus the sampled artifact's `dSYMs/` and
//    `PlugIns/*.appex` listing are that runtime oracle. A11's `OBJROOT` /
//    `-derivedDataPath` assertions deliberately overlap A9: the #427
//    relocation is only valid on top of the #422 relocation, and A11 states
//    the full invocation contract in one place. A build setting routed
//    through a shell variable (`S="BUILD_DIR=…"; xcodebuild … $S`) or through
//    an indirection the scanner cannot read (a `*.xcconfig`, a Reusable
//    Workflow input) remains invisible — the general scanner-heuristic defeat
//    below. The direct `env:` spellings are covered. (impl lens 2 F4)
//  - The scanner is a text heuristic: an indented or flow-style `runs:` /
//    `steps:` spelling, a quoted `ota-archive` key, or content at the step
//    indent that is not a list item throws `PinFailure` rather than scanning
//    the wrong region.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scans at a
//  mutated tree. On the iOS Simulator destination a plain environment variable
//  is inert; the measured-working form is
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<tree>` exported into xcodebuild's own
//  environment. The mutated tree needs only the two files this suite reads.
//  Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct WorkflowPrepareXcodeBuildPinsTests {

    private static let actionPath = ".github/actions/prepare-xcode-build/action.yml"
    private static let otaWorkflowPath = ".github/workflows/vvterm-pr-ota.yml"

    // MARK: - Tests

    /// A1: the diagnostic lands between the cache restore and the PCM clear,
    /// each stage exists exactly once as a distinct step, in the pinned order.
    @Test
    func testCompositeStepOrderIsPinned() throws {
        let steps = try Self.compositeSteps()

        let stages: [(String, Int)] = [
            ("source-mtime restore", try Self.stepIndex(containing: "git-restore-mtime-action", in: steps, label: "source-mtime restore")),
            ("DerivedData cache", try Self.stepIndex(containing: "irgaly/xcode-cache", in: steps, label: "DerivedData cache")),
            ("provenance/restore-completeness probe", try Self.stepIndex(containing: "restored-object-count:", in: steps, label: "provenance/restore-completeness probe")),
            ("provenance marker write", try Self.stepIndex(containing: "printf '%s|%s\\n'", in: steps, label: "provenance marker write")),
            ("PCM cache clear", try Self.stepIndex(containing: "ModuleCache.noindex", in: steps, label: "PCM cache clear")),
            ("Metal toolchain", try Self.stepIndex(containing: "xcodebuild -downloadComponent MetalToolchain", in: steps, label: "Metal toolchain")),
        ]
        let order = stages.map(\.1)
        let found = stages.sorted { $0.1 < $1.1 }.map(\.0).joined(separator: " -> ")
        #expect(
            order == order.sorted(),
            """
            the composite step order must be source-mtime restore -> irgaly cache -> \
            provenance/probe -> marker write -> PCM clear -> Metal toolchain (issue #109); \
            found \(found)
            """
        )
        #expect(
            Set(order).count == order.count,
            """
            the six pipeline stages must resolve to six distinct steps (found \(found)); \
            merging the provenance/read step with the marker-write step fails closed: a \
            write executed before the read would make a cold cache log `same` (issue #109)
            """
        )
    }

    /// A2: the marker is the one path both the read and the write use.
    @Test
    func testProvenanceMarkerReadAndWriteShareTheSamePath() throws {
        let steps = try Self.compositeSteps()
        let provenance = steps[try Self.stepIndex(containing: "restored-object-count:", in: steps, label: "provenance/restore-completeness probe")]
        let markerWrite = steps[try Self.stepIndex(containing: "printf '%s|%s\\n'", in: steps, label: "provenance marker write")]

        #expect(
            provenance.text.contains(#"marker="$RUNNER_TEMP/DerivedData/.vvterm-cache-provenance""#),
            "the provenance step must read `$RUNNER_TEMP/DerivedData/.vvterm-cache-provenance` (the marker the previous run writes); a changed path would make every run report `unknown` (issue #109)"
        )
        #expect(
            markerWrite.text.contains(#"> "$RUNNER_TEMP/DerivedData/.vvterm-cache-provenance""#),
            "the marker-write step must write the same `$RUNNER_TEMP/DerivedData/.vvterm-cache-provenance` path the provenance step reads (issue #109)"
        )
    }

    /// A3: the OTA prepare step restores from the OTA prefix only.
    @Test
    func testOTAWorkflowPassesTheOTAPrepareInputs() throws {
        let steps = try Self.otaSteps()
        let prepare = steps[try Self.stepIndex(containing: "uses: ./.github/actions/prepare-xcode-build", in: steps, label: "OTA prepare-xcode-build step")]

        #expect(
            Self.hasLine(prepare, equalTo: "deriveddata-key-prefix: xcode27-ota-deriveddata"),
            "the ota-archive prepare step must pass exactly `deriveddata-key-prefix: xcode27-ota-deriveddata`; a suffix such as `-ct` silently widens the prefix and restores the Debug/simulator entries (issue #109)"
        )
        #expect(
            Self.hasLine(prepare, equalTo: "deriveddata-restore-keys: xcode27-ota-deriveddata-"),
            "the ota-archive prepare step must pass exactly `deriveddata-restore-keys: xcode27-ota-deriveddata-`; a suffix such as `-ct-` never matches the OTA entries and the arm stays cold forever (issue #109)"
        )
    }

    /// A4: the unsigned-archive invocation keeps the four measured flags,
    /// each exactly once. `xcodebuild` option parsing is last-wins, so a
    /// duplicated flag would silently override the pin.
    @Test
    func testOTAArchiveInvocationKeepsThePinnedFlags() throws {
        let steps = try Self.otaSteps()
        let archive = steps[try Self.stepIndex(containing: "xcodebuild archive", in: steps, label: "OTA archive step")]
        let flags = [
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            #"generic/platform=iOS"#,
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS=FORCE_PRO_ENABLED",
        ]
        for flag in flags {
            let count = archive.text.components(separatedBy: flag).count - 1
            #expect(
                count == 1,
                "the OTA archive step must contain `\(flag)` exactly once (found \(count)); a duplicated xcodebuild flag is last-wins and would silently override this pin (issue #109)"
            )
        }
    }

    /// A9: the OTA archive relocates its `OBJROOT` inside the cached
    /// DerivedData root. `xcodebuild archive` deletes and recreates
    /// `ArchiveIntermediates/VVTerm/IntermediateBuildFilesPath` (the
    /// archive's objects + build-description/task store) on every
    /// invocation, so the restored archive intermediates are wiped before
    /// the build reads them (measured, issue #422). The pin binds the exact
    /// build-setting token so the fix cannot be silently removed, widened
    /// to a path outside the cached root, or duplicated **with any value**
    /// (xcodebuild build settings are last-wins), and binds the kept
    /// `-derivedDataPath`.
    @Test
    func testOTAArchiveRelocatesOBJROOTInsideCachedDerivedData() throws {
        let steps = try Self.otaSteps()
        let archive = steps[try Self.stepIndex(containing: "xcodebuild archive", in: steps, label: "OTA archive step")]
        let objroot = #"OBJROOT="$RUNNER_TEMP/DerivedData/Build/OTAIntermediates""#
        let count = archive.text.components(separatedBy: objroot).count - 1
        #expect(
            count == 1,
            """
            the OTA archive step must set `\(objroot)` exactly once (found \(count)); \
            without it `xcodebuild archive` recreates ArchiveIntermediates/VVTerm/\
            IntermediateBuildFilesPath and the restored objects are wiped before the \
            build reads them (issue #422)
            """
        )
        // Any second `OBJROOT=` assignment — whatever its value — shadows the
        // pinned one (xcodebuild build settings are last-wins), so a bare
        // assignment count is what makes a differently-valued duplicate red.
        let assignmentCount = archive.text.components(separatedBy: "OBJROOT=").count - 1
        #expect(
            assignmentCount == 1,
            """
            the OTA archive step must carry exactly one `OBJROOT=` assignment \
            (found \(assignmentCount)); a second assignment with any value is \
            last-wins and silently unrelocates the archive scratch (issue #422)
            """
        )
        #expect(
            archive.text.contains(#"-derivedDataPath "$RUNNER_TEMP/DerivedData""#),
            """
            the OBJROOT relocation must keep `-derivedDataPath "$RUNNER_TEMP/DerivedData"`; \
            OBJROOT is relative to the cached root, not a replacement for it (issue #422)
            """
        )
    }

    /// A5/A6: every diagnostic line is guarded for the cold and warm paths.
    /// The `|| true` after the `.o` sample pipeline is pinned because the
    /// verbatim `find | head -1` form returns 141 under `-o pipefail` on a
    /// warm tree (measured deviation, see the file header).
    @Test
    func testProvenanceProbesAreFailSafeForColdAndWarmCaches() throws {
        let steps = try Self.compositeSteps()
        let provenance = steps[try Self.stepIndex(containing: "restored-object-count:", in: steps, label: "provenance/restore-completeness probe")]
        let markerWrite = steps[try Self.stepIndex(containing: "printf '%s|%s\\n'", in: steps, label: "provenance marker write")]

        #expect(
            provenance.text.contains(#"if [[ -d "$RUNNER_TEMP/DerivedData/Build" ]]; then"#),
            "the `.o` restore-completeness probe must be guarded by the `Build/` directory test so a cold cache cannot red the job (issue #109)"
        )
        let countCommand = "echo \"restored-object-count: $(find \"$RUNNER_TEMP/DerivedData/Build\" -type f -name '*.o' | wc -l | tr -d ' ')\""
        #expect(
            Self.hasLine(provenance, equalTo: countCommand),
            "the restore-completeness count must stay the full `find \"$RUNNER_TEMP/DerivedData/Build\" -type f -name '*.o' | wc -l` payload; a loosened pattern would make the datum meaningless (issue #109)"
        )
        #expect(
            provenance.text.contains(#"echo "restored-object-count: absent""#),
            "the `.o` probe must log `restored-object-count: absent` on the cold path instead of failing (issue #109)"
        )
        #expect(
            provenance.text.contains("done || true"),
            "the `.o` sample pipeline must carry the `|| true` guard: the bare `find | head -1` form exits 141 under `-e -o pipefail` on a warm tree (measured) and would red the required `build` job (issue #109)"
        )
        #expect(
            provenance.text.contains(#"if compgen -G "$sdkstat_dir/*.sdkstatcache" >/dev/null; then"#),
            "the sdkstatcache positive control must be guarded by `compgen -G` so an absent cache cannot red the job (issue #109)"
        )
        #expect(
            provenance.text.contains(#"stat -f 'sdkstatcache: %m %z %N' "$sdkstat" 2>/dev/null || true"#),
            "the sdkstatcache `stat` must be non-fatal (`2>/dev/null || true`) so a missing file cannot red the job (issue #109)"
        )
        #expect(
            Self.hasLine(markerWrite, equalTo: #"rm -f "$RUNNER_TEMP/DerivedData/.vvterm-cache-provenance" 2>/dev/null || true"#),
            "the marker write must `rm -f` the stale restored marker first; without it a failed write leaves the old marker for the irgaly post step to re-save and a later run can read it as a false `same` (issue #109)"
        )
        #expect(
            Self.hasLine(markerWrite, equalTo: #"mkdir -p "$RUNNER_TEMP/DerivedData" 2>/dev/null || true"#),
            "the marker write must `mkdir -p` the cache root guarded (`2>/dev/null || true`); the cold path has no DerivedData and an unwritable root must not red the job (measured, issue #109)"
        )
        #expect(
            markerWrite.text.contains(#"2>/dev/null || echo "marker write skipped""#),
            "the marker redirect must be guarded with `2>/dev/null || echo \"marker write skipped\"` so a failed write cannot red the job (issue #109)"
        )
        #expect(
            provenance.text.contains("now_build=\"$(sw_vers -buildVersion 2>/dev/null || true)\""),
            "the `sw_vers` image-build probe must stay guarded (`2>/dev/null || true`): a failing `sw_vers` must not red the job (issue #109)"
        )
        #expect(
            provenance.text.contains("cat \"$HOME/imagedata.json\" 2>/dev/null || echo \"imagedata.json: unreadable\""),
            "the `imagedata.json` dump must stay guarded (`2>/dev/null || echo`): an unreadable file must not red the job (issue #109)"
        )
        #expect(
            provenance.text.contains("xcodebuild -version -sdk iphoneos 2>/dev/null || echo \"xcodebuild -version -sdk iphoneos unavailable\""),
            "the `xcodebuild -version -sdk iphoneos` probe must stay guarded: a missing SDK must not red the job (issue #109)"
        )
        #expect(
            provenance.text.contains("saved=\"$(head -1 \"$marker\" 2>/dev/null || true)\""),
            "the marker read must stay guarded (`head -1 … 2>/dev/null || true`): an unreadable marker must not red the job (issue #109)"
        )
        #expect(
            provenance.text.contains("if [[ -f \"$marker\" ]]; then"),
            "the marker read must keep its `[[ -f \"$marker\" ]]` condition so a missing marker logs `unknown` instead of an empty-`cross` read (issue #109)"
        )
    }

    /// A7: the cache step is addressable and the provenance step echoes its
    /// restored key. Without `id: xcode-cache` the echo silently prints an
    /// empty key — the diagnostic degrades without any failure signal.
    @Test
    func testCacheStepIdAndRestoredKeyEchoArePinned() throws {
        let steps = try Self.compositeSteps()
        let cache = steps[try Self.stepIndex(containing: "irgaly/xcode-cache", in: steps, label: "DerivedData cache")]
        let provenance = steps[try Self.stepIndex(containing: "restored-object-count:", in: steps, label: "provenance/restore-completeness probe")]

        #expect(
            Self.hasLine(cache, equalTo: "id: xcode-cache"),
            "the irgaly cache step must keep exactly `id: xcode-cache`; without it the provenance step's `steps.xcode-cache.outputs.restored-key` echo silently prints an empty key, and a suffix (`id: xcode-cache-v2`) breaks that resolution the same way (issue #109)"
        )
        #expect(
            provenance.text.contains("${{ steps.xcode-cache.outputs.restored-key }}"),
            "the provenance step must echo the cache step's `restored-key` output so a wrong-prefix restore is visible in the log (issue #109)"
        )
    }

    /// A8: `same` requires both marker components to be non-empty and equal;
    /// an empty saved component must read as `cross` (or `unknown` without a
    /// marker), never as `same`.
    @Test
    func testProvenanceVerdictRequiresBothComponentsNonEmptyAndEqual() throws {
        let steps = try Self.compositeSteps()
        let provenance = steps[try Self.stepIndex(containing: "restored-object-count:", in: steps, label: "provenance/restore-completeness probe")]

        #expect(
            provenance.text.contains(#"if [[ -n "$saved_image" && -n "$saved_build" && "$saved_image" == "$now_image" && "$saved_build" == "$now_build" ]]; then"#),
            "the `same` verdict must require both marker components (`ImageVersion` and OS build) to be non-empty and equal; an empty saved value must not read as `same` (issue #109)"
        )
        #expect(
            provenance.text.contains(#"echo "cache-provenance: $verdict (saved-on ${saved_image:-unknown}|${saved_build:-unknown}, now ${now_image:-unknown}|${now_build:-unknown})""#),
            "the verdict log must use the pinned `cache-provenance: same|cross|unknown (saved-on <label>, now <label>)` shape — `saved-on`, never `built on` (issue #109)"
        )
        #expect(
            provenance.text.contains(#"echo "cache-provenance: unknown (saved-on unknown, now ${now_image:-unknown}|${now_build:-unknown})""#),
            "the no-marker branch must log `unknown`, not `same` (issue #109)"
        )
    }

    /// A10: the cache step's SPM configuration is all-or-none coherent —
    /// either all three SPM inputs are present and exact (the wired arm) or
    /// all are absent (the deleted arm), never the pre-#418 mixed state in
    /// which `swiftpm-cache-key` + `swiftpm-cache-restore-keys` were passed
    /// but `sourcepackages-directory` was not, leaving the SPM half inert
    /// while the DerivedData tar silently carried the checkouts (issue #418).
    /// The wired-arm lines are also container-checked at the `with:`-child
    /// indent (8 spaces; the block-scalar value at 10), so a line moved to
    /// the step-field indent or `env:` reds instead of staying green
    /// (issue #418).
    @Test
    func testCacheStepSPMInputsAreAllOrNoneCoherent() throws {
        let steps = try Self.compositeSteps()
        let cache = steps[try Self.stepIndex(containing: "irgaly/xcode-cache", in: steps, label: "DerivedData cache")]

        let directoryKey = "sourcepackages-directory:"
        let keyKey = "swiftpm-cache-key:"
        let restoreKeysKey = "swiftpm-cache-restore-keys:"
        let directoryLine = "sourcepackages-directory: ${{ runner.temp }}/DerivedData/SourcePackages"
        let keyLine = "swiftpm-cache-key: xcode27-spm-${{ hashFiles('VVTerm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved') }}"
        let restoreKeysValueLine = "xcode27-spm-"

        let directoryCount = cache.text.components(separatedBy: directoryKey).count - 1
        let keyCount = cache.text.components(separatedBy: keyKey).count - 1
        let restoreKeysCount = cache.text.components(separatedBy: restoreKeysKey).count - 1

        let allPresent = directoryCount == 1 && keyCount == 1 && restoreKeysCount == 1
        let allAbsent = directoryCount == 0 && keyCount == 0 && restoreKeysCount == 0
        #expect(
            allPresent || allAbsent,
            """
            the cache step's SPM inputs must be all present-and-exact or all absent — \
            a mixed state is the dead configuration #418 fixes (a computed SPM key with \
            no sourcepackages-directory is never restored or saved); found \
            sourcepackages-directory: \(directoryCount), swiftpm-cache-key: \(keyCount), \
            swiftpm-cache-restore-keys: \(restoreKeysCount)
            """
        )

        if allPresent {
            // Container check: the SPM inputs must sit at the 8-space
            // `with:`-child indent (the block-scalar value at 10), not
            // merely somewhere in the step block — `hasLine` trims
            // indentation, so without these a line moved to the step-field
            // indent or `env:` would stay green while no longer being an
            // action input (issue #418).
            #expect(
                Self.hasLine(cache, equalTo: directoryLine, atIndent: 8),
                "the wired arm must pass `\(directoryLine)` at the `with:`-child indent (8 spaces) — a value at another indent is no longer an action input; the action's implemented default is the `{deriveddata-directory}/*/SourcePackages` glob, which cannot match this repo's explicit -derivedDataPath layout, so a wrong, renamed or relocated value restores nothing while still counting as present (issue #418)"
            )
            #expect(
                Self.hasLine(cache, equalTo: keyLine, atIndent: 8),
                "the wired arm must keep the full `Package.resolved`-keyed `swiftpm-cache-key` expression exactly at the `with:`-child indent (8 spaces); a dropped `hashFiles(...)`/`Package.resolved` term (or a moved project path) would key the checkouts on a stale hash (issue #418)"
            )
            #expect(
                Self.hasLine(cache, equalTo: "swiftpm-cache-restore-keys: |", atIndent: 8)
                    && Self.hasLine(cache, equalTo: restoreKeysValueLine, atIndent: 10),
                "the `swiftpm-cache-restore-keys` key must sit at the `with:`-child indent (8 spaces) with its block-scalar value `\(restoreKeysValueLine)` at 10; the `|` key line is not the value, and a suffix such as `xcode27-spm-debug-` must red (issue #418)"
            )

            // The two absolute lines can drift apart in one edit and
            // re-create #418's layout mismatch, so bind them relationally.
            let derivedDataCount = cache.text.components(separatedBy: "deriveddata-directory:").count - 1
            #expect(
                derivedDataCount == 1,
                "the cache step must carry exactly one `deriveddata-directory:` input (found \(derivedDataCount)); YAML is last-wins, so a duplicate would silently unanchor the SPM path (issue #418)"
            )
            if let derivedData = Self.colonValue(of: "deriveddata-directory", in: cache),
               let sourcePackages = Self.colonValue(of: "sourcepackages-directory", in: cache) {
                #expect(
                    sourcePackages == derivedData + "/SourcePackages",
                    "`sourcepackages-directory` must equal `deriveddata-directory` + `/SourcePackages` (found `\(sourcePackages)` vs `\(derivedData)`); an independent edit of either line must red (issue #418)"
                )
            } else {
                Issue.record("could not parse `deriveddata-directory:`/`sourcepackages-directory:` from the cache step — re-derive this pin (issue #418)")
            }
        } else if allAbsent {
            // `allAbsent` above already guarantees all three counts are
            // zero; the only non-tautological delete-arm check is the stray
            // block-scalar value line left behind by a partial removal.
            #expect(
                Self.exactLineCount(cache, equalTo: restoreKeysValueLine) == 0,
                "the deleted arm must remove the `\(restoreKeysValueLine)` block-scalar value line too (issue #418)"
            )
        }
    }

    /// A11: the OTA archive keeps its Swift-product materialization inside
    /// the cached DerivedData root. The archive recreates
    /// `ArchiveIntermediates/VVTerm/BuildProductsPath` on every invocation
    /// and re-materializes the `.swiftmodule` copies importers read;
    /// `builtin-copy` re-stamps every copied destination, so each importer's
    /// recorded input signature mismatches and 32 `SwiftCompile` tasks re-run
    /// on a same-image restore (measured, issue #427).
    /// `CONFIGURATION_BUILD_DIR` moves the per-configuration products dir
    /// under the cached root so the copies land on restored,
    /// mtime-preserved files. The archive stages `.xcarchive/dSYMs` only
    /// from the DEFAULT products path, so `DWARF_DSYM_FOLDER_PATH` is pinned
    /// back to that default path (with the relocation alone the `.xcarchive`
    /// dSYMs are 0 B, measured).
    ///
    /// The pin binds each exact token once (widening it outside
    /// `$RUNNER_TEMP/DerivedData` reds), each bare assignment count
    /// (build settings are last-wins, so a differently-valued duplicate
    /// reds), the kept `-derivedDataPath`, and the line-anchored absence of
    /// `SYMROOT=` (measured rc 70) and `BUILD_DIR=` in the step. The absence
    /// check is line-anchored on purpose: `CONFIGURATION_BUILD_DIR=` contains
    /// the substring `BUILD_DIR=`, so a substring count would red the
    /// correct source (closure CR-1).
    ///
    /// A11 deliberately re-asserts A9's `OBJROOT` token and kept
    /// `-derivedDataPath` line: the #427 fix is only valid on top of the
    /// #422 relocation, and this pin is the one that states the full
    /// invocation contract.
    @Test
    func testOTAArchiveRelocatesProductsAndPinsTheDSYMPath() throws {
        let steps = try Self.otaSteps()
        let archive = steps[try Self.stepIndex(containing: "xcodebuild archive", in: steps, label: "OTA archive step")]

        let settings = [
            #"OBJROOT="$RUNNER_TEMP/DerivedData/Build/OTAIntermediates""#,
            #"CONFIGURATION_BUILD_DIR="$RUNNER_TEMP/DerivedData/Build/OTAProducts/Release-iphoneos""#,
            #"DWARF_DSYM_FOLDER_PATH="$RUNNER_TEMP/DerivedData/Build/Intermediates.noindex/ArchiveIntermediates/VVTerm/BuildProductsPath/Release-iphoneos""#,
        ]
        for setting in settings {
            let count = archive.text.components(separatedBy: setting).count - 1
            #expect(
                count == 1,
                """
                the OTA archive step must set `\(setting)` exactly once (found \(count)); \
                the product materialization must stay inside the cached \
                `$RUNNER_TEMP/DerivedData` root so a same-image restore reuses \
                the `.swiftmodule` copies instead of re-copying them \
                (issue #427)
                """
            )
        }

        // Any second assignment of the same setting — whatever its value —
        // shadows the pinned one (xcodebuild build settings are last-wins),
        // so a bare assignment count is what makes a differently-valued
        // duplicate red.
        let assignments = ["OBJROOT=", "CONFIGURATION_BUILD_DIR=", "DWARF_DSYM_FOLDER_PATH="]
        for assignment in assignments {
            let count = archive.text.components(separatedBy: assignment).count - 1
            #expect(
                count == 1,
                """
                the OTA archive step must carry exactly one `\(assignment)` \
                assignment (found \(count)); a second assignment with any value \
                is last-wins and silently overrides the pinned relocation \
                (issue #427)
                """
            )
        }

        #expect(
            archive.text.contains(#"-derivedDataPath "$RUNNER_TEMP/DerivedData""#),
            """
            the product relocation must keep `-derivedDataPath "$RUNNER_TEMP/DerivedData"`; \
            CONFIGURATION_BUILD_DIR is relative to the cached root, not a replacement \
            for it (issue #427)
            """
        )

        // Token-boundary, not substring and not trimmed-prefix: a substring
        // count would red the correct source because `CONFIGURATION_BUILD_DIR=`
        // contains `BUILD_DIR=` (closure CR-1), while a trimmed line-prefix
        // count misses `export BUILD_DIR=…` and mid-line `… BUILD_DIR=…`
        // spellings (measured by impl lens 1 F1). A token boundary is
        // start-of-line or any preceding character outside `[A-Za-z0-9_]`.
        // `SYMROOT` was measured rc 70 (the archive finalization needs the
        // default products path); `BUILD_DIR` is a viable but wider knob that
        // must not silently replace the pinned per-configuration setting.
        let forbidden = ["SYMROOT=", "BUILD_DIR="]
        for setting in forbidden {
            let count = Self.tokenOccurrenceCount(archive, token: setting)
            #expect(
                count == 0,
                """
                the OTA archive step must not assign `\(setting)` (found \(count) \
                occurrence(s)); SYMROOT was measured rc 70 (the archive finalization \
                needs the default products path) and BUILD_DIR is the wider \
                alternative to the pinned per-configuration relocation; checked at a \
                token boundary because `CONFIGURATION_BUILD_DIR=` contains \
                `BUILD_DIR=` (issue #427)
                """
            )
        }

        // The same settings spelled as YAML `env:` keys (step-, job- or
        // workflow-level) are real evasions: xcodebuild reads build settings
        // from the environment, so `env: SYMROOT: …` moves the archive
        // exactly like the command-line spelling (impl lens 2 F4). The step
        // scan sees a step-level `env:` mapping but skips job-level content,
        // so count over the whole workflow file too.
        let workflowLines = try Self.commentCutLines(of: Self.otaWorkflowPath)
        let workflowBlock = StepBlock(lines: workflowLines)
        for setting in ["SYMROOT:", "BUILD_DIR:"] {
            let stepCount = Self.tokenOccurrenceCount(archive, token: setting)
            let fileCount = Self.tokenOccurrenceCount(workflowBlock, token: setting)
            #expect(
                stepCount == 0,
                """
                the OTA archive step must not declare `\(setting)` (found \(stepCount)); \
                an `env:` mapping is honored by xcodebuild as a build setting and moves \
                the archive just like the command-line spelling (issue #427)
                """
            )
            #expect(
                fileCount == 0,
                """
                \(Self.otaWorkflowPath) must not declare `\(setting)` at any indent \
                (found \(fileCount)); job- or workflow-level env build settings are \
                inherited by the archive step (issue #427)
                """
            )
        }

        // `-derivedDataPath` is last-wins like any build setting: bind it
        // exactly once so a second path cannot move the archive's DerivedData
        // — and therefore the whole cached-root invariant this pin protects —
        // without redding (impl lens 1 F2).
        let derivedDataFlag = #"-derivedDataPath"#
        let derivedDataCount = Self.tokenOccurrenceCount(archive, token: derivedDataFlag)
        #expect(
            derivedDataCount == 1,
            """
            the OTA archive step must carry exactly one `-derivedDataPath` (found \
            \(derivedDataCount)); a second flag with any value is last-wins and would \
            silently move the archive out of the cached root the relocation depends \
            on (issue #427)
            """
        )
    }

    // MARK: - Scanner

    private struct StepBlock {
        let lines: [String]

        var text: String { lines.joined(separator: "\n") }
    }

    /// True when the block contains `exact` as a whole trimmed line — the
    /// full-scalar bind a suffix rename (`…-ct`, `…-v2`) must fail.
    private static func hasLine(_ block: StepBlock, equalTo exact: String) -> Bool {
        block.lines.contains { $0.trimmingCharacters(in: .whitespaces) == exact }
    }

    /// True when the block contains `exact` as a whole line at exactly
    /// `indent` leading spaces — the `with:`-child container check. `hasLine`
    /// trims leading whitespace, so it cannot tell a `with:` child from a
    /// step field or an `env:` entry; this one fails such a relocation
    /// (issue #418).
    private static func hasLine(_ block: StepBlock, equalTo exact: String, atIndent indent: Int) -> Bool {
        indentedLineCount(block, equalTo: exact, indent: indent) == 1
    }

    /// The count of lines equal to `exact` after trimming at exactly `indent`
    /// leading spaces (a tab or a deeper/shallower indent does not count).
    private static func indentedLineCount(_ block: StepBlock, equalTo exact: String, indent: Int) -> Int {
        let prefix = String(repeating: " ", count: indent)
        return block.lines.filter { line in
            guard line.hasPrefix(prefix) else { return false }
            let remainder = line.dropFirst(prefix.count)
            return !remainder.hasPrefix(" ") && remainder.trimmingCharacters(in: .whitespaces) == exact
        }.count
    }

    /// The count of exact whole trimmed lines — hand-rolled so a block-scalar
    /// value line can be duplicate-guarded too (`hasLine` is presence-only).
    private static func exactLineCount(_ block: StepBlock, equalTo exact: String) -> Int {
        block.lines.filter { $0.trimmingCharacters(in: .whitespaces) == exact }.count
    }

    /// The count of token-boundary occurrences of `token` over the block's
    /// comment-stripped lines — the A11 negative check. A plain substring
    /// count is wrong in both directions: `CONFIGURATION_BUILD_DIR=` contains
    /// `BUILD_DIR=` (so a substring count would red the correct source), and
    /// a trimmed line-prefix count misses `export BUILD_DIR=…` and mid-line
    /// `… BUILD_DIR=…` spellings. A token boundary is a start-of-line position
    /// or any preceding character outside `[A-Za-z0-9_]` (issue #427).
    private static func tokenOccurrenceCount(_ block: StepBlock, token: String) -> Int {
        var count = 0
        for line in block.lines {
            var searchStart = line.startIndex
            while let range = line.range(of: token, range: searchStart..<line.endIndex) {
                if range.lowerBound == line.startIndex {
                    count += 1
                } else {
                    let preceding = line[line.index(before: range.lowerBound)]
                    if !(preceding.isLetter || preceding.isNumber || preceding == "_") {
                        count += 1
                    }
                }
                searchStart = range.upperBound
            }
        }
        return count
    }

    /// The trimmed value after `key:` on the first line starting with that
    /// key; nil when the key is absent. Used for the A10 relational bind.
    private static func colonValue(of key: String, in block: StepBlock) -> String? {
        for line in block.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + ":") else { continue }
            return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The one step containing `needle`, or a fail-closed `PinFailure`.
    /// Content signatures (not step names) identify steps, so a benign rename
    /// of a step stays green; a deleted or duplicated step reds.
    private static func stepIndex(containing needle: String, in steps: [StepBlock], label: String) throws -> Int {
        let matches = steps.indices.filter { steps[$0].text.contains(needle) }
        guard matches.count == 1, let index = matches.first else {
            throw PinFailure(
                "expected exactly one composite/workflow step containing `\(needle)` (\(label)), found \(matches.count) — re-derive this pin (issue #109)"
            )
        }
        return index
    }

    /// Slices `.github/actions/prepare-xcode-build/action.yml` into its
    /// composite steps. Fail-closed text heuristic: exactly one top-level
    /// `runs:` key, exactly one `  steps:` key under it, list items at the
    /// step indent, and no other non-empty content at that indent.
    private static func compositeSteps() throws -> [StepBlock] {
        let lines = try Self.commentCutLines(of: actionPath)

        let runsMatches = lines.enumerated().filter { pair in
            pair.element.range(of: #"^runs:\s*$"#, options: .regularExpression) != nil
        }
        guard runsMatches.count == 1, let runsStart = runsMatches.first?.offset else {
            throw PinFailure(
                "expected exactly one top-level `runs:` key in \(actionPath), found \(runsMatches.count) — re-derive this pin (issue #109)"
            )
        }

        // The action ends at the next top-level key, if any.
        var actionEnd = lines.count
        var cursor = runsStart + 1
        while cursor < lines.count {
            let line = lines[cursor]
            let indent = line.prefix { $0 == " " }.count
            if !line.trimmingCharacters(in: .whitespaces).isEmpty, indent == 0 {
                actionEnd = cursor
                break
            }
            cursor += 1
        }

        let stepsKeys = (runsStart + 1..<actionEnd).filter { lines[$0] == "  steps:" }
        guard stepsKeys.count == 1, let stepsStart = stepsKeys.first else {
            throw PinFailure(
                "expected exactly one `  steps:` key under `runs:` in \(actionPath), found \(stepsKeys.count) — re-derive this pin (issue #109)"
            )
        }

        var stepsEnd = actionEnd
        cursor = stepsStart + 1
        while cursor < actionEnd {
            let line = lines[cursor]
            let indent = line.prefix { $0 == " " }.count
            if !line.trimmingCharacters(in: .whitespaces).isEmpty, indent <= 2 {
                stepsEnd = cursor
                break
            }
            cursor += 1
        }

        return try Self.sliceSteps(lines: Array(lines[(stepsStart + 1)..<stepsEnd]), stepIndent: 4, context: actionPath)
    }

    /// Slices the `ota-archive` job out of the OTA workflow and returns its
    /// steps (workflow steps sit at indent 6).
    private static func otaSteps() throws -> [StepBlock] {
        let lines = try Self.commentCutLines(of: otaWorkflowPath)

        let jobKeys = lines.enumerated().filter { $0.element == "  ota-archive:" }
        guard jobKeys.count == 1, let jobStart = jobKeys.first?.offset else {
            throw PinFailure(
                "expected exactly one `  ota-archive:` job key in \(otaWorkflowPath), found \(jobKeys.count) — re-derive this pin (issue #109)"
            )
        }

        var jobEnd = lines.count
        var cursor = jobStart + 1
        while cursor < lines.count {
            let line = lines[cursor]
            let indent = line.prefix { $0 == " " }.count
            if !line.trimmingCharacters(in: .whitespaces).isEmpty, indent <= 2 {
                jobEnd = cursor
                break
            }
            cursor += 1
        }

        return try Self.sliceSteps(lines: Array(lines[(jobStart + 1)..<jobEnd]), stepIndent: 6, context: otaWorkflowPath)
    }

    /// Slices list items at `stepIndent` into step blocks. Job-level content
    /// (e.g. `runs-on:`, an `env:` mapping whose entries sit at the step
    /// indent) before the first step is skipped, matching the repo's
    /// `stepBlocks(in:)` idiom. After the first step, a non-list line at the
    /// step indent throws instead of silently merging into a step.
    private static func sliceSteps(lines: [String], stepIndent: Int, context: String) throws -> [StepBlock] {
        var steps: [StepBlock] = []
        var current: [String] = []
        for line in lines {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if indent == stepIndent, trimmed.hasPrefix("- ") {
                if !current.isEmpty { steps.append(StepBlock(lines: current)) }
                current = [line]
            } else if current.isEmpty {
                // Job-level keys and their nested values precede the steps.
                continue
            } else if indent == stepIndent, !trimmed.isEmpty {
                throw PinFailure(
                    "unexpected non-list content at the step indent in \(context) (`\(trimmed)`) — the step shape changed; re-derive this pin (issue #109)"
                )
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { steps.append(StepBlock(lines: current)) }
        guard !steps.isEmpty else {
            throw PinFailure("no steps found in \(context) — re-derive this pin (issue #109)")
        }
        return steps
    }

    private static func commentCutLines(of relativePath: String) throws -> [String] {
        let source = try PinScan.source(relativePath)
        return Self.strippingYAMLComments(source)
            .components(separatedBy: "\n")
            .map(Self.cuttingLineComment)
    }

    /// Cuts one YAML/bash-style trailing comment from a single line: a `#`
    /// at line start or preceded by whitespace starts a comment, outside
    /// single/double quotes. The file-level `strippingYAMLComments` already
    /// blanks comments, but it can be left stuck by an apostrophe; this
    /// per-line backstop keeps the scanned region clean in that case.
    private static func cuttingLineComment(_ line: String) -> String {
        var result = ""
        var previousWasWhitespace = true
        var inSingleQuoted = false
        var inDoubleQuoted = false
        var escaped = false
        for character in line {
            if inDoubleQuoted {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inDoubleQuoted = false
                }
                previousWasWhitespace = false
                continue
            }
            if inSingleQuoted {
                result.append(character)
                if character == "'" {
                    inSingleQuoted = false
                }
                previousWasWhitespace = false
                continue
            }
            if character == "#", previousWasWhitespace {
                break
            }
            if character == "'" {
                inSingleQuoted = true
            } else if character == "\"" {
                inDoubleQuoted = true
            }
            result.append(character)
            previousWasWhitespace = character.isWhitespace
        }
        return result
    }

    /// A YAML comment-stripped copy of `source`: a `#` that starts a comment
    /// (at line start or preceded by whitespace, outside a quoted scalar)
    /// blanks the rest of the line; newlines are preserved, so line anchors
    /// still resolve. Single-quoted (`''` escapes) and double-quoted (`\`
    /// escapes) scalars are copied verbatim, so a `#` inside a scalar is not
    /// read as a comment. Duplicated from `WorkflowXcodebuildFlagPinsTests`
    /// (each pin file is self-contained so it reverts independently).
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
                        // YAML single-quote escape: `''` stays inside the scalar.
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
}
