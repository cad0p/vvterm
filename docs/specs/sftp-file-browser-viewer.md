# SFTP Remote File Browser & Viewer (Spec)

## Summary
Add a read-only SFTP file browser and file viewer for remote hosts. The feature is exposed as a new server view tab placed after Terminal:
- `Stats`
- `Terminal`
- `Files`

Path note: this original feature spec predates the feature-first migration. Any legacy `Models/`, `Managers/`, `Services/`, or `Views/` file paths in this document should be mapped to the current `App/`, `Core/`, and `Features/` tree.

This is a cross-platform feature for macOS and iOS. All three server views are enabled by default, and users can hide views they do not use from Settings. Zen remains a presentation mode layered on top of the selected server view; it is not a separate fourth view tab.

## Problem
VVTerm can connect and run shell commands, but users cannot browse remote files or quickly inspect file contents without typing shell commands (`ls`, `cat`, `less`) in Terminal. This adds friction for routine tasks like checking config files, logs, and deployment artifacts.

## Goals (V1)
- Add a `Files` view tab after `Terminal` in the per-server view selector.
- Browse remote directories over SFTP.
- View file metadata and read file contents (read-only).
- Support both macOS and iOS UI patterns.
- Reuse existing SSH credentials and host-key verification flow.
- Support user-configurable view visibility for `Stats`, `Terminal`, and `Files`, with all enabled by default.
- Ensure `Files` works correctly inside Zen mode without changing Zen into a separate server view type.
- Keep tab/session limits unchanged (no new Pro gating in V1).
- Preserve current terminal behavior and performance.

## Non-Goals (V1)
- Upload, rename, delete, chmod/chown, or create files/directories.
- Remote file editing and save-back.
- Recursive search / grep across remote trees.
- Git-aware file diffing.
- Offline caching of full file contents.

## User Stories
- As a user, I can switch from Terminal to Files without disconnecting.
- As a user, I can navigate directories with breadcrumbs.
- As a user, I can open a file and preview its contents quickly.
- As a user, I can refresh the current directory when files change remotely.
- As a user, I can see clear error states for permission denied, not found, and connection issues.

## UX Design

### View Tab Placement
- Add `Files` to the per-server view selector after `Terminal`.
- Default order: `Stats`, `Terminal`, `Files`.
- Keep per-server selected-view persistence (`selectedViewByServer`) and accept `"files"` values.
- Update `ConnectionViewTab.defaultOrder` to include `.files` and append missing tab IDs during order migration.
- Extend `ViewTabConfigurationManager` visibility support with `showFilesTab` (`true` by default), alongside `showStatsTab` and `showTerminalTab`.
- The per-server view selector only shows tabs that are currently enabled in Settings.
- At least one server view must remain enabled. Settings must prevent hiding the last visible view.
- If a stored `selectedViewByServer[serverId]` value points to a hidden view, fall back to `ViewTabConfigurationManager.effectiveDefaultTab(...)`.

### View Visibility Settings
- Add a Settings section for server view visibility and order.
- Default state for fresh installs: `Stats = on`, `Terminal = on`, `Files = on`.
- Users may hide views they do not use, for example leaving only `Terminal` visible.
- Reuse `ViewTabConfigurationManager` as the source of truth for:
  - tab order
  - default tab
  - per-tab visibility (`showStatsTab`, `showTerminalTab`, `showFilesTab`)
- Hidden views are removed from:
  - macOS toolbar segmented picker
  - iOS segmented control
  - Zen mode view chips

### Zen Mode Compatibility
- Zen is not a `ConnectionViewTab` and must not be added as a separate top-level server view.
- Zen mode must support whichever server view is currently selected, including `Files`.
- Entering or leaving Zen mode must preserve:
  - current selected server view
  - current remote path
  - current directory entries
  - current selected file viewer payload
  - current terminal tab/session selection
- Zen mode view chips should reflect only currently enabled server views in configured order.
- Zen mode action groups remain view-specific:
  - `Terminal`: existing tab and pane actions
  - `Files`: file-browser actions such as Up, Refresh, Sort, Show Hidden Files
  - `Stats`: no terminal/file-specific actions
