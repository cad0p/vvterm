# VVTerm

Cross-platform (iOS/macOS) SSH terminal app with iCloud sync and Keychain credential storage.

## Target Versions

- **macOS**: 13.3+ (Ventura), arm64 only
- **iOS**: 16.1+, arm64 only
- **Xcode**: 16.0+

## Architecture

```
VVTerm/
├── App/
│   ├── VVTermApp.swift           # App entry point and composition root
│   ├── ContentView.swift         # Shared root container
│   ├── Localization/             # App-scoped localization preferences
│   └── iOS/                      # iOS app shell and root navigation views
├── Core/                         # Shared infrastructure and platform glue
│   ├── Logging/
│   ├── Network/
│   ├── UI/
│   ├── SSH/
│   ├── Security/
│   ├── Sync/
│   └── Terminal/
├── Features/                     # Feature-first product features
│   ├── ConnectionViews/
│   │   ├── Domain/
│   │   └── Application/
│   ├── LocalDiscovery/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── Servers/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── RemoteFiles/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── VoiceInput/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── Security/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── Settings/
│   │   ├── Application/
│   │   └── UI/
│   ├── Store/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── Support/
│   │   └── UI/
│   ├── TerminalThemes/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── TerminalAccessories/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── TerminalPresets/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── TerminalSessions/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── Stats/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   └── Welcome/
│       ├── Domain/
│       └── UI/
├── GhosttyTerminal/              # libghostty terminal emulation
├── Compatibility/                # Version/platform compatibility helpers
├── Generated/                    # Build-time generated sources
└── Resources/                    # Bundled assets, themes, terminfo, l10n
```

## Architecture Direction

VVTerm uses a **feature-first architecture** for app-owned source code.

Current architecture:
- `App` owns app entry, composition roots, shared root containers, localization preferences, and iOS app-shell navigation.
- `Core/Sync` owns CloudKit sync infrastructure.
- `Core/Security` owns keychain, device identity, and privacy-mode infrastructure.
- `Core/Network` owns shared connectivity monitoring and Cloudflare transport support.
- `Core/UI` owns shared view primitives and presentation helpers reused across features.
- `Core/Terminal` owns shared clipboard, paste, and terminal text/default helpers.
- `Core/Logging` owns shared logging utilities.
- `Core/SSH` owns shared SSH bootstrap, known-hosts, key generation, environment detection, rich-paste support, tmux/mosh runtime helpers, and `SSHClient`.
- `Features/ConnectionViews` owns connection view tab configuration types and state.
- `Features/RemoteFiles` owns remote file browsing, preview, transfer, and SFTP integration.
- `Features/LocalDiscovery` owns discovery-specific code and UI.
- `Features/Servers` owns server/workspace domain models, server management, and server/workspace UI flows.
- `Features/Stats` owns server metrics collection and presentation.
- `Features/Security` owns app lock and biometric authentication flows.
- `Features/Settings` owns settings window presentation and settings screens.
- `Features/Store` owns Pro entitlements, purchases, and upgrade surfaces.
- `Features/Support` owns support/contact UI surfaces.
- `Features/TerminalThemes` owns theme models, validation, storage paths, parsing, and theme management.
- `Features/TerminalAccessories` owns keyboard accessory models, preferences, settings UI, and accessory validation flows.
- `Features/TerminalPresets` owns terminal preset models, persistence, and preset form UI.
- `Features/TerminalSessions` owns terminal session/tab domain models, session/tab managers, tmux prompt coordination, live activity support, and terminal session UI.
- `Features/VoiceInput` owns transcription/audio capture infrastructure, MLX model management, and transcription settings UI.
- `Features/Welcome` owns welcome/onboarding copy and presentation.
- New app code should land in `Features`, `Core`, or `App` based on ownership.
- New work inside a feature should stay inside its `Features/<FeatureName>` subtree and should not reintroduce app-wide bucket folders.

Feature-first shape:
- `Domain`: pure feature types and rules
- `Application`: feature state, orchestration, coordinators, use-case style logic
- `Infrastructure`: transport, persistence, adapters, external integrations
- `UI`: SwiftUI/AppKit/UIKit presentation only

For Files/SFTP specifically:
- no non-view logic under `UI`
- no feature policy inside `SSHClient` beyond low-level transport/session behavior
- use explicit dependency injection at the feature boundary
- do direct cutovers, not compatibility shims

