# Remote Shell Profiles and Multi-Shell SSH Support (Draft Spec)

## Summary
Refactor VVTerm's remote SSH bootstrap logic around explicit remote shell profiles so shell-specific behavior is modeled in one place instead of being spread across generic SSH, tmux, mosh, and terminal restore paths.

Path note: this draft predates the feature-first migration. Any legacy `Models/`, `Managers/`, `Services/`, or `Views/` file paths in this document should be mapped to the current `App/`, `Core/`, and `Features/` tree.

Draft date: 2026-03-18

## Problem
VVTerm's current SSH flow is mostly POSIX-shaped.

That works well for Unix hosts using `bash`, `zsh`, `fish`, and similar shells, but it breaks down when the remote shell is not POSIX-compatible or when the remote platform is Windows.

Recent Windows PowerShell behavior exposed the underlying issue:
- plain SSH startup previously assumed `/bin/sh -lc`
- working-directory restore assumed POSIX `cd -- ...`
- shell integration availability is only modeled for bundled Unix integrations
- tmux and mosh helpers are hardcoded around `sh -lc`, `export`, `command -v`, and other POSIX constructs

The immediate PowerShell bug can be patched, but continuing with one-off conditionals will make the code harder to extend and easier to regress.

## Goals (V1)
- Introduce a single internal abstraction for remote shell behavior.
- Make plain interactive SSH startup shell-aware and platform-aware.
- Make working-directory restore shell-aware and platform-aware.
- Explicitly model shell/platform capabilities for tmux, mosh, and OSC 7 cwd reporting.
- Add first-class PowerShell support for standard SSH sessions on Windows.
- Preserve the current good path for existing Unix shells.
- Preserve current user-facing settings and flows without adding new capability-based UI blocking.

## Non-Goals (V1)
- Full Windows `cmd.exe` feature parity with PowerShell.
- Windows support for tmux flows.
- Windows support for mosh flows.
- User-configurable arbitrary shell plugins.
- Reworking Ghostty upstream shell integration behavior.
- Changing Ghostty shell integration selection behavior in V1.

## Current State

### What works well today
- Standard SSH sessions to Unix hosts.
- POSIX shell startup and quoting.
- tmux attach/create flows on Unix hosts.
- mosh flows on Unix hosts.
- Ghostty shell integration for bundled shells:
  - `bash`
  - `zsh`
  - `fish`
  - `elvish`

### What is coupled today
- Startup command wrapping is centralized in `RemoteTerminalBootstrap`, but is still mostly POSIX-specific.
- tmux helpers in `RemoteTmuxManager` assume POSIX shell availability.
- mosh helpers in `RemoteMoshManager` assume POSIX shell availability.
- SSH reconnect cwd restore in terminal wrappers previously assumed POSIX `cd -- ...`.
- Ghostty shell integration selection is based on local shell naming, not an explicit remote shell model.
- Stats collection has a separate remote platform detection path and a dedicated Windows PowerShell collector.

### Important current behavior to preserve
- Standard SSH terminal startup must remain fast for Unix hosts.
- Working-directory restore must continue to work across reconnects when the shell supports it.
- tmux attach/create behavior must remain intact for supported Unix targets.
- mosh behavior must remain intact for supported Unix targets.
- Stats collection must continue to work independently of terminal shell integration.
- Windows stats collection must keep working through PowerShell-based commands.

Relevant files:
- `VVTerm/Services/SSH/RemoteTerminalBootstrap.swift`
- `VVTerm/Services/SSH/SSHClient.swift`
- `VVTerm/Services/SSH/RemoteTmuxManager.swift`
- `VVTerm/Services/SSH/RemoteMoshManager.swift`
- `VVTerm/Services/Stats/ServerStatsCollector.swift`
- `VVTerm/Services/Stats/Platforms/PlatformStatsCollector.swift`
- `VVTerm/Services/Stats/Platforms/WindowsStatsCollector.swift`
- `VVTerm/Views/Terminal/SSHTerminalWrapper.swift`
- `VVTerm/Views/Splits/TerminalView.swift`
- `VVTerm/Views/Stats/ServerStatsView.swift`
- `VVTerm/GhosttyTerminal/Ghostty.App.swift`

## Stats Requirements

The stats page is in scope for this refactor.

Current behavior:
- `ServerStatsCollector` detects remote platform separately from terminal startup.
- Platform detection currently runs:
  - `uname -s 2>/dev/null || ver 2>/dev/null || echo unknown`