- Switching `Terminal <-> Files` while Zen mode is active must not disconnect the underlying terminal session or clear the browser state.

### macOS
- Update `ConnectionTerminalContainer` toolbar picker in `VVTerm/Views/Tabs/ConnectionTabsView.swift`:
  - `Stats` (`chart.bar.xaxis`)
  - `Terminal` (`terminal`)
  - `Files` (`folder`)
- Render only currently enabled view tabs in the picker, preserving configured order.
- Show terminal tab strip only when `selectedView == "terminal"`.
- In `Files` view, toolbar actions:
  - Back / Up directory
  - Refresh
  - Sort menu (name/date/size)
  - Show hidden files toggle

### iOS
- Update segmented control in `VVTerm/Views/iOS/iOSContentView.swift`:
  - Tags: `["stats", "terminal", "files"]`
  - Icons: `["chart.bar.xaxis", "terminal", "folder"]`
- Render only currently enabled view tabs in the segmented control, preserving configured order.
- Keep Terminal-only actions (`+` new terminal tab) hidden unless `selectedView == "terminal"`.
- Add Files-specific actions in trailing menu: Refresh, toggle hidden files, sort.

### Browser Behavior
- First open path selection priority:
  1. Last successful path for that server (local cache).
  2. Active terminal working directory for that server (if available).
  3. Remote home directory (`.` realpath fallback).
- Directory list behavior:
  - directories first, then files
  - default sort: name ascending
  - pull-to-refresh (iOS) / refresh button (macOS)
  - tap directory to navigate into it
  - tap file to open viewer

### Viewer Behavior
- V1 viewer is read-only.
- Text files:
  - UTF-8 text preview with monospaced font.
  - Show truncation banner when preview limit is hit.
- Binary/unknown files:
  - Show metadata card and message that inline preview is unavailable in V1.
- Always show metadata header:
  - path, size, permissions, modified time, type

## Technical Design

### New Models
Create `VVTerm/Models/RemoteFile.swift`:
- `enum RemoteFileType: String, Codable` (`file`, `directory`, `symlink`, `other`)
- `struct RemoteFileEntry: Identifiable, Hashable`
  - `id` (full path)
  - `name`
  - `path`
  - `type`
  - `size: UInt64?`
  - `modifiedAt: Date?`
  - `permissions: UInt32?`
  - `symlinkTarget: String?`
- `enum RemoteFileSort: String, Codable, CaseIterable` (`name`, `modifiedAt`, `size`)
- `struct RemoteFileViewerPayload`
  - `entry: RemoteFileEntry`
  - `textPreview: String?`
  - `isTruncated: Bool`

### SSH / SFTP Layer
Extend `SSHClient` + `SSHSession` in `VVTerm/Services/SSH/SSHClient.swift` with SFTP operations backed by `libssh2_sftp`:
- `listDirectory(path:)`
- `stat(path:)`
- `readFile(path:maxBytes:offset:)`
- `resolveHomeDirectory()`

Implementation notes:
- Keep operations actor-isolated in `SSHSession` to avoid races with shell/exec channels.
- Handle `LIBSSH2_ERROR_EAGAIN` using existing socket wait flow.
- Reuse existing authenticated SSH sessions when possible.
- If no reusable session exists, create a dedicated short-lived SSH client for file browsing.
- Track whether the file browser is using a borrowed client or an owned client. `disconnect(serverId:)` must only tear down owned SFTP clients.

### File Browser Manager
Create `VVTerm/Managers/RemoteFileBrowserManager.swift` (`@MainActor`, `ObservableObject`):
- Per-server state:
  - current path
  - breadcrumbs
  - entries
  - loading/error state
  - sort + hidden-file toggle
  - selected file payload
- Public APIs:
  - `loadInitialPath(for:)`
  - `refresh(serverId:)`
  - `openDirectory(_:serverId:)`
  - `openFile(_:serverId:)`
  - `goUp(serverId:)`
  - `disconnect(serverId:)`

### Connection Strategy
- Prefer existing shared SSH client from:
  - `TerminalTabManager` (macOS path)
  - `ConnectionSessionManager` (iOS path)
