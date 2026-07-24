# Windows psmux tmux Support (Draft Spec)

## Summary

Add Windows tmux-compatible session persistence in VVTerm by supporting [psmux](https://github.com/psmux/psmux) as the Windows tmux runtime.

VVTerm already has shell-aware SSH startup for Windows, but it still treats tmux as a Unix-only capability. psmux changes that assumption: it exposes a tmux-compatible CLI on native Windows and ships `psmux.exe`, `pmux.exe`, and `tmux.exe` aliases. The implementation should keep the existing Unix tmux behavior intact while adding a separate Windows psmux backend with Windows-safe probing, config writing, quoting, attach/create, install, cleanup, and current-path commands.

Research date: 2026-06-03.

## Goals

- Support tmux-style VVTerm-managed sessions on Windows OpenSSH hosts when psmux is installed.
- Preserve existing Unix tmux behavior and all mosh fallback behavior.
- Keep saved server settings unchanged; runtime support is detected per connection.
- Reuse the existing tmux user flows: ask/attach/create/skip, managed session names, cleanup, status, and install action.
- Keep psmux support behind backend-specific command generation instead of adding Windows branches throughout UI code.
- Support Windows default shells used by VVTerm today:
  - PowerShell 5 (`powershell`)
  - PowerShell 7 (`pwsh`)
  - `cmd.exe`

## Non-Goals

- Windows mosh support.
- Replacing psmux with a bundled binary.
- Replacing the Unix tmux implementation.
- Full control-mode integration in VVTerm.
- Importing or editing the user's own `.tmux.conf`.
- Fixing psmux upstream rendering issues.

## Research Findings

### psmux project state

GitHub metadata from `gh repo view psmux/psmux`:

- Repository: `psmux/psmux`
- URL: `https://github.com/psmux/psmux`
- License: MIT
- Description: native tmux-compatible multiplexer for Windows PowerShell, Windows Terminal, `cmd.exe`, and `pwsh`
- Default branch: `master`
- Latest release checked: `v3.3.5`
- Latest release published: 2026-05-28
- Latest push observed: 2026-05-31

Release `v3.3.5` ships:

- portable zip builds for Windows x64, x86, and ARM64
- NSIS setup executables for Windows x64, x86, and ARM64
- `psmux.exe`
- `pmux.exe`
- `tmux.exe` alias for tmux compatibility

Documented install paths:

- `scoop bucket add psmux https://github.com/psmux/scoop-psmux && scoop install psmux`
- `choco install psmux`
- `winget install marlocarlo.psmux`
- `cargo install psmux`
- PowerShell install script: `irm https://raw.githubusercontent.com/psmux/psmux/master/scripts/install.ps1 | iex`

### psmux tmux compatibility relevant to VVTerm

psmux claims and implements the tmux CLI surface VVTerm currently depends on:

- `new-session`
- `attach-session`
- `has-session`
- `kill-session`
- `list-sessions`
- `list-panes`
- `source-file`
- `set-option`
- `set-environment`
- `show-options`
- `-f <config>`
- `-L <namespace>`
- `-C` / `-CC` control mode

The documented command reference includes the key flags VVTerm uses:

- `new-session -A -s <name> -c <dir>`
- `attach-session -t <target>`
- `has-session -t <target>`
- `kill-session -t <target>`
- `list-sessions -F <format>`
- `list-panes -t <target> -F '#{pane_current_path}'`
- `source-file <path>`

psmux supports tmux-style format variables, including session/window/pane values and `#{pane_current_path}`. Its docs also state the session server survives SSH disconnects. Issue `#187` confirms an SSH disconnect bug was fixed by breaking the psmux server process away from the Windows OpenSSH Job Object.

### Important psmux caveats

- `psmux -V`, `pmux -V`, and `tmux -V` intentionally print `tmux <version>` for compatibility. VVTerm should not rely on `tmux -V` output to distinguish real tmux from psmux.
- psmux reads config from `~/.psmux.conf`, `~/.psmuxrc`, `~/.tmux.conf`, and `~/.config/psmux/psmux.conf`, but VVTerm should pass its own generated config with `-f`.
- psmux supports `terminal-overrides` as a compatibility no-op. `terminal-features` is not a first-class option in the current source, but psmux stores unknown hyphenated tmux options in `user_options` instead of failing or injecting them as environment variables. VVTerm may include it for config parity, but must not depend on it for behavior.
- psmux documents that `alternate_on` is always false because ConPTY consumes alternate-screen transitions. VVTerm's current Unix tmux mouse-scroll binding uses `#{alternate_on}`, so Windows psmux must not reuse that binding unchanged.
- psmux does not currently support tmux-style `WheelUpPane` / `WheelDownPane` bindings; issue `#193` added `scroll-enter-copy-mode` as the supported scroll customization path instead.
- psmux supports `allow-set-title`, `set-titles`, `set-titles-string`, and `#{pane_title}`. Issue `#231` fixed OSC 0/2 propagation into `pane_title` for state queries. PowerShell 7 sends OSC 0 with the current working directory on every prompt when title propagation is allowed.
- Mouse over SSH requires a Windows 11 server build 22523+ for full mouse support. Keyboard and session persistence should still work without that.
- Issue `#73` remains open for mangled output in at least one Windows Server SSH setup. VVTerm should validate Windows Server explicitly before release and keep plain SSH fallback reliable when psmux cannot be used.

## Current VVTerm State

Relevant files:

- `VVTerm/Core/SSH/RemoteEnvironmentResolver.swift`
- `VVTerm/Core/SSH/RemoteTerminalBootstrap.swift`
- `VVTerm/Core/SSH/RemoteTmuxManager.swift`
- `VVTerm/Core/SSH/SSHClient.swift`
- `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- `VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift`
- `VVTerm/Features/TerminalSessions/Application/TmuxAttachResolver.swift`
- `VVTermTests/RemoteEnvironmentTests.swift`
- `VVTermTests/RemoteTmuxManagerParserTests.swift`

Current blockers:

- `RemoteEnvironment.supportsTmuxRuntime` returns false for Windows.
- Tests explicitly assert Windows PowerShell disables tmux and mosh.
- `RemoteTmuxManager` builds commands with POSIX-only assumptions:
  - `sh -lc`
  - `sh -c`
  - `command -v`
  - `export PATH=...`
  - `mkdir -p`
  - `printf`
  - `$HOME`
  - `uname -s`
  - `exec`
  - POSIX single-quote escaping
- The generated config path is Unix-shaped: `~/.vvterm/tmux.conf`.
- The install script only knows Unix package managers and macOS package managers.

This means Windows psmux support should not be implemented by flipping `supportsTmuxRuntime` to true. That would route Windows through POSIX command construction and keep failing.

## Proposed Design

### 1) Add an explicit multiplexer backend

Introduce a small backend model near the SSH infrastructure:

```swift
enum RemoteTmuxBackend: Hashable, Sendable {
    case unixTmux
    case windowsPsmux(commandName: String, shellFamily: RemoteShellFamily, powerShellExecutable: String?)
}
```

Better names are acceptable, but the model must distinguish:

- whether the remote shell can run a tmux-compatible runtime
- which executable should be called
- which command quoting rules apply
- which generated config path should be used
- whether install is Unix tmux or Windows psmux

Do not encode psmux as a fake POSIX tmux. It is protocol-compatible at the CLI layer, not shell-compatible at the bootstrap layer.

### 2) Split command generation from `RemoteTmuxManager`

Extract command construction behind a backend-aware builder:

```swift
struct RemoteTmuxCommandBuilder {
    let backend: RemoteTmuxBackend

    func availabilityProbe(okMarker: String) -> String
    func listSessionsCommand() -> String
    func prepareConfigCommand(terminalType: RemoteTerminalType) -> String
    func attachOrCreateCommand(sessionName: String, workingDirectory: String, context: RemoteTmuxManager.CommandContext) -> String
    func attachExistingCommand(sessionName: String, context: RemoteTmuxManager.CommandContext) -> String
    func killSessionCommand(sessionName: String) -> String
    func currentPathCommand(sessionName: String) -> String
    func installAndAttachScript(sessionName: String, workingDirectory: String, terminalType: RemoteTerminalType) -> String
}
```

The existing POSIX implementation can move into `.unixTmux` with minimal behavior change. The Windows implementation should generate PowerShell or cmd syntax directly.

### 3) Resolve psmux availability separately from shell support

Update runtime gating semantics:

- Unix POSIX profile: tmux runtime can be probed.
- Windows PowerShell profile: psmux runtime can be probed.
- Windows cmd profile: psmux runtime can be probed.
- Unknown Windows shell: do not probe unless PowerShell is available and VVTerm can run a PowerShell exec command safely.
- Windows mosh remains unsupported.

The availability probe should prefer an explicit psmux executable:

1. `psmux`
2. `pmux`
3. confirmed psmux-compatible `tmux` alias

On Windows, `psmux` or `pmux` should win over any `tmux.exe` on `PATH`. This is intentional even if `tmux.exe` appears earlier in `PATH`: an unrelated Cygwin/MSYS/Git-for-Windows `tmux.exe` is not the native Windows psmux backend and may have different shell, path, process, or persistence assumptions.

Use `tmux` on Windows only as an alias fallback after a psmux-specific compatibility probe succeeds. A robust probe can combine:

- `tmux -V` exits successfully
- `tmux list-commands` includes a psmux extension such as `dump-state` or `claim-session`
- a short detached-session smoke command works with Windows paths and psmux-compatible flags

If `tmux` is found but cannot be identified as psmux-compatible, treat the Windows tmux runtime as unavailable and keep plain SSH fallback behavior.

For PowerShell:

```powershell
$cmd = Get-Command psmux,pmux -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cmd) {
  & $cmd.Source -V | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Output "__VVTERM_TMUX_OK__" }
}
```

For `cmd.exe`:

```cmd
where psmux >NUL 2>NUL && psmux -V >NUL 2>NUL && echo __VVTERM_TMUX_OK__
where pmux >NUL 2>NUL && pmux -V >NUL 2>NUL && echo __VVTERM_TMUX_OK__
```

`tmux` fallback should be implemented as a separate confirmed-alias probe, not as part of the first-pass availability check.

### 4) Use a Windows VVTerm config path

Use a VVTerm-owned generated config file:

- PowerShell path: `$HOME\.vvterm\psmux.conf`
- cmd path: `%USERPROFILE%\.vvterm\psmux.conf`

Always pass it through psmux's `-f` flag:

```powershell
& $psmux -f "$HOME\.vvterm\psmux.conf" attach-session -t "=vvterm_..."
```

This avoids modifying or depending on the user's `~/.tmux.conf`.

The config writer needs a Windows implementation:

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\.vvterm" | Out-Null
@'
...tmux config...
'@ | Set-Content -Encoding UTF8 -NoNewline "$HOME\.vvterm\psmux.conf"
```

