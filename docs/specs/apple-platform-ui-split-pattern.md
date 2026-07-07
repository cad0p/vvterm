# Apple Platform UI Split Pattern (Spec)

Status: architecture guardrail and migration plan

Last updated: 2026-07-07

## Summary

VVTerm ships one Apple app target across iOS and macOS. Shared feature code is valuable, but large SwiftUI files have accumulated many inline `#if os(iOS)` and `#if os(macOS)` branches, plus product UI type names such as `iOSServerRow`, `MacOSZenModePanel`, and `StatsMacSearchField`.

This spec defines the preferred pattern for Apple-platform UI code:

- keep shared feature state, policy, and composition in neutral shared files
- move platform-specific UI, lifecycle, AppKit/UIKit bridges, and platform-specific state into platform files
- use file-level compile gates for platform files because folder names do not affect Swift compilation
- avoid `iOS`, `Mac`, `macOS`, and `MacOS` prefixes in product UI names unless the type is a true platform adapter

The goal is behavior-preserving cleanup: same screens, same entry points, same interactions, and same visual intent, with clearer platform ownership.

## Problem

Inline platform branches are currently used for several different reasons:

- selecting different platform layout trees
- importing UIKit or AppKit
- storing platform-only view state
- attaching platform-only modifiers such as importers, sheets, overlays, search, or drop handling
- calling platform services such as `NSOpenPanel`, `NSSavePanel`, `NSAlert`, `NSEvent`, `UIActivityViewController`, or UIKit keyboard/focus APIs
- working around platform-specific SwiftUI presentation behavior

Those are not all equivalent. Small presentation differences can remain local, but platform state and platform lifecycle should not live in the middle of shared views.

Current audit snapshot from the local working tree:

- `233` Swift files total
- `89` Swift files contain platform gates
- `429` platform-gate matches
- `368` platform-gate matches in `App`, `Features`, or `Core/UI`

Highest-noise UI files:

- `VVTerm/Features/Stats/UI/ServerStatsView.swift`: 28 platform gates, about 5036 lines
- `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift`: 25 platform gates, about 2121 lines
- `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`: 22 platform gates, about 965 lines
- `VVTerm/Features/Settings/UI/TerminalSettingsView.swift`: 22 platform gates, about 1940 lines
- `VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift`: 21 platform gates, about 1574 lines
- `VVTerm/Features/Settings/UI/KeychainSettingsView.swift`: 18 platform gates, about 716 lines
- `VVTerm/Features/Store/UI/ProUpgradeSheet.swift`: 16 platform gates, about 1329 lines
- `VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift`: 12 platform gates, about 1335 lines

This spec does not require cleaning every file immediately. It sets the pattern new work should follow and gives a migration order for existing hotspots.

## Goals

- Reduce inline `#if os(...)` branches inside shared SwiftUI view bodies.
- Keep feature-first ownership intact.
- Preserve existing iOS and macOS behavior during refactors.
- Make platform-specific files obvious from filename and compile gate.
- Keep product UI names neutral and feature-owned.
- Keep UIKit/AppKit code out of shared feature views unless it is a tiny unavoidable bridge point.
- Provide a repeatable pattern for future UI splits.

## Non-Goals

- Redesigning UI.
- Changing navigation, sheet flow, menus, shortcuts, or gestures.
- Splitting the Xcode target into separate iOS and macOS targets.
- Removing all `#if os(...)` usage.
- Forcing identical UI across iOS and macOS when native platform behavior should differ.
- Rewriting Ghostty terminal platform views, which are already platform-specific adapter files.

## Source Constraints

### Single Multiplatform Target

The `VVTerm` target supports `iphoneos`, `iphonesimulator`, and `macosx` in one target. The project also uses synchronized filesystem groups, so adding Swift files under `VVTerm/` is normally enough for inclusion.

Implication:

- placing a file in `App/iOS/` or a folder named `macOS` is not enough
- Swift still parses target source files for each SDK build
- platform-only files must use file-level compile gates unless the target structure changes later

Correct:

```swift
#if os(iOS)
import SwiftUI
import UIKit

extension RemoteFileBrowserScreen {
    var platformBody: some View {
        ...
    }
}
#endif
```

Correct:

```swift
#if os(macOS)
import SwiftUI
import AppKit

extension RemoteFileBrowserScreen {
    var platformBody: some View {
        ...
    }
}
#endif
```