- If the active server transport is Mosh, do not expect a reusable shared SSH client. In that case, create an owned SSH/SFTP client for Files.
- If unavailable, manager creates an owned `SSHClient`, connects using `KeychainManager` credentials, and disconnects on idle/teardown.
- On explicit server disconnect, always tear down any owned SFTP connections.

### Local Persistence (No Cloud Sync in V1)
- Store lightweight per-server browser preferences in `UserDefaults`:
  - last visited path
  - sort mode
  - show hidden files
- Key example: `remoteFileBrowserState.v1`
- Do not sync file browser state with CloudKit in V1.
- Store view visibility settings separately from per-server browser state, reusing the existing `ViewTabConfigurationManager` keys and adding `showFilesTab`.

## View Integration

### macOS Path
Update `VVTerm/Views/Tabs/ConnectionTabsView.swift`:
- Add `Files` picker tag.
- Update the picker to render from visible tabs instead of hardcoding only `Stats` and `Terminal`.
- Render new `RemoteFileBrowserView` when `selectedView == "files"`.
- Keep terminal-only rendering/background logic scoped to `selectedView == "terminal"`.
- Update macOS Zen mode controls to include `Files`, respect hidden views, and show file-browser actions when `selectedView == "files"`.

### iOS Path
Update `VVTerm/Views/iOS/iOSContentView.swift`:
- Add `files` segmented option in `iOSNativeSegmentedPicker`.
- Update `iOSNativeSegmentedPicker` to support a dynamic list of visible tabs instead of a fixed two-item array.
- In `sessionContent`, render `RemoteFileBrowserView` for the active server when selected view is files.
- Keep terminal warmup logic (`shouldShowTerminalBySession`) untouched and only for terminal mode.
- Update iOS Zen mode controls to include `Files`, respect hidden views, and show file-browser actions when `selectedView == "files"`.

### New Views
Create:
- `VVTerm/Views/Files/RemoteFileBrowserView.swift`
- `VVTerm/Views/Files/RemoteFileViewerView.swift`
- `VVTerm/Views/Files/RemoteFileRow.swift`

## Error Handling
- Map common SFTP failures to user-facing states:
  - permission denied
  - path not found
  - disconnected / timeout
  - unsupported encoding / binary file
- Preserve retry affordances (`Retry`, `Refresh`).
- Avoid dropping user path context on transient failures.

## Security & Privacy
- Reuse current SSH authentication and host-key trust flow.
- No credential changes in Keychain schema.
- No file content logging.
- No remote file metadata/content synced to CloudKit.

## Performance Limits (V1)
- Directory listing soft cap: 2,000 entries (show warning after cap).
- Text preview default cap: 512 KB.
- Hard read cap per viewer request: 2 MB.
- Lazy-load viewer data only when a file is selected.

## Testing Plan

### Unit Tests
- Add `VVTermTests/RemoteFileBrowserManagerTests.swift`:
  - path navigation
  - sort and hidden-file filtering
  - state restoration
- Add `VVTermTests/SFTPPathNormalizationTests.swift`:
  - `.` / `..` handling
  - root handling
  - symlink-safe display path logic
- Add `VVTermTests/SFTPPreviewTests.swift`:
  - text/binary detection
  - truncation behavior

### Integration / Behavior Tests
- Connect to test SSH server and validate:
  - list directory
  - read small text file
  - permission denied handling
  - reconnect and refresh behavior

### UI Tests
- macOS and iOS:
  - `Files` tab appears after `Terminal`.
  - hiding `Stats` or `Files` in Settings removes them from the picker/segmented control without breaking selection.
  - users cannot hide the last remaining server view.
  - switching `Terminal <-> Files` preserves session stability.
  - entering Zen mode from `Files` preserves current path and entries.
  - switching views inside Zen mode preserves browser state and terminal stability.
  - opening file shows viewer and metadata.
  - refresh and breadcrumb navigation work.

## Rollout
- Ship enabled by default.
- Validate with internal QA across mixed host types (Linux/macOS/BSD) before public release.

## Open Questions
- Should V1 include image preview (PNG/JPEG) or keep text-only preview?
- Should directory listing use pagination in V1 or defer until very large directory feedback appears?
- Should we add an `Open in Terminal` action from Files in V1.1?
