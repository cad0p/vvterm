# SFTP File Tabs (Draft Spec)

Draft date: 2026-04-13

## Summary
Add tab support inside the existing `Files` server view on both macOS and iOS.

This is not a new top-level server view tab. The existing `Stats` / `Terminal` / `Files` view selector stays intact. The new tabs live inside `Files`, similar to how terminal tabs live inside `Terminal`.

The UX target is parity with the current terminal tab experience:
- macOS: toolbar tab strip with arrows, tab pills, close buttons, and `+`
- iOS: top tab bar with the same visual language and `+` in the navigation bar
- Zen mode: file tabs are manageable from the same panel when `Files` is the active server view

This feature should be guarded by the same Pro entitlement bucket as terminal multi-tab usage, but without regressing the current free single-file-browser experience.

Important architecture rule:
- implement this as a direct-cutover internal refactor
- do not add server-id keyed compatibility shims that pretend multiple file tabs exist while still sharing one browser state
- do not migrate or preserve legacy `remoteFileBrowserState.v1` browser snapshots

## Problem
Today the Files feature is effectively a single browser state per server:
- `RemoteFileBrowserStore.states` is keyed by `serverId`
- directory request IDs and viewer request IDs are keyed by `serverId`
- persisted browser state is keyed by `serverId`
- toolbar commands target a server, not a specific file browser instance

That works for one browser surface, but it breaks down immediately for tabs:
- every fake tab would mirror the same path, selection, preview, and error state
- switching tabs would not preserve independent folder context
- toolbar actions like Upload or New Folder could target the wrong tab
- request cancellation and persistence would race across tabs on the same server

Users need multiple file contexts for common workflows:
- compare `/etc` with `/var/log`
- keep one tab at project root and another at a nested config folder
- stage uploads in one folder while inspecting logs in another

## Goals
- Add multiple file tabs inside `Files` on macOS and iOS.
- Keep the current top-level server view model unchanged.
- Match terminal tab behavior closely enough that the feature feels native to VVTerm.
- Preserve the current free experience: one file browser tab remains available without Pro.
- Gate opening additional file tabs behind the existing Pro entitlement.
- Keep browser state isolated per file tab.
- Keep SSH/SFTP transport pooled per server rather than per tab.
- Persist file tabs locally across relaunch and reconnect.
- Keep CloudKit out of scope.
- Allow structural cleanup inside `Features/RemoteFiles` to support the feature properly.

## Non-Goals
- Cross-server file tabs inside one shared tab strip.
- Split panes inside `Files`.
- Reusing terminal session or pane models for file tabs.
- Syncing file tabs or browser state through CloudKit.
- Background preloading every tab aggressively.
- Turning `Files` into a second terminal-like session system.
- UI redesign outside the scope of the file-tab addition.

## Product Decisions

### Core Behavior
- File tabs are scoped per server.
- Each file tab owns its own browser state:
  - current path
  - entries
  - breadcrumbs
  - selection
  - preview payload
  - viewer error
  - directory error
  - loading state
  - sort
  - sort direction
  - hidden-files preference
  - filesystem status
- File tabs do not own their own SSH connection by default.
- SFTP transport remains pooled per server through `SSHSFTPAdapter`.

### Free vs Pro
- Free users can keep exactly one file tab per server.
- Pro users can open multiple file tabs per server.
- This uses the same Pro entitlement as terminal multi-tab access.
- This does not count the baseline existing `Files` experience as a new paid feature.
- The paywall copy should be file-tab specific where needed, but the upgrade destination remains the standard Pro sheet.

### Default Creation Rules
- When `Files` becomes active for a server with no file tabs yet, VVTerm should auto-create one file tab so the current one-tab behavior remains unchanged.
- Creating an additional file tab duplicates the current tab’s navigation context:
  - seed from the current tab’s path when available
  - copy current sort, sort direction, and hidden-files setting
  - do not copy active selection, preview sheet presentation, pending dialogs, or in-flight operations
- If there is no current file tab to duplicate, use the existing initial-path rules:
  1. provided seed path
  2. active terminal working directory for that server
  3. persisted path from the last file tab snapshot
  4. remote home / root fallback

### Closing Rules
- Closing a non-selected file tab preserves the selected tab.
- Closing the selected file tab selects an adjacent tab, preferring the next tab to the right, otherwise the nearest tab to the left.
- Closing the last file tab is allowed.
- If `Files` is selected with zero file tabs, show a Files empty state with a `New File Tab` action.