Incorrect:

```text
VVTerm/Features/Example/UI/iOS/ExampleView.swift
```

The folder name is useful for humans, but by itself it does not make the file iOS-only.

### Swift Extensions Cannot Add Stored Properties

Platform extension files can add methods, computed properties, nested helper types, and modifiers. They cannot add stored state such as `@State`, `@StateObject`, or `@SceneStorage`.

If a platform needs stored state, use one of these patterns:

1. Move that platform surface into a child `View` in the platform file and let the child own platform state.
2. Move state into a small platform presenter/model owned by a platform child view.
3. Keep a short temporary gated state property in the shared view only during a staged migration, then remove it in the same feature cleanup.

Preferred:

```swift
struct RemoteFileBrowserScreen: View {
    var body: some View {
        platformBody
    }
}
```

```swift
#if os(iOS)
extension RemoteFileBrowserScreen {
    var platformBody: some View {
        PlatformContent(screen: self)
    }
}

private struct PlatformContent: View {
    let screen: RemoteFileBrowserScreen
    @State private var searchQuery = ""

    var body: some View {
        ...
    }
}
#endif
```

This keeps iOS-only `@State` out of the shared screen.

## Definitions

### Shared Feature UI

Shared feature UI is code that should exist for both iOS and macOS:

- feature screen entry point
- dependency injection and shared stores
- common loading lifecycle
- common empty states when visual structure is the same
- common operation orchestration
- common validation and formatted view data
- reusable feature components that are visually equivalent on both platforms

Shared feature UI should use feature and domain names, not platform prefixes.

### Platform Presentation

Platform presentation is SwiftUI code that exists because the platform experience differs:

- `NavigationStack` vs macOS window/split presentation
- iOS bottom toolbar vs macOS toolbar/path bar
- iOS sheet flow vs macOS panel/alert/menu flow
- iOS search and safe-area handling
- macOS table, outline, sidebar, split, or titlebar behavior
- platform-specific keyboard shortcuts or gestures

Platform presentation belongs in platform files next to the feature UI.

### Platform Adapter

A platform adapter directly wraps or coordinates platform frameworks:

- `UIViewRepresentable`
- `NSViewRepresentable`
- `UIViewControllerRepresentable`
- `NSViewControllerRepresentable`
- `UIApplicationDelegate`
- `NSApplicationDelegate`
- `NSToolbarDelegate`, `NSMenuDelegate`, `NSEvent`, `NSOpenPanel`, `NSSavePanel`, `NSAlert`
- Ghostty's native terminal view wrappers

Platform adapters may keep platform names when that makes the boundary honest.

Examples of acceptable platform names:

- `MacShellSplitHost`
- `MacToolbarBridge`
- `MacConnectionToolbarController`
- `MacOSRemoteFileTableView`
- `MacOSWindowTopInsetBridge`
- `GhosttyTerminalView+iOS.swift`
- `GhosttyTerminalView+macOS.swift`

Examples that should move toward neutral product names:

- `iOSServerRow`
- `iOSTerminalTabsBar`
- `iOSRemoteFileTabsBar`
- `MacOSZenModePanel`
- `StatsMacSearchField`
- `StatsMacDetailShell`

## Naming Rules

### Files

Use a shared file plus platform extension files when one type is a cross-platform feature surface:

```text
FeatureScreen.swift
FeatureScreen+iOS.swift
FeatureScreen+macOS.swift
```

For platform adapters where the platform is the point of the file, platform names are acceptable:

```text
MacShellSplitHost.swift
MacToolbarBridge.swift
GhosttyTerminalView+iOS.swift
GhosttyTerminalView+macOS.swift
```

For platform-specific support files under a feature, prefer the subject first and platform last:

```text
RemoteFileBrowserSupport+iOS.swift
RemoteFileBrowserSupport+macOS.swift
TerminalContainerView+iOS.swift
TerminalContainerView+macOS.swift
```

Avoid new files named like:

```text
iOSFeatureScreen.swift
MacFeatureScreen.swift
MacOSFeatureComponents.swift
```

unless they are true platform shell/adapters rather than product UI.

### Types

Use neutral names for product UI:

```swift
ServerRow
TerminalTabsBar
RemoteFileTabsBar
ZenModePanel
SearchField
DetailShell
```