- Windows stats are collected by `WindowsStatsCollector` with explicit `powershell -Command ...` invocations.

Implications:
- remote platform detection and remote shell detection must not diverge
- shell-profile work must not break `ServerStatsCollector`
- Windows support cannot mean only terminal startup support; stats must remain first-class

V1 requirement:
- define a shared remote environment model that can be reused by:
  - SSH terminal startup
  - working-directory restore
  - tmux/mosh capability checks
  - stats collection

The stats collectors do not need to become shell-profile implementations, but they should consume the same resolved remote platform information rather than redetecting incompatible state independently.

## Shell Support Matrix

### V1 target support
- POSIX shells on Unix hosts:
  - `sh`
  - `bash`
  - `zsh`
  - `fish`
  - `elvish`
  - `nushell` via the POSIX wrapper path
- Windows PowerShell family on Windows hosts:
  - `powershell`
  - `pwsh`

### V1 minimal compatibility only
- `cmd.exe`
  - plain interactive startup only
  - no shell integration
  - no tmux/mosh support

### Deferred
- Windows `tmux`
  - out of scope
- Windows `mosh`
  - out of scope

## Shell Capability Matrix

The matrix below describes runtime capability, not whether the user may see or select a UI option.

| Shell / Platform | Plain SSH | Startup Command Wrapping | CWD Restore | Shell Integration | tmux Runtime | mosh Runtime | Stats |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `sh` on Unix | Full | Full | Full | Limited / generic | Full | Full | Full |
| `bash` on Unix | Full | Full | Full | Full | Full | Full | Full |
| `zsh` on Unix | Full | Full | Full | Full | Full | Full | Full |
| `fish` on Unix | Full | Full via POSIX wrapper entry | Full | Full | Full | Full | Full |
| `elvish` on Unix | Full | Full via POSIX wrapper entry | Full | Full | Full | Full | Full |
| `powershell` on Windows | Full | Full | Full | None in V1 | Fallback to plain SSH | Fallback to plain SSH | Full |
| `pwsh` on Windows | Full | Full | Full | None in V1 | Fallback to plain SSH | Fallback to plain SSH | Full |
| `cmd.exe` on Windows | Basic | Minimal / fallback only | Basic | None | Fallback to plain SSH | Fallback to plain SSH | Full when PowerShell is available for stats commands |
| `nushell` on Unix | Full via POSIX wrapper path | Full via POSIX wrapper path | Full | None in V1 | Full | Full | Full |
| Unknown Unix-like shell | Conservative POSIX fallback | Conservative POSIX fallback | Full when POSIX path works | None | Full when POSIX path works | Full when POSIX path works | Full |
| Unknown Windows shell | Plain SSH fallback | Conservative fallback only | Disabled unless shell is resolved confidently | None | Fallback to plain SSH | Fallback to plain SSH | Full when PowerShell is available for stats commands |

Definitions:
- `Full`: supported as a first-class runtime path in V1.
- `Basic`: intended to start correctly, but advanced shell-specific polish is limited.
- `None`: no shell-specific integration provided in V1.
- `Fallback to plain SSH`: user settings remain available, but VVTerm resolves capabilities at runtime and silently uses normal SSH shell behavior instead of tmux/mosh-specific behavior.

## Proposed Design

### 1) Introduce a remote shell profile model
Add a small internal model that makes shell behavior explicit.

Proposed types:
- `RemotePlatform`
  - `.unix`
  - `.windows`
- `RemoteShellFamily`
  - `.posix`
  - `.powershell`
  - `.cmd`
  - `.unknown`
- `RemoteShellProfile`
  - `platform: RemotePlatform`
  - `family: RemoteShellFamily`
  - `executableName: String?`
  - `supportsPOSIXExecWrapper: Bool`
  - `supportsPowerShellCommands: Bool`
  - `supportsOSC7Reporting: Bool`
  - `supportsTmux: Bool`
  - `supportsMosh: Bool`
  - `supportsWorkingDirectoryRestore: Bool`

The profile should be an internal strategy object, not a user-extensible plugin system.

### 2) Separate shell launch strategy from startup command wrapping
Today a plain SSH session and a shell-specific startup command share too much logic.

Instead, model launch separately:
- `interactiveShell`
  - ask the SSH server for its default login shell
- `execWrapped(command)`
  - only when the profile supports a specific wrapper

Examples:
- POSIX shell:
  - wrapper: `/bin/sh -lc ...`
- PowerShell:
  - wrapper: `powershell -NoLogo -NoProfile -Command ...` or `pwsh ...`