### Titles
- File-tab titles are derived, not user-editable in V1.
- Primary title source is the current directory name.
- Root-level fallback is the server name or `/`.
- Duplicate display titles should be disambiguated at render time.

## UX Design

### Terminology
- `ConnectionViewTab` continues to mean `Stats`, `Terminal`, `Files`.
- `TerminalTab` continues to mean a terminal tab inside `Terminal`.
- Introduce `RemoteFileTab` for file-browser tabs inside `Files`.

The spec intentionally keeps these three concepts separate.

### macOS
- When `selectedView == "files"`, show a file-tab strip in the same toolbar region where terminal tabs currently render.
- The file-tab strip matches the current terminal tab structure:
  - previous / next arrows
  - horizontal scrollable pill tabs
  - close button on each tab
  - `+` button
- The `Files` toolbar menu continues to exist, but all actions target the selected file tab.
- `Cmd+T` opens a new file tab when `Files` is the active view.
- `Cmd+W` closes the selected file tab when `Files` is the active view.
- `Shift+Cmd+[` and `Shift+Cmd+]` move between file tabs when `Files` is the active view.
- Context menu parity with terminal tabs:
  - Close Tab
  - Close Other Tabs
  - Close All to the Left
  - Close All to the Right
  - Duplicate Tab

### iOS
- When `selectedView == "files"` and more than one file tab exists, show a top file-tab bar using the same visual style as the current terminal tab bar.
- The navigation bar `+` button opens a new file tab when `Files` is selected.
- Closing a file tab uses the same inline tab affordance as terminal tabs.
- When `Files` is selected and only one file tab exists, the header tab bar stays hidden, matching current iOS terminal behavior.
- Edge-swipe tab switching should work for file tabs with the same thresholds as terminal tabs, provided it does not interfere with the system back gesture.

### Zen Mode
- Zen mode must become view-aware for tab content, not terminal-session specific.
- When `selectedView == "files"`, the Zen panel should show:
  - file-tab count
  - file-tab list
  - close action for each file tab
  - `New Tab` opening a new file tab
- The existing file actions in Zen mode continue to target the selected file tab.

### Empty State
- If `Files` is selected and the server has zero file tabs, show a Files-specific empty state with:
  - `New File Tab`
  - optional explanation that no file tabs are open
- Do not fall back to the old singleton browser automatically after the user explicitly closed all tabs.

## Architecture Direction

### Direct Cutover
This feature should be implemented as a real ownership change, not a compatibility layer.

Required changes:
- stop treating `serverId` as the unique identifier for a file browser instance
- move browser runtime state from server-scoped to file-tab-scoped
- make toolbar commands explicitly target a file tab
- make request tracking explicitly target a file tab

Avoid:
- hidden “active tab state” dictionaries layered on top of the existing server-scoped store
- APIs that still take only `serverId` for tab-specific browser actions
- importing terminal-tab UI components directly into `RemoteFiles`

### Shared UI Primitives
The file tabs should look like terminal tabs, but `RemoteFiles` should not depend on `TerminalSessions/UI`.

Preferred approach:
- extract style-only shared tab chrome primitives into `Core/UI` if reuse is meaningful
- keep terminal-specific and file-specific wrappers inside their respective features

Examples of reusable primitives:
- pill tab bar container
- pill tab button shell
- previous / next arrow button
- common sizing metrics

### State Ownership
Introduce two distinct application-level responsibilities:

1. `RemoteFileTabManager`
- owns file-tab metadata and selection per server
- owns open / close / duplicate / select-next / select-previous actions
- owns local persistence for tab lists and selected tab

2. `RemoteFileBrowserStore`
- owns browser state per file tab
- owns directory loading, preview loading, mutations, toolbar commands, and error state
- no longer assumes one browser per server

This split keeps tab chrome concerns separate from browser orchestration concerns.

## Proposed Types

### Domain
Add:
- `VVTerm/Features/RemoteFiles/Domain/RemoteFileTab.swift`

Suggested shape:
- `struct RemoteFileTab: Identifiable, Codable, Equatable`
  - `id: UUID`
  - `serverId: UUID`
  - `createdAt: Date`
  - `seedPath: String?`
  - `lastKnownPath: String?`

Notes:
- display title can be computed from runtime or persisted path
- no SSH client references
- no SwiftUI

Add:
- `VVTerm/Features/RemoteFiles/Domain/RemoteFileTabSnapshot.swift`