Inside a platform-gated file, private implementation names can be generic:

```swift
private struct PlatformContent: View { ... }
private struct PlatformToolbar: View { ... }
private struct PlatformSearchField: View { ... }
```

If a private type must expose platform semantics, keep it in the platform file and prefer a role name over a platform prefix:

```swift
private struct TitlebarInsetReader: NSViewRepresentable { ... }
private struct TableBridge: NSViewRepresentable { ... }
```

Use platform prefixes only when the type's public job is the platform bridge.

## Compile-Gate Rules

Allowed inline gates in shared files:

- one-line imports when no cleaner file split is justified
- small availability fallbacks such as `#available(iOS 26, macOS 26, *)`
- tiny modifier differences that are easier to read inline than to extract
- temporary gates during an active split, removed before the phase is complete

Prefer extraction when a shared file has:

- platform-specific stored state
- platform-specific lifecycle hooks
- platform-specific view bodies longer than a few lines
- AppKit/UIKit calls
- more than two platform gates in one view body
- repeated `#if os(...)` around related modifiers or sheets
- product UI types with platform prefixes

Do not hide platform divergence behind `AnyView` just to erase type differences. Prefer `@ViewBuilder`, platform child views, or platform extension files.

## Standard Pattern

### Shared Screen

The shared screen owns dependencies and shared lifecycle:

```swift
struct ExampleScreen: View {
    @ObservedObject var store: ExampleStore

    var body: some View {
        platformBody
            .task {
                await store.load()
            }
    }

    func refresh() {
        Task {
            await store.reload()
        }
    }
}
```

The shared screen does not import UIKit or AppKit.

### iOS File

```swift
#if os(iOS)
import SwiftUI
import UIKit

extension ExampleScreen {
    var platformBody: some View {
        PlatformContent(screen: self)
    }
}

private struct PlatformContent: View {
    let screen: ExampleScreen
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ...
        }
        .searchable(text: $searchText)
    }
}
#endif
```

### macOS File

```swift
#if os(macOS)
import SwiftUI
import AppKit

extension ExampleScreen {
    var platformBody: some View {
        PlatformContent(screen: self)
    }
}

private struct PlatformContent: View {
    let screen: ExampleScreen
    @State private var selection = Set<Example.ID>()

    var body: some View {
        ...
    }
}
#endif
```

### Shared Component With Small Platform Differences

If only spacing or placement differs, a small environment-derived helper may be enough:

```swift
private var rowSpacing: CGFloat {
    #if os(iOS)
    10
    #else
    8
    #endif
}
```

Do not create platform files for every single value. Split when ownership gets clearer.

## Current Hotspots And Target Shape

### Remote Files

Current issues:

- `RemoteFileBrowserScreen.swift` still owns shared operation logic plus platform routing modifiers and some platform state.
- iOS search state is stored in the shared screen.
- macOS selection, inline edit state, and titlebar inset state are still stored in the shared screen until platform child views or platform state models own them.
- `RemoteFileBrowserScreen+iOS.swift` and `RemoteFileBrowserScreen+macOS.swift` exist, but the shared screen still owns too much platform state.
- `RemoteFileBrowserSupport.swift` now holds shared support only; platform-specific support lives in `Platform/RemoteFileBrowserSupport+iOS.swift` and `Platform/RemoteFileBrowserSupport+macOS.swift`.

Target files:

```text
VVTerm/Features/RemoteFiles/UI/
  RemoteFileBrowserScreen.swift
  RemoteFileBrowserScreen+iOS.swift
  RemoteFileBrowserScreen+macOS.swift
  RemoteFileBrowserSupport+iOS.swift
  RemoteFileBrowserSupport+macOS.swift
  Components/
  Sheets/
  Preview/
```

Shared responsibilities:

- store injection
- snapshot creation
- common transfer orchestration
- shared validation
- shared delete/move/rename/upload/download operation methods when behavior is identical
- notice host integration if the host is feature-level

iOS responsibilities:

- search text state
- `NavigationStack`/navigation destination preview flow
- bottom toolbar
- import picker sheet
- share sheet
- iOS create-folder, rename, delete sheet presentation
- iOS drop handling if it differs from macOS

macOS responsibilities:

- table/split layout
- preview panel sizing
- titlebar inset bridge
- multi-selection state
- inline folder/create rename editor state
- `NSOpenPanel`
- `NSSavePanel`
- `NSAlert`
- context menu construction
- AppKit table bridge and drag session store

Migration notes:

- Move platform state into platform child views before removing gated stored properties from the shared screen.
- Do not reintroduce the old `RemoteFileBrowserMacScreen.swift` or `RemoteFileBrowserIOSScreen.swift` names; use the existing `RemoteFileBrowserScreen+macOS.swift` and `RemoteFileBrowserScreen+iOS.swift` files.
- Preserve the existing SFTP Files feature-first spec as the behavioral contract.

Initial implementation status:

- Done: renamed the platform screen files, split `RemoteFileBrowserSupport.swift`, moved macOS AppKit upload/download/delete helpers into `RemoteFileBrowserScreen+macOS.swift`, and removed AppKit/UIKit imports from `RemoteFileBrowserScreen.swift`.
- Remaining: move platform stored state, iOS search/sheet/drop presentation, and remaining platform routing modifiers out of `RemoteFileBrowserScreen.swift`.

### Terminal Sessions

Current issues:

- `TerminalContainerView.swift` mixes shared connection lifecycle with iOS/macOS terminal wrapper differences, macOS key monitoring, voice recording presentation, and render pause/resume.
- `ConnectionTabsView.swift` contains a macOS toolbar body, macOS zen chrome bridge, and shared tab/session composition in one file.
- `SSHTerminalWrapper.swift` has been split into shared, iOS, and macOS files.
- `ZenModeControls.swift` keeps shared controls while `ZenModeControls+iOS.swift` and `ZenModeControls+macOS.swift` own the platform panels.

Target files:

```text
VVTerm/Features/TerminalSessions/UI/Terminal/
  TerminalContainerView.swift
  TerminalContainerView+iOS.swift
  TerminalContainerView+macOS.swift
  SSHTerminalWrapper+iOS.swift
  SSHTerminalWrapper+macOS.swift
  TerminalVoicePresentation.swift

VVTerm/Features/TerminalSessions/UI/Tabs/
  ConnectionTabsView.swift
  ConnectionTabsView+macOS.swift
  ConnectionTabComponents.swift
  ConnectionTabComponents+macOS.swift

VVTerm/Features/TerminalSessions/UI/Terminal/
  ZenModeControls.swift
  ZenModeControls+iOS.swift
  ZenModeControls+macOS.swift
```

Shared responsibilities:

- credential loading
- connection state display policy
- notice and fallback messaging
- common voice transcription behavior
- common terminal theme/background behavior

iOS responsibilities:

- keyboard-preservation wrapper configuration
- iOS terminal focus behavior
- iOS full-screen terminal presentation details
- touch/toolbar specific controls

macOS responsibilities:

- render pause/resume hooks
- local key monitor setup
- menu/shortcut bridging
- titlebar/toolbar zen mode chrome

Migration notes:

- Keep `SSHTerminalWrapper.swift` shared-only; platform wrappers belong in `SSHTerminalWrapper+iOS.swift` and `SSHTerminalWrapper+macOS.swift`.
- Keep platform zen panels in `ZenModeControls+iOS.swift` and `ZenModeControls+macOS.swift`.
- Move macOS `NSEvent` key monitoring out of `TerminalContainerView.swift`.
- Keep terminal content non-glassy.

### App Shell

Current issues:

- `VVTermApp.swift` contains app entry, root composition, macOS commands, and both app delegates.
- `ContentView.swift` is mostly macOS shell composition but has shared naming.
- `App/iOS/iOSContentView.swift` is a platform shell and can keep an iOS-specific file path, but product child views inside it should be split over time.

Target files:

```text
VVTerm/App/
  VVTermApp.swift
  VVTermApp+iOS.swift
  VVTermApp+macOS.swift
  AppDelegate+iOS.swift
  AppDelegate+macOS.swift
  Commands+macOS.swift
  ContentView.swift
  ContentView+macOS.swift
  iOS/
    ContentView+iOS.swift
    ServerListView+iOS.swift
    ServerRows+iOS.swift
```

Allowed exceptions:

- `MacShellSplitHost`
- `MacShellCommandBridge`
- `MacToolbarBridge`
- `MacConnectionToolbarController`

