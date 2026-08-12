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

`custom-io.patch` — the fork's 7-commit custom-I/O delta (2026-01-06 → 03-08), **rebased
onto the upstream commit recorded in `BASE`**:

- `src/termio/Callback.zig` — the callback I/O backend (~180 lines)
- `src/termio.zig`, `src/termio/backend.zig`, `src/termio/Thread.zig`, `src/termio/message.zig` — backend wiring
- `src/apprt/embedded.zig` — the 3 C API exports + surface `use_custom_io`
- `src/Surface.zig` — `use_custom_io` config plumbing (IO-init branching)
- `include/ghostty.h` — the 4 C symbols the app compiles against
- `pkg/macos/iosurface/iosurface.zig`, `src/renderer/Metal.zig`, `src/renderer/metal/IOSurfaceLayer.zig`, `src/font/shaper/coretext.zig` — iOS renderer fixes the app relies on (row-bytes alignment, iOS present path, CFReleaseThread disabled on iOS)

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

Then:

```sh
git diff <new-upstream-main-sha> -- include/ghostty.h pkg/macos/iosurface/iosurface.zig \
  src/Surface.zig src/apprt/embedded.zig src/font/shaper/coretext.zig src/renderer/Metal.zig \
  src/renderer/metal/IOSurfaceLayer.zig src/termio.zig src/termio/Callback.zig \
  src/termio/Thread.zig src/termio/backend.zig src/termio/message.zig \
  > scripts/patches/ghostty/custom-io.patch
echo <new-upstream-main-sha> > scripts/patches/ghostty/BASE
```

Validate before committing (a Linux box can compile-verify the core — see below):

```sh
# Compile-verify the core on Linux (no macOS needed): install zig 0.16.0 for
# linux-aarch64/x86_64, then from the patched tree:
zig build -Dapp-runtime=none -Demit-exe=false -Demit-docs=false -Demit-webdata=false \
  -Demit-helpgen=false -Demit-terminfo=false -Demit-termcap=false -Demit-themes=false
# This compiles termio/*, Surface.zig and the renderer core and catches missing
# .callback switch arms and merge mistakes. macOS-only files (coretext.zig,
# embedded.zig, Metal/IOSurfaceLayer) are NOT covered — the probe build is.
```

```sh
git apply --check scripts/patches/ghostty/custom-io.patch   # on a pristine <new> checkout
grep -E 'ghostty_surface_write_fn|use_custom_io|ghostty_surface_feed_data|ghostty_surface_set_write_callback' scripts/patches/ghostty/custom-io.patch  # all 4
grep '^diff --git' scripts/patches/ghostty/custom-io.patch   # no build.zig.zon / macos/ / generic.zig
./scripts/build.sh ghostty                                    # full build (macOS machine)
```

## Validating a rebuild

- Behavioral probe: `VVTermTests/GhosttyCustomIOProbeTests` (custom-I/O round-trip,
  keyboard direction, no-pty assertion) + `GhosttyOSCColorQueryTests` — run them via the
  probe workflow dispatch (below) or locally:
  `xcodebuild test -scheme VVTermUnitTests -destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64' -only-testing:VVTermTests/GhosttyCustomIOProbeTests`
- App-level: the loopback-SSH UI tests in PR CI exercise the custom-I/O path end-to-end.

## Weekly probe workflow

`.github/workflows/ghostty-upstream-probe.yml` (Mon 06:00 UTC + manual dispatch):

- Resolves latest upstream `main` → no-op week if it equals `Vendor/libghostty/VERSION`
- Rebuilds (upstream + patch), runs the probe tests
- Pass → bump PR (`chore/ghostty-upstream-bump-<sha7>`, artifacts + VERSION + BASE) whose
  CI is the merge gate; the `watch` job merges on green (no auto-merge — `main` has no
  branch protection) or files an alarm issue on red
- Fail → alarm issue (label `ghostty-patch`) with this runbook; the shipped app is untouched

Manual dispatch inputs: `force_rebuild` (skip the no-op gate), `create_bump_pr` (skip PR
creation — useful for validation runs).

Dispatch `ref` restriction: run validation dispatches on a feature branch with
`create_bump_pr=false` — never on the bump branch itself (`chore/ghostty-upstream-bump-*`)
and never with `create_bump_pr=true` on a non-main ref (the bump PR would fold that ref's
commits into the bump).

### Alarm drill (simulate patch drift)

1. On a scratch branch, corrupt the patch: `sed -i '' 's/use_custom_io/use_custom_iox/' scripts/patches/ghostty/custom-io.patch`
2. Push, dispatch the workflow with `ref` = that branch, `create_bump_pr=false`
3. Expect: build step fails at patch apply → alarm issue filed with the run URL
4. Cleanup: delete the alarm issue + the scratch branch