Suggested shape:
- `struct RemoteFileTabSnapshot: Codable, Equatable`
  - `tabsByServer: [String: [RemoteFileTab]]`
  - `selectedTabByServer: [String: UUID]`
  - `schemaVersion: Int`

### Application
Add:
- `VVTerm/Features/RemoteFiles/Application/RemoteFileTabManager.swift`

Responsibilities:
- `tabs(for serverId:)`
- `selectedTab(for serverId:)`
- `ensureInitialTab(for server:)`
- `openTab(for server:seedingFrom:)`
- `duplicateTab(_:)`
- `closeTab(_:)`
- `closeOtherTabs(except:)`
- `closeTabsToLeft(of:)`
- `closeTabsToRight(of:)`
- `selectNextTab(for serverId:)`
- `selectPreviousTab(for serverId:)`
- `disconnect(serverId:)`

Refactor:
- `RemoteFileBrowserStore`

Change the primary identity from `serverId` to `(serverId, tabId)` or a dedicated tab context type.

Suggested approach:
- keep server identity explicit for transport lookup
- key browser state, request IDs, and toolbar commands by `tabId`
- validate that each tab belongs to the provided server before mutating state

Suggested API direction:
- `state(for tab: RemoteFileTab) -> BrowserState`
- `loadInitialPath(for server: Server, tab: RemoteFileTab, initialPath: String?)`
- `refresh(server: Server, tab: RemoteFileTab)`
- `activate(_ entry: RemoteFileEntry, in tab: RemoteFileTab, server: Server)`
- `loadPreview(for entry: RemoteFileEntry, in tab: RemoteFileTab, serverId: UUID)`
- `setShowHiddenFiles(_:for tab: RemoteFileTab)`
- `updateSort(_:direction:for tab: RemoteFileTab)`
- `disconnect(serverId:)`
- `removeRuntimeState(for tabId: UUID)`

### Infrastructure
Keep:
- `SSHSFTPAdapter`

But preserve server-scoped transport ownership:
- multiple file tabs on the same server reuse the same borrowed or owned `SSHClient`
- opening a second file tab must not create a second owned client by default
- disconnecting a server tears down owned SFTP transport once, not once per tab

No transport model changes are needed beyond ensuring concurrent tab activity is safe.

## Persistence and Cutover

### New Persistence Model
Keep file-tab persistence local-only.

Recommended persistence split:
- `remoteFileTabsSnapshot.v1`
  - tab lists per server
  - selected tab per server
- `remoteFileBrowserState.v2`
  - per-tab browser snapshots

Recommended per-tab persisted browser payload:
- `lastVisitedPath`
- `sort`
- `sortDirection`
- `showHiddenFiles`
- `hasCustomizedHiddenFiles`

### Cutover Policy
Current persisted data is keyed by `serverId` in `remoteFileBrowserState.v1`.

This feature uses a hard cutover, not a migration:
- do not read `remoteFileBrowserState.v1` into the new file-tab model
- do not create synthetic `RemoteFileTab` instances from legacy browser state
- do not keep fallback read paths for the old format

On first launch after the refactor:
- start with the new tab-aware persistence model only
- create a fresh default file tab when `Files` is opened for a server
- ignore or clear the old `remoteFileBrowserState.v1` payload

Tradeoff:
- existing users lose old local Files state such as last visited path, sort, and hidden-files preference
- this is acceptable in exchange for a clean cutover and simpler implementation

### Persistence Rules
- Persist tab list and selected tab after every structural change.
- Persist per-tab browser preferences whenever path, sort, or hidden-files settings change.
- Persist runtime-light state only.
- Do not persist:
  - loaded entry arrays
  - preview payload content
  - active sheet presentation
  - upload / rename / move dialogs
  - in-flight request IDs

## Integration Plan

### Composition Root
Update `VVTermApp` to create and inject:
- `RemoteFileTabManager`
- `RemoteFileBrowserStore`

Do not hide the file-tab manager inside the file-browser store singleton.

### macOS Container
Update `ConnectionTerminalContainer` so that:
- `Files` renders a selected `RemoteFileTab`
- the toolbar tab strip swaps between terminal tabs and file tabs based on `selectedView`
- file actions target the selected file tab
- `disconnectFromServer()` tears down file-tab runtime state for that server

### iOS Container
Update `iOSTerminalView` so that:
- `Files` uses selected file-tab state rather than server-scoped file-browser state
- the header tab bar is view-aware:
  - terminal sessions when `Terminal` is selected
  - file tabs when `Files` is selected