For cmd, prefer invoking PowerShell for the config write if available. If PowerShell is unavailable, use a simpler cmd-safe `>` writer or skip config generation and log that only default psmux config is active.

### 5) Audit the generated config before reuse

The existing generated tmux config includes useful portable lines:

- `set-environment`
- `terminal-features`
- `terminal-overrides`
- `set -g allow-passthrough on`
- `set -g allow-set-title on`
- `set -g set-titles on`
- `set -g set-titles-string "#{pane_title}"`
- `set -g status off`
- `set -g history-limit 10000`
- `set -g mouse on`
- `set -g default-terminal "..."`
- `set -g mode-style "..."`

The Windows psmux variant must audit or change:

- `terminal-features`: psmux stores it as an unknown hyphenated option and does not fail, so it can stay for config parity, but VVTerm must not rely on it for hyperlink or terminal capability behavior.
- `terminal-overrides`: safe compatibility no-op.
- mouse scroll bindings using `#{alternate_on}`: do not reuse unchanged because psmux documents `alternate_on` as always false and does not support `WheelUpPane` / `WheelDownPane` key bindings today.
- `allow-set-title on`: keep it in the VVTerm-managed psmux config to preserve the existing VVTerm tmux behavior where the active pane title can propagate to the outer terminal title. Accept that PowerShell 7 will usually make that title the current working directory. This is less harmful in VVTerm because the psmux status bar is hidden; if the resulting outer title is noisy, handle that as a targeted follow-up rather than disabling title propagation in V1.

