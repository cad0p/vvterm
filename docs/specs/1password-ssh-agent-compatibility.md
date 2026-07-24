# 1Password SSH Agent Compatibility Integration (Draft Spec)

## Summary
Add macOS support for authenticating SSH sessions with the 1Password SSH agent, while staying compatible with App Sandbox and App Store distribution requirements.

Draft date: 2026-02-26

## Problem
VVTerm currently authenticates with passwords or private keys stored in Keychain. Users who keep keys in 1Password want agent-based signing instead of importing private keys.

The main constraint is sandboxing: the 1Password agent socket is outside the app container by default, so direct path assumptions are risky for App Store builds.

## Goals (V1)
- Authenticate SSH sessions via 1Password SSH agent on macOS.
- Keep App Sandbox enabled and App Store-safe.
- Avoid temporary-exception entitlements for file paths.
- Preserve existing password/key/passphrase flows.
- Keep CloudKit server schema stable in V1.

## Non-Goals (V1)
- iOS 1Password agent integration.
- Agent forwarding.
- Multi-agent provider management.
- Changing host key verification behavior.

## Investigation Findings

### 1Password behavior
- 1Password documents both `IdentityAgent` and `SSH_AUTH_SOCK` integration styles.
- The official macOS examples point to:
  - `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`
  - optional symlink `~/.1password/agent.sock`
- 1Password compatibility docs state:
  - `IdentityAgent` usually takes precedence over `SSH_AUTH_SOCK` when both are supported.
  - OpenSSH is compatible.
  - Termius and Xcode are listed as not compatible.

### Apple sandbox constraints
- App Sandbox restricts filesystem access to the app container, app group containers, world-readable locations, and user-intent-selected files/folders.
- `com.apple.security.files.user-selected.read-write` allows read/write access to files selected via Open/Save panels.
- Temporary exception entitlements exist, but Apple documents them as temporary exception mechanisms that require explicit App Store Connect justification.

### Current VVTerm state
- macOS target has `com.apple.security.app-sandbox` and network entitlements enabled.
- It does not currently include user-selected file/bookmark entitlements.
- SSH auth is centralized in `SSHSession.authenticate()`.
- Bundled `libssh2` includes agent APIs, including `libssh2_agent_set_identity_path`.

## Proposed Design (V1)

### 1) Keep synced server schema unchanged
Use local-only agent binding metadata keyed by `serverId` instead of adding a new synced `AuthMethod` value in V1.

Rationale:
- avoids CloudKit enum/version break risk.
- keeps iOS behavior unchanged.
- path/bookmark is machine-local anyway.

Proposed local model (`macOS` only):
- `SSHAgentBinding`
  - `serverId: UUID`
  - `provider: onePassword`
  - `enabled: Bool`
  - `bookmarkData: Data`
  - `displayPath: String`
  - `updatedAt: Date`

Storage:
- local-only, not synced (UserDefaults or local secure store).

### 2) Add sandbox-safe path authorization flow
macOS entitlements to add:
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope`

User flow:
1. In server auth UI (macOS), user enables `Use 1Password SSH Agent`.
2. User selects socket file or socket directory via `NSOpenPanel`.
3. App stores a security-scoped bookmark.
4. On connect, app resolves bookmark and starts security-scoped access before touching socket path.

Path resolution behavior:
- If selected URL is directory, append `agent.sock`.
- If selected URL is file/socket, use it directly.
- If stale/missing, surface re-authorize prompt.

### 3) SSH auth execution in libssh2
When agent binding is enabled for a server:
1. Resolve authorized socket path.
2. In `SSHSession.authenticate()`, run libssh2 agent auth before private-key fallback:
   - `libssh2_agent_init`
   - `libssh2_agent_set_identity_path`
   - `libssh2_agent_connect`
   - `libssh2_agent_list_identities`
   - iterate identities with `libssh2_agent_userauth`
3. Always disconnect/free agent handles.

Fallback policy:
- if agent auth fails and server has a local key configured, fall back to existing key flow.
- if no local key exists, fail with actionable agent error.

### 4) UI updates
In `ServerFormSheet` on macOS when auth method is key-based:
- Toggle: `Use 1Password SSH Agent`.
- Status row: selected socket path and validation state.
- Button: `Select Agent Socket...`.
- Help text linking to 1Password SSH setup docs.

No UI changes on iOS for V1.

### 5) Error model
Add SSH errors for agent-specific failures:
- socket path not authorized
- socket missing/unreachable
- no identities from agent
- agent auth rejected
- 1Password not available/unlocked

All errors must include concrete recovery actions.

## Security and App Store Compliance
- No private key material is imported from 1Password.
- No home-relative temporary-exception path entitlements in V1.
- Access to socket path is granted via explicit user intent (open panel) and scoped bookmarks.
- Existing sandbox/network posture remains intact.

## Testing Plan

### Unit tests
- Bookmark resolution and stale bookmark handling.
- Directory vs file socket path normalization.
- Agent-first then private-key fallback behavior.

### Manual integration tests (macOS sandbox build)
- Connect using 1Password agent after selecting socket path.
- Relaunch app and reconnect without re-selecting path.
- Handle deleted/moved socket path with recovery prompt.
- Verify password/key flows still work.

### Regression tests
- iOS unchanged behavior.
- CloudKit sync unchanged for server model.

## Rollout
1. Implement behind feature flag: `onePasswordAgentAuthEnabled` (macOS only).
2. Internal dogfood and TestFlight validation.
3. Enable by default after sandbox and reliability validation.

## Risks and Mitigations
- Risk: socket file selection may be inconsistent in file picker.
  - Mitigation: support selecting containing directory and auto-append `agent.sock`.
- Risk: agent unavailable/locked during connection.
  - Mitigation: explicit error and retry guidance.
- Risk: fallback ambiguity for users with both local key and agent.
  - Mitigation: deterministic order (agent first), clear UI copy.

## Open Questions
- Should V1 require directory selection only (instead of file/socket) for reliability?
- Should fallback to local key be configurable per server?
- Should we add a future synced auth enum once all active clients are updated?

## References
- 1Password SSH get started: https://developer.1password.com/docs/ssh/get-started/
- 1Password SSH client compatibility: https://developer.1password.com/docs/ssh/agent/compatibility/
- 1Password SSH advanced use cases: https://developer.1password.com/docs/ssh/agent/advanced/
- Apple App Sandbox overview: https://developer.apple.com/documentation/security/app-sandbox
- Apple entitlement `com.apple.security.app-sandbox`: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.app-sandbox
- Apple entitlement `com.apple.security.network.client`: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client
- Apple entitlement `com.apple.security.files.user-selected.read-write`: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write
- Apple App Sandbox temporary exceptions: https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html
- Apple enabling App Sandbox (security-scoped bookmarks guidance): https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html