- the navigation bar `+` button is view-aware:
  - terminal tab when `Terminal`
  - file tab when `Files`
- disconnect tears down file-tab runtime state for the current server

### RemoteFileBrowserScreen
Keep `RemoteFileBrowserScreen` as the per-tab browser surface.

Refactor it so that it receives explicit tab context:
- `browser`
- `server`
- `fileTab`
- `initialPath`

Do not move tab-strip ownership into this screen.

### Toolbar Commands
`RemoteFileBrowserStore.ToolbarCommand` must become tab-aware.

Suggested change:
- add `tabId`
- derive destination path from the selected file tab

This prevents upload / create-folder actions from targeting the wrong file tab.

## Paywall and Copy

### Entitlement
- Reuse the existing Pro entitlement and upgrade sheet.
- No new StoreKit product.

### Limit Enforcement
Add a file-tab-specific gate:
- free: 1 file tab per server
- Pro: unlimited

Suggested API:
- `RemoteFileTabManager.canOpenNewTab(for serverId:)`

### Copy
The current generic tab-limit copy is terminal-connection oriented and should not be reused verbatim for file tabs.

Add file-tab-specific strings:
- title: `File Tab Limit Reached`
- message: `You can only have 1 file tab at a time on the free plan. Upgrade to Pro for multiple file tabs.`

Update the Pro sheet feature description so it does not imply the feature only applies to terminal tabs.

Recommended revised feature copy:
- `Open multiple terminal or file tabs at once (free: 1)`

## Implementation Steps

### 1. Extract shared tab chrome if needed
- move shared visuals into `Core/UI` only if both features genuinely use them
- keep feature-specific wrappers in `TerminalSessions` and `RemoteFiles`

### 2. Add file-tab domain and manager
- add `RemoteFileTab`
- add `RemoteFileTabManager`
- add local persistence and restore
- add free/pro limit logic

### 3. Refactor browser store to tab identity
- move browser runtime state to file-tab scope
- migrate request IDs and toolbar commands to file-tab scope
- keep transport pooling server-scoped

### 4. Update platform containers
- macOS toolbar strip
- iOS tab header and nav bar actions
- Zen mode panel
- empty states
- keyboard shortcuts and tab navigation commands

### 5. Add cutover handling
- do not import `remoteFileBrowserState.v1`
- optionally clear the legacy local key during first-run cutover
- initialize fresh tab-aware snapshots on demand

### 6. Add tests
- unit, integration, and UI coverage for tab isolation and gating

## Testing Plan

### Unit Tests
- `RemoteFileTabManagerTests`
  - create initial tab
  - open / close / duplicate / select
  - close-left / close-right / close-others
  - free-tier gating
  - persistence round-trip
  - hard-cutover behavior with legacy `remoteFileBrowserState.v1` ignored
- `RemoteFileBrowserStoreTests`
  - state isolation between two file tabs on the same server
  - request ID isolation by tab
  - toolbar command routing by tab
  - disconnect clears runtime state for all tabs on a server

### Integration Tests
- Same server, two file tabs:
  - tab A at `/etc`
  - tab B at `/var/log`
  - switching tabs preserves independent path and preview state
- New file tab duplicates current folder context
- Disconnect and reconnect restore file-tab snapshots locally
- File actions operate on the selected file tab only

### UI Tests
- macOS:
  - file-tab strip appears only in `Files`
  - `Cmd+T` opens file tab when `Files` is active
  - `Cmd+W` closes selected file tab
- iOS:
  - `+` opens file tab when `Files` is selected
  - file-tab bar appears when multiple tabs exist
  - tab selection and close actions preserve independent folder state
- Paywall:
  - free user hitting second file tab shows file-tab-specific upgrade messaging
  - Pro user can open multiple file tabs

## Acceptance Criteria
- Opening a second file tab does not change the first file tab’s path, selection, preview, or sort state.
- `Files` continues to open automatically with one browser tab on first use.
- Free users can still use `Files` exactly as before with one tab.
- Pro users can open multiple file tabs on both macOS and iOS.
- File tabs use the same visual language as terminal tabs without cross-feature UI coupling.
- Disconnecting a server does not leak owned SFTP clients.
- The implementation removes the current per-server browser-state assumption rather than layering around it.

## Deferred
- User-renamable file tabs.
- Drag-reorder file tabs.
- Cross-window file-tab persistence semantics.
- CloudKit sync for file tabs.
- Mixed terminal/file tab strip in one unified model.