V1 should use a Windows config that is as close to the Unix tmux config as psmux supports:

- keep status hidden
- keep history limit
- keep mouse enabled
- keep mode style
- keep terminal type
- keep terminal metadata and update-environment lines
- keep title propagation
- include `terminal-features` / `terminal-overrides` for parity, but treat them as best-effort/no-op under psmux
- skip the custom WheelUp/WheelDown bindings in V1
- use psmux's built-in scroll behavior and `scroll-enter-copy-mode` option instead of custom wheel bindings

### 6) Build Windows attach/create commands

Use psmux's tmux-compatible commands but Windows-safe quoting.

PowerShell attach-or-create shape:

```powershell
$s = 'vvterm_session'
$exact = '=' + $s
if (& $psmux -f $config has-session -t $exact 2>$null) {
  & $psmux -f $config source-file $config 2>$null
  & $psmux -f $config attach-session -t $exact
} elseif (& $psmux -f $config has-session -t $s 2>$null) {
  & $psmux -f $config source-file $config 2>$null
  & $psmux -f $config attach-session -t $s
} else {
  & $psmux -f $config new-session -A -s $s -c $workingDirectory
}
```

cmd attach-or-create can call `psmux` directly, but PowerShell is the preferred implementation because quoting Windows paths and exact session targets is safer.