These are platform shell/adapters, not product UI.

Migration notes:

- Do not rename root shell types casually. App shell names are public to a lot of composition code.
- First move `VVTermCommands` and app delegates out of `VVTermApp.swift`.
- Then split iOS server-list child views into separate iOS files with neutral type names where feasible.

### Settings And Forms

Current issues:

- `TerminalSettingsView.swift`, `ServerFormSheet.swift`, and `KeychainSettingsView.swift` have many inline platform gates.
- Some gates are small row modifiers, but others represent platform-specific pickers, form presentation, and keychain/share/export behavior.

Target shape:

```text
VVTerm/Features/Settings/UI/
  TerminalSettingsView.swift
  TerminalSettingsView+iOS.swift
  TerminalSettingsView+macOS.swift
  KeychainSettingsView.swift
  KeychainSettingsView+iOS.swift
  KeychainSettingsView+macOS.swift

VVTerm/Features/Servers/UI/ServerDetail/
  ServerFormSheet.swift
  ServerFormSheet+iOS.swift
  ServerFormSheet+macOS.swift
```

Shared responsibilities:

- preference binding
- validation
- common rows and sections
- localized copy
- feature ownership

Platform responsibilities:

- platform file importers/exporters
- platform security/keychain UI affordances
- platform-specific field submit behavior
- toolbar and sheet placement differences

Migration notes:

- Do not split every small row just because it has one platform value.
- Split complete controls or presentation clusters: font picker, theme picker, keychain credential action rows, server auth field behavior.

### Store And Support

Current issues:

- `ProUpgradeSheet.swift` has platform presentation and restore/purchase UI differences inline.
- `SupportSheet.swift` has separate platform sections.

Target shape:

```text
VVTerm/Features/Store/UI/
  ProUpgradeSheet.swift
  ProUpgradeSheet+iOS.swift
  ProUpgradeSheet+macOS.swift

VVTerm/Features/Support/UI/
  SupportSheet.swift
  SupportSheet+iOS.swift
  SupportSheet+macOS.swift
```

Shared responsibilities:

- entitlement state
- product formatting
- purchase/restore actions
- copy and plan metadata

Platform responsibilities:

- macOS window/sheet sizing
- iOS sheet/navigation wrapping
- platform-specific close/cancel affordances

### Stats

Current issues:

- `ServerStatsView.swift` is very large and currently has many platform gates.
- There is existing in-progress local work in this file, so platform cleanup should wait until that work is settled.
- `StatsMacDetailShell`, `StatsMacSheetTitle`, and `StatsMacSearchField` are product UI types with platform prefixes.

Target shape:

```text
VVTerm/Features/Stats/UI/
  ServerStatsView.swift
  ServerStatsView+iOS.swift
  ServerStatsView+macOS.swift
  DetailPresentation+iOS.swift
  DetailPresentation+macOS.swift
  Components/
  Blocks/
  Layouts/
```

Shared responsibilities:

- collection lifecycle
- preference application
- block order and visibility
- layout/style selection
- shared block data

Platform responsibilities:

- sheet chrome and sizing
- search-field implementation if it must differ
- toolbar close placement
- platform-native list/detail presentation

Migration notes:

- Align this work with `docs/specs/stats-view-customization.md`.
- Keep Stats visually aligned across iOS and macOS unless a native platform convention requires a difference.
- Prefer neutral names such as `DetailShell`, `SheetTitle`, and `SearchField` inside platform files.

### Core UI Notices

Current issues:

- Notice components have small platform placement differences.

Target shape:

- Keep shared components in `Core/UI/Notices`.
- Use small inline gates for spacing and placement while the view remains shared.
- Split only if notice host ownership or platform presentation becomes structurally different.

## Migration Phases

### Phase 0: Guardrails

- Add this spec.
- Add AGENTS guidance so future UI work follows the split pattern.
- Do not change runtime behavior.

### Phase 1: Remote Files

Reason: highest-value ownership cleanup. The feature already has partial platform files but still keeps platform state in the shared screen.

Steps:

1. Done: introduce `RemoteFileBrowserScreen+iOS.swift` and `RemoteFileBrowserScreen+macOS.swift`.
2. In progress: move platform content methods into those files.
3. Move platform-specific stored state into platform child views or small platform models.
4. Done: split `RemoteFileBrowserSupport.swift` by platform.
5. In progress: remove product UI platform prefixes where the type is not a bridge.
6. Build iOS and macOS.