- `cmd.exe`:
  - wrapper: `cmd.exe /d /k ...` only if we intentionally support command bootstrapping there

This removes the need for generic code to guess which quoting rules apply.

### 3) Centralize per-shell command generation
Create a shell strategy surface for operations VVTerm performs after connect.

Proposed API shape:
- `wrapStartupCommand(_ command: String) -> String?`
- `directoryChangeCommand(path: String) -> String?`
- `quoteLiteral(_ value: String) -> String`
- `defaultLaunchMode() -> RemoteShellLaunchPlan`

Behavior examples:
- POSIX:
  - `cd -- '/path'`
- PowerShell:
  - `Set-Location -LiteralPath 'C:\Users\...'`
- `cmd.exe`:
  - `cd /d C:\Users\...`

The important rule is that UI and SSH orchestration code should stop constructing shell syntax directly.

### 4) Add remote shell and platform detection
VVTerm needs a best-effort way to resolve a remote shell profile early in connection startup.

Detection should be layered:
1. Use explicit transport/platform knowledge where already available.
   - Example: Windows platform can already be inferred in stats collection paths.
2. If needed, probe the remote host with lightweight detection commands.
3. Fall back conservatively:
   - unknown Unix-like host -> conservative POSIX behavior
   - unknown Windows host -> `.unknown`, with shell-specific restore/features disabled unless detection becomes confident

Detection does not need to be perfect in V1, but it must be explicit and visible in code.

The same remote environment resolution should be reusable by stats collection so the app has one canonical answer for:
- remote platform
- remote shell family
- feature support

### 5) Gate tmux and mosh by profile capability
`RemoteTmuxManager` and `RemoteMoshManager` should only run when the active profile allows them.

V1 rules:
- `supportsTmux == true` only for Unix POSIX shells
- `supportsMosh == true` only for Unix POSIX shells
- Windows profiles must bypass these flows cleanly
- Nushell is treated as POSIX-capable in V1 because tmux/mosh/startup commands are launched through the POSIX wrapper path rather than Nushell-specific syntax.

This removes the current implicit assumption that every SSH target can execute `sh -lc`.

Important UI rule:
- VVTerm must not hide, disable, or block tmux/mosh UI based only on shell capability resolution.
- Existing settings and selections remain user-visible.
- At runtime, if the resolved remote environment does not support tmux or mosh, VVTerm automatically falls back to normal SSH shell behavior.
- Fallback should be safe and observable in logs, but should not require extra user intervention.
- Mosh fallback should be exposed in active session state.
- tmux fallback may remain status-based in V1 as long as it safely degrades to plain SSH behavior without mutating saved settings.
- Example: a server configured for mosh may show "requested mosh, using SSH fallback" for the current session.
- VVTerm must not automatically rewrite the saved server connection mode or tmux/mosh preferences during fallback.
- When fallback repeats, VVTerm may present a non-blocking recommendation to switch the server to `SSH`.

### 6) Preserve current Ghostty integration scope
Ghostty integration resources currently exist only for:
- `bash`
- `zsh`
- `fish`
- `elvish`

V1 does not need to invent a custom Ghostty integration implementation for PowerShell, `cmd.exe`, or Nushell.

That means:
- keep using bundled Ghostty integrations where they exist
- mark PowerShell and `cmd.exe` as no-shell-integration profiles for now
- mark Nushell and unknown shells as no-shell-integration profiles for now
- do not pretend prompt/cwd/title features are equally available on every remote shell
- do not change Ghostty integration selection behavior as part of this refactor

### 7) Preserve upgrade compatibility
This refactor must not introduce breaking user-facing behavior during app update.

What must remain stable:
- server models and CloudKit schema
- Keychain credential storage
- existing tmux and mosh preferences in settings
- existing connection mode selections
- existing server/session persistence behavior

Compatibility rules:
- existing POSIX hosts should continue using effectively the same runtime behavior after the refactor
- existing Windows hosts should become safer, not more restrictive
- if capability resolution is uncertain, VVTerm should prefer safe fallback behavior over hard failure
- tmux/mosh settings must not be erased or rewritten simply because the current remote shell does not support them
- unsupported combinations should degrade to plain SSH shell startup rather than surfacing blocking UI
- runtime transport fallback should be reflected in active session status without mutating persisted server configuration

Non-goal for V1:
- migrating saved settings to a new compatibility model in a way that changes user intent

## V1 Scope Breakdown