Startup exec behavior:

- For PowerShell remotes, `RemoteTerminalBootstrap.wrapPowerShellCommand` can encode the psmux startup script.
- For cmd remotes, either generate native cmd syntax or use `powershell -EncodedCommand` when `powerShellExecutable` was detected.
- Do not use POSIX `exec`; just let the psmux process become the foreground process for that SSH channel.

### 7) Preserve session selection and cleanup behavior

Keep using existing `TmuxAttachResolver` behavior:

- ask every time
- create managed session
- attach last selected session
- skip tmux
- cleanup detached VVTerm-managed sessions

The parser for `list-sessions -F '#{session_name} #{session_attached} #{session_windows}'` should remain valid for psmux.

Cleanup on Windows should use:

```powershell
& $psmux list-sessions -F '#{session_name} #{session_attached}' |
  ForEach-Object { ... } # filter vvterm prefix and attached count
```

But V1 can avoid a complex pipeline by reusing existing Swift-side filtering:

1. call `listSessions(using:)`
2. filter in Swift by prefix and `attachedClients == 0`
3. call `killSession(named:)`

This is already how `cleanupDetachedSessions` works and is safer than writing shell-specific filters.

### 8) Add Windows psmux install support

When psmux is missing on Windows and the user taps the existing install action, VVTerm should run a Windows psmux install script instead of the Unix tmux package-manager script.

Preferred install order:

1. `winget install --id marlocarlo.psmux --accept-package-agreements --accept-source-agreements`
2. `scoop bucket add psmux https://github.com/psmux/scoop-psmux; scoop install psmux`
3. `choco install psmux -y`
4. `cargo install psmux`

The `irm ... | iex` installer should not be the automatic default. It can be documented or offered only as an explicit last resort because it executes a remote script.

After install, rerun the psmux availability probe and attach if available, mirroring the current tmux install flow.

## UX

V1 should keep the normal tmux UX. psmux intentionally markets itself as a tmux-compatible Windows runtime, ships a `tmux.exe` alias, and supports the tmux CLI surface VVTerm needs. Existing VVTerm UI copy, settings, prompts, and localized strings should continue saying "tmux" wherever they describe the feature generically.

Mention "psmux" only where the user needs platform-specific action or diagnostics:

- Missing/install explanation on Windows: "psmux is required for tmux-compatible sessions on Windows."
- Install action on Windows: "Install psmux"
- Logs/diagnostics: "Using psmux for tmux-compatible session persistence."

Do not rename the feature to "psmux" in settings, the attach prompt, session persistence copy, or tab/session status. That would create unnecessary user-facing divergence from Unix tmux and would churn localized strings. The backend distinction should be implementation detail unless something is missing or failed.

Do not hide the tmux setting for Windows hosts. Keep the existing runtime fallback behavior:

- if psmux is available, use it
- if psmux is missing, show missing status
- if the shell/runtime is unsupported, fall back to plain SSH without mutating saved server settings

Do not gate Windows psmux support behind a user-facing feature flag. Ship it behind runtime backend detection and safe fallback. A private development flag or kill switch is acceptable during implementation and test builds, but production UX should be "tmux works on Windows when psmux is installed."

## Implementation Plan

### Phase 1: Backend model and command builder

- Add `RemoteTmuxBackend`.
- Move POSIX command construction into backend-aware builder methods.
- Keep generated POSIX commands byte-for-byte equivalent where practical.
- Update `RemoteTmuxManager` to resolve a backend before building commands.
- Add unit tests for POSIX command stability.

### Phase 2: Windows psmux detection

- Treat Windows PowerShell and cmd as tmux-probe-capable profiles.
- Add psmux availability probes for PowerShell and cmd.
- Prefer `psmux`, then `pmux`.
- Accept `tmux` on Windows only after confirming it is the psmux-compatible alias or otherwise passes a psmux-specific smoke probe.
- Update tests that currently assert Windows PowerShell disables tmux.
- Keep Windows mosh tests disabled.

### Phase 3: Windows psmux config and attach

- Add PowerShell-safe config writer.
- Add psmux attach/create/existing attach command generation.
- Add psmux list/kill/current-path command generation.
- Skip or adjust config lines known to be risky under psmux.
- Verify parser compatibility with psmux `list-sessions -F` output.

### Phase 4: Install action

