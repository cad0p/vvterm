# Ghostty patch queue

VVTerm embeds [Ghostty](https://github.com/ghostty-org/ghostty) through the classic
`ghostty_app` C API via a vendored prebuilt xcframework
(`Vendor/libghostty/GhosttyKit.xcframework`). Upstream never merged — and will not merge
(the classic API is branded "libghostty-internal") — the custom-I/O feature VVTerm's SSH
terminal depends on. This directory is the repo-owned replacement for the old
floating `wiedymi/ghostty@custom-io` fork branch.

## Why a patch at all

The app depends on exactly 4 fork-only symbols:

| Symbol | Role |
|---|---|
| `use_custom_io` (config field) | selects the callback termio backend instead of spawning a pty |
| `ghostty_surface_feed_data` | host → terminal bytes (SSH channel output) |
| `ghostty_surface_set_write_callback` | installs the terminal → host callback (keyboard input) |
| `ghostty_surface_write_fn` | the callback typedef |

There is no runtime substitute: the backend is Zig code compiled into the library, and
`use_custom_io` only drives a compile-time union switch. The patch must be carried as code.

## Contents

`custom-io.patch` — the fork's 7-commit custom-I/O delta (2026-01-06 → 03-08) **rebased
onto the upstream commit recorded in `BASE`**, plus the **iOS full-build restoration**
(carried since 2026-08-12 — see below):

- `src/termio/Callback.zig` — the callback I/O backend (~180 lines)
- `src/termio.zig`, `src/termio/backend.zig`, `src/termio/Thread.zig`, `src/termio/message.zig` — backend wiring
- `src/apprt/embedded.zig` — the 3 C API exports + surface `use_custom_io`
- `src/Surface.zig` — `use_custom_io` config plumbing (IO-init branching)
- `include/ghostty.h` — the 4 C symbols the app compiles against
- `pkg/macos/iosurface/iosurface.zig`, `src/renderer/Metal.zig`, `src/renderer/metal/IOSurfaceLayer.zig`, `src/font/shaper/coretext.zig` — iOS renderer fixes the app relies on (row-bytes alignment, iOS present path, CFReleaseThread disabled on iOS)
- `src/build/GhosttyXCFramework.zig`, `src/build/MetallibStep.zig`, `src/build/Config.zig`, `pkg/macos/iosurface/iosurface.zig`, `macos/build.nu`, `HACKING.md`, `nix/devShell.nix` — **iOS build restoration**: upstream commit `7a171895d` ("build: stop building Ghostty.xcframework for iOS", 2026-08-12) deleted the iOS/iOS-simulator slices from the xcframework, the MetallibStep iOS branch, and `osVersionMin(.ios)`. VVTerm needs all three slices, so the patch carries the reverse of that commit. If a future upstream build refactor conflicts here, the probe alarms — re-reverse `7a171895d` or hand-merge

Excluded deliberately (do not re-add):

- `macos/Sources/App/iOS/iOSApp.swift`, `macos/Sources/Ghostty/Ghostty.App.swift`, `macos/Sources/Ghostty/Surface View/SurfaceView.swift`, `macos/Sources/Ghostty/Surface View/SurfaceView_UIKit.swift` — the fork's macOS demo app; not compiled by the libghostty build (`-Demit-macos-app=false`)
- `build.zig.zon` — fork swaps the libxev dep URL to a github archive; upstream's `deps.files.ghostty.org` CDN works
- `src/renderer/generic.zig` — fork only removes commented-out debug code

`BASE` — the upstream commit SHA the patch applies to. `scripts/build.sh` clones upstream
at this ref (default) and applies the patch; `Vendor/libghostty/VERSION` records the base
of the *committed* vendored build. The weekly probe updates both together.

## Rebuilding locally

```sh
./scripts/build.sh ghostty          # clones upstream @ BASE, applies custom-io.patch + inline patches
GHOSTTY_REF=<sha> ./scripts/build.sh ghostty   # build against a different upstream ref
VVTERM_STRICT_BUILD=1 ./scripts/build.sh ghostty  # hard-fail if the ref differs from the vendored VERSION
```

Requires: git, [zig 0.16.0](https://ziglang.org/download/), Xcode, perl, rsync.
The xcframework + stripped `.a` libs land in `Vendor/libghostty/` and the script writes
`Vendor/libghostty/VERSION` = the checked-out upstream base SHA.

## Regenerating from the fork (one-time reference)

```sh
git clone https://github.com/wiedymi/ghostty.git
cd ghostty
# fork delta base (rebased history) .. fork custom-io tip:
git diff b34c62bf0 91fe505e6 > custom-io-full.patch
# then filter to the files listed under "Contents", drop the exclusions,
# and rebase onto the current upstream main (see below).
```

## Rebasing onto a newer upstream (`BASE` bump)

The weekly probe alarms when the patch stops applying (`git apply --check` fails) or the
behavioral probe fails. Fix procedure:

```sh
cd /tmp
git clone https://github.com/ghostty-org/ghostty.git gv
cd gv
git checkout <new-upstream-main-sha>
git apply --3way /path/to/custom-io.patch   # most hunks apply cleanly
git add -A                                  # stage cleanly-applied files
git checkout -- build.zig.zon macos/        # re-exclude demo app + dep URL swap
```

Hand-merge the known conflict spots:

1. **`src/Surface.zig`** — "Start our IO implementation" block. Keep upstream's newest env
   handling (`global.environMap()`, `_ = env.orderedRemove("GHOSTTY_LOG")`,
   `GHOSTTY_SURFACE_ID`, `global.resourcesDir()`) inside the fork's `else` (non-custom-I/O)
   branch; keep the fork's `Mailbox.initSPSC` + `backend` union + `if (use_custom_io) { Callback } else { Exec }`
   structure and `Termio.init(.backend = backend, .mailbox = io_mailbox)`.
2. **`src/font/shaper/coretext.zig`** — fork makes the CF release thread optional on iOS
   (`?*CFReleaseThread`, spawn skipped when `comptime builtin.os.tag != .ios`, release-pool
   flush wrapped in `if (self.cf_release_thread) |thread|`). Keep upstream's newer
   `setName(global.io(), ...)` signatures.
3. **New `Backend`/`ThreadData` switch arms** — upstream adds new functions that switch on
   the backend unions (`Kind = enum { exec, callback }`) over time. Every such switch must
   gain a `.callback` arm; recent example: `getProcessInfo` in `src/termio/backend.zig`
   (callback has no process → `return null`). Grep for `switch (self.*)` / `switch (data.backend)`
   in `src/termio/backend.zig` and `src/termio/Thread.zig` and check every arm.
4. **libghostty C API signature drift (app-side)** — when the probe build succeeds but the
   unit suite fails to compile, upstream changed a C API the app compiles against.
   Known: `ghostty_runtime_read_clipboard_cb` returns `bool` since ~2026-08-12 (was `void`);
   `VVTerm/GhosttyTerminal/Ghostty.App.swift`'s `readClipboard` returns `Bool` (false when
   the clipboard can't be read, so paste bindings fall through), and the three vendored
   `Vendor/libghostty/{,ios/,ios-simulator/}include/ghostty.h` typedefs are kept in sync
   (the app targets the new API on main even before a bump merges; the old lib ignores the
   return value — ABI-safe).

Then:

```sh
git diff <new-upstream-main-sha> -- include/ghostty.h pkg/macos/iosurface/iosurface.zig \
  src/Surface.zig src/apprt/embedded.zig src/font/shaper/coretext.zig src/renderer/Metal.zig \
  src/renderer/metal/IOSurfaceLayer.zig src/termio.zig src/termio/Callback.zig \
  src/termio/Thread.zig src/termio/backend.zig src/termio/message.zig \
  src/build/Config.zig src/build/GhosttyXCFramework.zig src/build/MetallibStep.zig \
  HACKING.md macos/build.nu nix/devShell.nix \
  > scripts/patches/ghostty/custom-io.patch
echo <new-upstream-main-sha> > scripts/patches/ghostty/BASE

**Regeneration gotcha**: `src/termio/Callback.zig` is a NEW file (not in upstream) —
`git apply` leaves it untracked and `git diff` silently skips untracked files, so a
regenerated patch will DROP it and the build fails with `unable to load
'termio/Callback.zig'`. Run `git add -N src/termio/Callback.zig` (intent-to-add)
before `git diff` and verify the output contains `new file mode` for it.
```

Validate before committing (a Linux box can compile-verify the core — see below):

```sh
# Compile-verify the core on Linux (no macOS needed): install zig 0.16.0 for
# linux-aarch64/x86_64, then from the patched tree:
zig build -Dapp-runtime=none -Demit-exe=false -Demit-docs=false -Demit-webdata=false \
  -Demit-helpgen=false -Demit-terminfo=false -Demit-termcap=false -Demit-themes=false \
  -Di18n=false -Doptimize=Debug -p /tmp/zig-out-host
# Compiles termio/*, Surface.zig and the renderer core and catches missing .callback
# switch arms and merge mistakes. Use Debug on small boxes (ReleaseFast OOMs a 2GB
# machine); run `zig build --fetch=all` once first (the Darwin lazy deps like
# zig_objc are NOT fetched by a plain build). macOS-only files (coretext.zig,
# embedded.zig, Metal/IOSurfaceLayer) and the iOS slices are NOT covered — the
# probe build on the macOS runner is the real validator.
```

```sh
git apply --check scripts/patches/ghostty/custom-io.patch   # on a pristine <new> checkout
grep -E 'ghostty_surface_write_fn|use_custom_io|ghostty_surface_feed_data|ghostty_surface_set_write_callback' scripts/patches/ghostty/custom-io.patch  # all 4
grep '^diff --git' scripts/patches/ghostty/custom-io.patch   # no build.zig.zon / macos/ / generic.zig
./scripts/build.sh ghostty                                    # full build (macOS machine)
```

Known build.sh friction: the xcframework slice lib names drift upstream — the macOS
slice is emitted by LipoStep with the out_name verbatim (`ghostty-internal.a`, no
`lib` prefix) while the iOS slices go through addLibrary and keep the `lib` prefix
(`libghostty-internal.a`). `scripts/build.sh` therefore matches `*.a` inside each
slice dir and prints the xcframework contents + Info.plist on mismatch.

## Validating a rebuild

- Behavioral probe: `VVTermTests/GhosttyCustomIOProbeTests` (custom-I/O round-trip,
  keyboard direction, no-pty assertion) + `GhosttyOSCColorQueryTests` — run them via the
  probe workflow dispatch (below) or locally:
  `xcodebuild test -scheme VVTermUnitTests -destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64' -only-testing:VVTermTests/GhosttyCustomIOProbeTests`
- App-level: the loopback-SSH UI tests in PR CI exercise the custom-I/O path end-to-end.

## Weekly probe workflow

`.github/workflows/ghostty-upstream-probe.yml` (Mon 06:00 UTC + manual dispatch):

- Resolves latest upstream `main` → no-op week if it equals `Vendor/libghostty/VERSION`
- Rebuilds (upstream + patch), pre-validates with the **full VVTermTests unit suite**
  (incl. the behavioral probe tests) against the NEW binaries
- Pass → bump PR (`chore/ghostty-upstream-bump-<sha7>`, artifacts + VERSION + BASE)
  created with the **vvterm-ghostty-bump GitHub App token**, auto-merge enabled
- The bump PR's own `pull_request` CI runs **automatically** (app-created PRs are
  first-class actors — no approval, no click) and is the **merge gate**: the
  `gh-ruleset-main` required checks (`build`, `unit-tests`, `ui-tests-shard-0..3`,
  stable job names — no wildcards; rulesets don't support them) must pass;
  auto-merge then merges. The `watch` job exits 0 on merge, files an alarm issue on
  red CI, and parks (never alarms) on stalls — with one self-heal before parking:
  if every check is green but auto-merge hasn't fired within 10m, the watch
  **re-enables auto-merge once** (observed 2026-08-13 on the first live bump: after
  check reruns the mergeability evaluation can go stale — `BLOCKED` with all
  required checks green — and auto-merge never fires; re-enabling forces a fresh
  evaluation) before parking.
- Fail before PR creation → alarm issue (label `ghostty-patch`) with this runbook; the
  shipped app is untouched

### Why a GitHub App token (no PAT, no human, no bypass actor, no direct push)

- A bump PR created with `GITHUB_TOKEN` runs its `pull_request` CI in an
  **approval-required** state (one human click per bump) — rejected by design.
- A PR created with a **GitHub App installation token** is a first-class actor: its
  workflows run automatically, exactly like a human PR. The app is scoped to this
  repo only (Contents + Pull requests read/write, installed on `cad0p/vvterm` only).
- No direct pushes and no ruleset bypass actors: the bump goes through a normal PR
  and the ruleset's required checks are the gate via auto-merge.
- Setup (done 2026-08-12): GitHub App `vvterm-ghostty-bump` (App ID 4570338) created
  and installed on `cad0p/vvterm`; **Client ID** stored as repo variable
  `GHOSTTY_BUMP_CLIENT_ID`; the app's **private key** must be stored as the Actions
  secret `GHOSTTY_BUMP_PRIVATE_KEY` (full PEM). Revoke anytime by deleting the app
  or uninstalling it.

### Ruleset constraint (learned the hard way, 2026-08-12)

`gh-ruleset-all` must NOT contain `required_linear_history` or `required_signatures`:

- `required_linear_history` on a ruleset evaluates the **entire branch history**,
  not just new commits ([known GitHub bug — GH community #80952](https://github.com/orgs/community/discussions/80952)).
  This repo's `main` contains historical merge commits, so **every new-branch push
  fails** — including the probe's bump branch. The rule only works on the default
  branch (delta-only evaluation), where `gh-ruleset-main` keeps it.
- `required_signatures` rejects the probe runner's unsigned bump commit (a GitHub App
  cannot sign commits; no bypass actors allowed by design).

`gh-ruleset-all` currently has `non_fast_forward` only; `gh-ruleset-main` keeps
`deletion`, `non_fast_forward`, `pull_request` (squash), `required_signatures`,
`required_linear_history`, `required_status_checks`, `code_quality`.

Manual dispatch inputs: `force_rebuild` (skip the no-op gate), `create_bump_pr`
(skip PR creation — useful for validation runs).

Dispatch `ref` restriction: the workflow file must exist on `main` to be dispatched
at all (GitHub's dispatch API resolves the workflow against the default branch).
Validation runs dispatch from `main` with `force_rebuild=true, create_bump_pr=false`.

**Dispatch booleans**: use the REST API with real JSON booleans —
`gh workflow run -f create_bump_pr=false` is unreliable (gh CLI drops/coerces the
value and the step still runs; observed 2026-08-12):

```sh
gh api -X POST repos/cad0p/vvterm/actions/workflows/ghostty-upstream-probe.yml/dispatches \
  --input '{"ref":"main","inputs":{"force_rebuild":true,"create_bump_pr":false}}'
```

### Alarm drill (simulate patch drift)

1. On a scratch branch, corrupt the patch: `sed -i '' 's/use_custom_io/use_custom_iox/' scripts/patches/ghostty/custom-io.patch`
2. Push, dispatch the workflow with `ref` = that branch, `create_bump_pr=false`
3. Expect: build step fails at patch apply → alarm issue filed with the run URL
4. Cleanup: delete the alarm issue + the scratch branch