Acceptance:

- `RemoteFileBrowserScreen.swift` has no AppKit/UIKit imports.
- `RemoteFileBrowserScreen.swift` has no platform-specific stored state.
- Platform panels, importers, search, inline editing, and table bridge live in platform files.
- Files UI behavior is unchanged on both platforms.

### Phase 2: Terminal Surface

Reason: terminal lifecycle is sensitive, and platform behavior should be explicit.

Steps:

1. Done: split `SSHTerminalWrapper.swift` into platform files.
2. Move macOS key monitoring and render pause/resume hooks out of shared `TerminalContainerView.swift`.
3. Move iOS terminal wrapper options into `TerminalContainerView+iOS.swift`.
4. Done: split zen mode panels into platform files.
5. Build iOS and macOS.

Acceptance:

- Shared terminal container owns connection lifecycle, not AppKit/UIKit mechanics.
- macOS shortcut/key-monitor code is not in the shared terminal container.
- iOS keyboard/focus behavior remains unchanged.
- Terminal content remains non-glassy.

### Phase 3: App Shell

Reason: app root files should make platform root ownership clear.

Steps:

1. Move app delegates into `AppDelegate+iOS.swift` and `AppDelegate+macOS.swift`.
2. Move macOS commands into `Commands+macOS.swift`.
3. Keep AppKit shell bridges platform-named.
4. Consider moving iOS server list pieces out of `iOSContentView.swift` with neutral product names.

Acceptance:

- `VVTermApp.swift` remains a small composition root.
- Platform app lifecycle code lives in platform files.
- Existing commands, windows, notifications, and app lock behavior are unchanged.

### Phase 4: Settings, Forms, Store

Reason: many inline branches exist, but the risk is lower if split by complete presentation clusters.

Steps:

1. Split large platform pickers and sheet shells first.
2. Keep tiny platform spacing or row modifiers inline where extraction makes code harder to follow.
3. Use shared form sections for common fields and validation.
4. Build iOS and macOS.

Acceptance:

- AppKit/UIKit-specific picker and panel logic is out of shared files.
- Common validation remains shared.
- Form behavior and localized text remain unchanged.

### Phase 5: Stats

Reason: large file, many platform branches, and existing in-progress local work.

Steps:

1. Wait until current Stats work is clean.
2. Align with `docs/specs/stats-view-customization.md`.
3. Split detail presentation, search, and sheet chrome by platform.
4. Keep block rendering shared unless platform-native presentation clearly requires separation.
5. Build iOS and macOS.

Acceptance:

- `ServerStatsView.swift` becomes a lifecycle/container file.
- Platform sheet/detail chrome lives in platform files.
- Block order, visibility, and style behavior remains shared.

## Review Checklist

Use this checklist for new UI work and platform split refactors:

- Does the shared file import UIKit or AppKit? If yes, is it a true adapter or should it move?
- Does a shared view contain platform-specific `@State`, `@StateObject`, or `@SceneStorage`?
- Does a shared view body contain more than two related `#if os(...)` branches?
- Would a platform child view make ownership clearer?
- Is a platform prefix being used for product UI rather than a real platform adapter?
- Are iOS and macOS preserving their native behavior?
- Is all user-facing copy still localized?
- Are both iOS and macOS builds planned for validation?
- Is the change behavior-preserving, or is any behavior change explicitly called out?

## Validation

For docs-only guardrail changes:

- `git diff --check`

For implementation phases:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project VVTerm.xcodeproj -scheme VVTerm -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project VVTerm.xcodeproj -scheme VVTerm -destination 'platform=macOS' build
```

For risky UI migration phases, also run a manual smoke pass:

- open the affected screen on iOS
- open the affected screen on macOS
- verify the same entry points still work
- verify platform-specific controls still appear
- verify no terminal content glass was introduced

## Success Criteria

This pattern is working when:

- shared feature files read as product flow, not platform branching tables
- platform files contain native presentation and adapters
- new product UI types are not named with `iOS` or `Mac` prefixes by default
- platform prefixes identify true framework bridges or app shell integration
- `#if os(...)` branches are mostly file-level or small local value differences
- both iOS and macOS builds remain green after each phase