### Phase 1: Refactor foundation
- Add `RemoteShellProfile` types.
- Add a shared `RemoteEnvironmentResolver` for platform + shell detection.
- Move startup wrapping, cwd restore, and quoting behind profile methods.
- Stop building shell syntax directly in terminal wrapper code.
- Gate tmux/mosh by profile capability with runtime fallback to plain SSH.

### Phase 2: PowerShell first-class support
- Resolve Windows PowerShell family as a supported profile.
- Support:
  - plain SSH startup
  - startup command wrapping
  - cwd restore
  - capability gating
- Keep shell integration limited if Ghostty resources are unavailable.

### Phase 3: Minimal `cmd.exe` compatibility
- Allow safe interactive fallback when PowerShell is unavailable.
- Do not commit to tmux, mosh, or advanced prompt integration.

### Deferred phases
- richer remote shell detection
- custom integration scripts for non-bundled shells

## Proposed File Layout

Possible additions:
- `VVTerm/Services/SSH/RemoteShellProfile.swift`
- `VVTerm/Services/SSH/RemoteEnvironmentResolver.swift`
- `VVTerm/Services/SSH/RemoteShellDetector.swift`
- `VVTerm/Services/SSH/RemoteShellCommandBuilder.swift`

Expected touch points:
- `VVTerm/Services/SSH/RemoteTerminalBootstrap.swift`
- `VVTerm/Services/SSH/SSHClient.swift`
- `VVTerm/Services/SSH/RemoteTmuxManager.swift`
- `VVTerm/Services/SSH/RemoteMoshManager.swift`
- `VVTerm/Services/Stats/ServerStatsCollector.swift`
- `VVTerm/Services/Stats/Platforms/PlatformStatsCollector.swift`
- `VVTerm/Services/Stats/Platforms/WindowsStatsCollector.swift`
- `VVTerm/Views/Terminal/SSHTerminalWrapper.swift`
- `VVTerm/Views/Splits/TerminalView.swift`

## Testing Plan

### Unit tests
- startup launch plan selection by shell profile
- shell-specific startup command wrapping
- shell-specific cwd restore command generation
- tmux/mosh capability gating by profile
- remote shell detection fallback logic
- upgrade-compatibility tests for existing POSIX launch behavior
- fallback tests for unsupported tmux/mosh combinations

### Regression tests
- existing POSIX startup behavior still works
- existing tmux behavior still works on Unix targets
- PowerShell startup does not use POSIX shell wrappers
- Windows cwd restore uses PowerShell-safe path handling
- Windows stats collection still works
- Unix stats collection still works
- remote platform resolution remains consistent between terminal and stats paths
- unsupported tmux/mosh combinations fall back to plain SSH without UI breakage
- mosh fallback preserves saved connection mode while exposing SSH fallback in active session state
- unknown Windows shell resolution degrades safely without shell-specific cwd restore
- Nushell hosts keep POSIX startup/tmux/mosh behavior

### Manual tests
- macOS/Linux host with `bash`, `zsh`, and `fish`
- Windows OpenSSH host with Windows PowerShell
- Windows OpenSSH host with `pwsh`
- Windows host with PowerShell unavailable and fallback to `cmd.exe`

## Rollout
1. Land the profile abstraction without behavior changes for existing POSIX shells.
2. Move current PowerShell fixes and current stats platform assumptions onto the new abstraction.
3. Enable profile-based startup for all standard SSH sessions.
4. Verify stats collection against the shared remote platform model.
5. Defer `cmd.exe` and `nushell` enhancements until demand justifies them.

## Risks and Mitigations
- Risk: overengineering the abstraction before enough shells are implemented.
  - Mitigation: keep the profile interface narrow and focused on current cross-cutting behaviors.
- Risk: shell detection adds connection latency.
  - Mitigation: prefer known platform signals and short-circuit where possible.
- Risk: tmux/mosh regressions on Unix flows.
  - Mitigation: add capability-gated tests and keep POSIX profile behavior unchanged in V1.
- Risk: unclear behavior for unknown shells.
  - Mitigation: fall back conservatively and disable advanced features instead of guessing.
- Risk: capability-based handling accidentally changes the UI contract for existing users.
  - Mitigation: keep settings visible and apply fallback only at runtime.

## Open Questions
- Should remote shell preference ever be user-overridable per server?
- Should PowerShell V1 target `powershell`, `pwsh`, or both equally?
- Should `cmd.exe` be explicitly selectable, or only used as a last-resort fallback?
- Do we want to expose remote shell capability state in UI or logs for debugging?