- Add Windows psmux install script generation.
- Wire install action to choose Unix tmux vs Windows psmux by resolved environment.
- Reprobe after install.
- Add tests for install script selection.

### Phase 5: Manual validation and polish

- Validate against Windows 11 + PowerShell 7.
- Validate against Windows 11 + Windows PowerShell 5.
- Validate against Windows 11 + cmd default shell.
- Validate against Windows Server OpenSSH because psmux issue `#73` is still open.
- Validate Windows 10 behavior with keyboard/session persistence, accepting limited SSH mouse support.

## Test Plan

### Unit tests

- Windows PowerShell environment can probe tmux-compatible runtime.
- Windows cmd environment can probe tmux-compatible runtime.
- Windows unknown shell still does not attempt tmux unless a safe PowerShell command path exists.
- POSIX environment keeps Unix tmux support.
- Windows mosh remains unsupported.
- psmux availability probe prefers `psmux` over `pmux` over `tmux`.
- Windows `tmux.exe` is rejected when it cannot be confirmed as psmux-compatible.
- psmux config path is Windows-shaped and VVTerm-owned.
- psmux attach/create command contains no `sh -lc`, `export`, `mkdir -p`, `printf`, `uname`, or POSIX `exec`.
- psmux session parser accepts expected `list-sessions -F` output.
- psmux current-path command uses `list-panes -F '#{pane_current_path}'`.
- Windows psmux config includes title propagation and omits unsupported WheelUp/WheelDown bindings.

### Integration tests

- SSH to Windows host with psmux installed:
  - create managed session
  - disconnect/reconnect
  - attach existing managed session
  - attach user-selected psmux session
  - cleanup detached VVTerm-managed sessions
  - current working directory restore from psmux pane path
- SSH to Windows host without psmux:
  - status becomes missing
  - plain SSH remains usable
  - saved tmux setting is not changed
- Install psmux through at least one package manager and attach after reprobe.

### Manual acceptance

- Windows 11 22H2+ with `pwsh`.
- Windows 11 22H2+ with `powershell`.
- Windows 11 22H2+ with `cmd.exe`.
- Windows Server 2022 OpenSSH.
- Windows 10 OpenSSH.
- Existing Linux/macOS tmux host regression pass.

## Resolved Decisions

- Keep the normal tmux UX. Use "psmux" only for Windows install/missing copy and diagnostics.
- Prefer explicit `psmux` / `pmux` over any `tmux.exe` on Windows. Accept `tmux.exe` only after a psmux-specific alias probe succeeds.
- Keep most VVTerm-generated tmux config parity. `terminal-features` is accepted/stored by psmux as an unknown hyphenated option, but should be treated as best-effort/no-op under psmux.
- Keep `allow-set-title on` and `set-titles on` for VVTerm-managed psmux sessions. PowerShell 7 CWD titles are acceptable for V1 because VVTerm hides the psmux status bar and uses title propagation for outer terminal metadata.
- Do not hide Windows psmux support behind a user-facing feature flag. Use runtime detection, safe fallback, and manual Windows Server validation before release.

## Remaining Unknowns

- Whether Windows Server issue `#73` reproduces in VVTerm/Ghostty specifically.
- Whether psmux should grow first-class `terminal-features` handling upstream; VVTerm does not need to block on this.
- Whether a later release should add a user-facing "backend details" diagnostic panel for tmux/psmux/mosh runtime choices.

## References

- psmux repository: `https://github.com/psmux/psmux`
- psmux latest release checked: `https://github.com/psmux/psmux/releases/tag/v3.3.5`
- psmux compatibility docs: `https://github.com/psmux/psmux/blob/master/docs/compatibility.md`
- psmux configuration docs: `https://github.com/psmux/psmux/blob/master/docs/configuration.md`
- psmux multi-shell docs: `https://github.com/psmux/psmux/blob/master/docs/multi-shell.md`
- psmux control mode docs: `https://github.com/psmux/psmux/blob/master/docs/control-mode.md`
- psmux mouse over SSH docs: `https://github.com/psmux/psmux/blob/master/docs/mouse-ssh.md`
- psmux SSH disconnect issue: `https://github.com/psmux/psmux/issues/187`
- psmux Windows Server SSH output issue: `https://github.com/psmux/psmux/issues/73`
- psmux mouse scroll issue: `https://github.com/psmux/psmux/issues/193`
- psmux OSC pane title issue: `https://github.com/psmux/psmux/issues/231`
- Existing VVTerm shell profile spec: `docs/specs/remote-shell-profiles.md`