For every feature:
- keep `Domain`, `Application`, `Infrastructure`, and `UI` boundaries intact
- prefer view-owned dependencies to be injected from the app/screen boundary instead of created inside leaf views
- if shared cross-feature primitives are needed, extract them into `Core` instead of creating new app-wide bucket folders

## Refactoring Rules

When doing architectural refactors:
- prioritize structural splits and ownership cleanup over behavior changes
- preserve existing UI, UX, and visual behavior unless the user explicitly asks for a change
- do not bundle redesigns or new features into a refactor
- keep platform parity intact unless a platform-specific bug is being fixed
- if a behavior change is necessary for correctness or safety, keep it minimal and isolated

Safe refactor expectation:
- same screens
- same entry points
- same interactions
- same user-facing flows
- smaller files, clearer boundaries, better ownership

## Commits

- Use **atomic commits**.
- Each commit must represent one coherent change that can be reviewed and reverted independently.
- Do not mix architecture docs, code moves, behavioral fixes, and unrelated cleanup in one commit unless they are inseparable.
- Prefer a sequence such as:
  - architecture/spec update
  - domain extraction
  - application/store extraction
  - infrastructure extraction
  - UI split
  - targeted safety fix
- Before committing, verify the diff matches a single intent.

## Key Components

### Terminal
- Uses **libghostty** (Ghostty terminal emulator) via xcframework
- Metal GPU rendering (arm64 only)
- iOS keyboard toolbar with special keys (Esc, Tab, Ctrl, arrows)

### SSH
- **libssh2** + **OpenSSL** for SSH connections
- Auth methods: Password, SSH Key, Key+Passphrase
- Credentials stored in Keychain

### Data Sync
- **CloudKit** for server/workspace sync across devices
- Container: `iCloud.it.pcad.vvterm`
- Local fallback via UserDefaults

### Pro Tier (StoreKit 2)
- Free: 1 workspace, 1 server, 1 tab
- Pro: Unlimited everything
- Products: Monthly ($6.49), Yearly ($24.99), Lifetime ($49.99)

## Build Dependencies

### libghostty
Pre-built xcframework at `Vendor/libghostty/GhosttyKit.xcframework`
Build with: `./scripts/build.sh ghostty`

### libssh2 + OpenSSL
Build with: `./scripts/build.sh ssh`
Output: `Vendor/libssh2/{macos,ios,ios-simulator}/`

## Data Models

### Server
```swift
struct Server: Identifiable, Codable {
    let id: UUID
    var workspaceId: UUID
    var environment: ServerEnvironment
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var keychainCredentialId: String
}
```

### Workspace
```swift
struct Workspace: Identifiable, Codable {
    let id: UUID
    var name: String
    var colorHex: String
    var environments: [ServerEnvironment]
    var order: Int
}
```

### ConnectionSession (local only, not synced)
```swift
struct ConnectionSession: Identifiable {
    let id: UUID
    let serverId: UUID
    var title: String
    var connectionState: ConnectionState
}
```

## UI Patterns

### macOS Layout
- NavigationSplitView with sidebar (workspaces/servers) and detail (terminal)
- Toolbar tabs for multiple connections
- `.windowToolbarStyle(.unified)`

### iOS Layout
- NavigationStack with server list
- Full-screen terminal with keyboard toolbar
- Sheet-based forms

### Liquid Glass (iOS 26+ / macOS 26+)
```swift
// Use adaptive helpers for backwards compatibility
.adaptiveGlass()           // Falls back to .ultraThinMaterial
.adaptiveGlassTint(.green) // For semantic tinting
```

## Important Notes

1. **Never apply glass to terminal content** - only navigation/toolbars
2. **Deduplicate by ID** when syncing from CloudKit
3. **Pro limits enforced in**: `ServerManager.canAddServer`, `canAddWorkspace`, `ConnectionSessionManager.canOpenNewTab`
4. **Keychain credentials** are NOT synced - only server metadata syncs via CloudKit
5. **iOS keyboard toolbar** provides Esc, Tab, Ctrl, arrows, function keys
6. **Voice-to-command** uses MLX Whisper/Parakeet on-device or Apple Speech fallback
