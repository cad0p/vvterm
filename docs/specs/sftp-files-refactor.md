# SFTP Files Feature-First Refactor (Spec)

## Summary
Refactor the SFTP Files feature into a feature-first structure with clear internal layers:
- `Domain`
- `Application`
- `Infrastructure`
- `UI`

This is a structural refactor. Its purpose is to improve maintainability, scalability, testability, and safety of future changes.

This refactor must be safe:
- no intentional UI redesign
- no intentional UX changes
- no intentional visual styling changes
- no intentional changes to navigation structure
- no intentional changes to feature scope

The default expectation is behavior preservation while splitting responsibilities into better file and folder boundaries.

## Problem
Before the feature-first migration, the SFTP Files implementation was spread across multiple top-level technical buckets and oversized files:
- `Models/RemoteFile.swift`
- `Views/Files/RemoteFileBrowserManager.swift`
- `Views/Files/RemoteFileBrowserView.swift`
- `Views/Files/RemoteFileBrowserComponents.swift`
- `Views/Files/RemoteFileBrowserSupport.swift`
- `Services/SSH/SSHClient.swift`

This creates several problems:
- feature logic is scattered across unrelated top-level directories
- non-view logic lives under `Views`
- transport, policy, state, and UI concerns are mixed
- files are too large for safe feature growth
- testing is difficult because core logic is not isolated
- future work such as search, background transfer, bookmarks, sync, and conflict policy will further increase coupling

## Goals
- Move the Files feature to a feature-first directory layout.
- Keep the refactor behavior-preserving by default.
- Split current large files into small focused files.
- Establish explicit layer boundaries inside the feature.
- Introduce dependency injection at the feature boundary.
- Centralize transfer policy, conflict handling, preview loading, and temporary-file management.
- Keep platform-specific UI code separate from shared feature UI.
- Make the feature easier to test without SwiftUI or live SSH sessions.

## Non-Goals
- Redesigning the Files UI.
- Adding new user-facing features.
- Reworking the whole app to feature-first in the same change.
- Rewriting the SSH transport stack beyond what is needed to isolate Files behavior.
- Changing non-Files features unless required for integration compatibility.

## Refactor Safety Rules

### Safe Refactor Definition
For this spec, "safe refactor" means:
- preserve existing screen structure and user flows
- preserve existing labels, icons, menus, and sheet presentation where possible
- preserve current navigation entry points from Terminal/Stats/Files tabs
- preserve current supported operations and limits
- preserve platform-specific behavior on macOS and iOS unless there is an existing bug being explicitly fixed

Allowed changes:
- moving files
- renaming files/types for better ownership
- extracting logic into services/coordinators/stores
- introducing protocol boundaries
- replacing singleton usage with injected dependencies
- centralizing temporary-file and conflict policy behavior without changing user-facing UI

Not allowed as part of this refactor:
- new visual design language
- new layout hierarchy for the browser
- changing toolbar structure for aesthetic reasons
- changing sheet designs unless needed to keep behavior after extraction
- introducing new features under the guise of cleanup

### Behavior Preservation Contract
The refactor should preserve:
- current Files tab integration
- current directory loading behavior
- current preview behavior
- current drag/drop interactions
- current rename/move/upload/delete/permission flows
- current iOS/macOS parity

If a behavior change is required for correctness or safety, it must be:
- explicitly documented in the spec
- isolated to the narrowest possible area
- covered by tests

## Architectural Direction

### Why Feature-First
The Files feature is already substantial enough that technical-bucket organization is working against it.

Feature-first is preferred here because:
- all code for one feature lives together
- ownership is clearer
- review scope becomes smaller and easier to reason about
- future changes affect one subtree instead of several top-level buckets
- tests naturally mirror feature boundaries

This refactor is intentionally scoped to the Files feature only. It does not require converting the rest of VVTerm immediately.

### Target Folder Structure
```text
VVTerm/
├── Features/
│   └── RemoteFiles/
│       ├── Domain/
│       │   ├── RemoteFileType.swift
│       │   ├── RemoteFileEntry.swift
│       │   ├── RemoteFilePath.swift
│       │   ├── RemoteFilePermissions.swift
│       │   ├── RemoteFileSort.swift
│       │   ├── RemoteFilePreview.swift
│       │   ├── RemoteFileBrowserError.swift
│       │   ├── RemoteFileConflictPolicy.swift
│       │   ├── RemoteFileBrowserState.swift
│       │   └── RemoteFileBrowserPersistedState.swift
│       ├── Application/
│       │   ├── RemoteFileBrowserStore.swift
│       │   ├── RemoteFileBrowserActions.swift
│       │   ├── RemoteFileTransferCoordinator.swift
│       │   ├── RemoteFilePreviewCoordinator.swift
│       │   └── RemoteFilePersistence.swift
│       ├── Infrastructure/
│       │   ├── RemoteFileService.swift
│       │   ├── SFTPRemoteFileService.swift
│       │   ├── SSHSFTPAdapter.swift
│       │   ├── RemoteFileConflictResolver.swift
│       │   ├── RemoteFileTemporaryStorage.swift
│       │   └── RemoteFilePreviewLoader.swift
│       ├── UI/
│       │   ├── RemoteFileBrowserScreen.swift
│       │   ├── RemoteFileBrowserMacScreen.swift
│       │   ├── RemoteFileBrowserIOSScreen.swift
│       │   ├── Components/
│       │   ├── Sheets/
│       │   ├── Preview/
│       │   └── Platform/
│       └── Testing/
│           ├── Fakes/
│           ├── Fixtures/
│           └── Helpers/
└── VVTermTests/
    └── Features/
        └── RemoteFiles/
```

### Integration Boundary
The rest of the app should treat Files as a feature entry point:
- parent containers create and inject the Files store/dependencies
- `ConnectionTabsView` and iOS content views only embed the Files screen
- integration points should remain thin

## Detailed Design

### 1. Domain Layer
The `Domain` layer contains pure feature types and logic with no SwiftUI, no SSH session ownership, and no direct temp-file or UI concerns.

#### `RemoteFileType.swift`
- `RemoteFileType`

#### `RemoteFileEntry.swift`
- `RemoteFileEntry`
- lightweight display metadata only if independent from SwiftUI

#### `RemoteFilePath.swift`
- normalization
- parent path logic
- path append logic
- breadcrumb generation

#### `RemoteFilePermissions.swift`
- permission audiences/capabilities
- draft mutation helpers
- symbolic/octal formatting helpers

#### `RemoteFileSort.swift`
- `RemoteFileSort`
- `RemoteFileSortDirection`
- sorting helpers

#### `RemoteFilePreview.swift`
- `RemoteFilePreviewKind`
- `RemoteFileViewerPayload`
- preview-size rules if domain-level

#### `RemoteFileBrowserError.swift`
- feature-level errors

#### `RemoteFileConflictPolicy.swift`
- overwrite policy model
- keep-both policy model
- explicit policy enum shared by upload/move/rename/copy

#### `RemoteFileBrowserState.swift`
- selected path
- entries
- loading flags
- viewer state
- sort/hidden preferences
- current path

#### `RemoteFileBrowserPersistedState.swift`
- persisted subset only

Rules:
- no SwiftUI imports
- no direct `SSHClient` references
- no temp-file logic
- no AppKit/UIKit

### 2. Application Layer
The `Application` layer owns feature state and orchestrates user actions.

#### `RemoteFileBrowserStore.swift`
Responsibilities:
- `@MainActor` observable feature state
- bind UI to application state
- expose user-facing actions
- own the feature lifecycle

This is the replacement for the current broad manager role.

#### `RemoteFileBrowserActions.swift`
Responsibilities:
- thin action entry points grouped by use case
- navigation actions
- selection actions
- refresh actions
- mutation actions

This file may remain small or be folded into the store if the split is not justified after extraction.

#### `RemoteFileTransferCoordinator.swift`
Responsibilities:
- upload planning
- remote copy planning
- move planning
- recursive traversal
- progress tracking
- conflict resolution integration

#### `RemoteFilePreviewCoordinator.swift`
Responsibilities:
- preview loading orchestration
- preview-size gating
- download-for-preview flow
- preview artifact cleanup

#### `RemoteFilePersistence.swift`
Responsibilities:
- load/save persisted browser state
- no UI
- no SSH

Rules:
- `Application` depends on `Domain`
- `Application` depends on protocols from `Infrastructure`
- `Application` does not import AppKit/UIKit-specific code

### 3. Infrastructure Layer
The `Infrastructure` layer implements the real transport/storage/integration mechanisms.

#### `RemoteFileService.swift`
Protocol used by `Application`.

Expected operations:
- list directory
- stat/lstat
- read file
- download file
- upload/write file
- create directory
- rename/move
- delete file/directory
- set permissions
- resolve home directory
- fetch file-system status

#### `SFTPRemoteFileService.swift`
Responsibilities:
- implement `RemoteFileService`
- reuse or own SSH connections as needed
- hide SFTP transport details from application/UI layers

#### `SSHSFTPAdapter.swift`
Responsibilities:
- bridge between feature infrastructure and `SSHClient`/`SSHSession`
- isolate SFTP-specific adapter logic from feature policy logic

#### `RemoteFileConflictResolver.swift`
Responsibilities:
- conflict planning
- "keep both" naming
- policy application for:
  - upload
  - rename
  - move
  - cross-server copy

#### `RemoteFileTemporaryStorage.swift`
Responsibilities:
- dedicated temp root for Files feature artifacts
- preview temp files
- drag export temp files
- download staging
- cross-server copy staging
- cleanup policy

#### `RemoteFilePreviewLoader.swift`
Responsibilities:
- classify previewability
- decode text previews
- validate media previews

Rules:
- `Infrastructure` may depend on SSH transport and Foundation IO
- `Infrastructure` must not depend on SwiftUI screen state
- no feature UI logic allowed here

### 4. UI Layer
The `UI` layer is presentation only.

#### `RemoteFileBrowserScreen.swift`
Responsibilities:
- compose the feature screen
- own local presentation state only
- bind to injected store
- present sheets/alerts/exporters

Non-responsibilities:
- recursive transfer logic
- conflict planning
- preview loading policy
- SSH transport behavior

#### `RemoteFileBrowserMacScreen.swift`
- macOS-specific layout and AppKit wiring only

#### `RemoteFileBrowserIOSScreen.swift`
- iOS-specific layout and UIKit wiring only

#### `UI/Components/`
Split shared presentation pieces into focused files, for example:
- `RemoteFileInspectorView.swift`
- `RemoteFileToolbarView.swift`
- `RemoteFileTransferStatusView.swift`
- `RemoteFileEmptyState.swift`
- `RemoteFileFilesystemStatusCard.swift`

#### `UI/Sheets/`
- `RemoteFileRenameSheet.swift`
- `RemoteFileMoveSheet.swift`
- `RemoteFilePermissionEditorSheet.swift`
- `RemoteFileDeleteConfirmationSheet.swift`
- `RemoteFileUploadConflictSheet.swift`
- `RemoteFileCreateFolderSheet.swift`

#### `UI/Preview/`
- `RemoteTextPreview.swift`
- `RemoteImagePreview.swift`
- `RemoteVideoPreview.swift`
- `RemotePreviewUnavailableView.swift`
- `RemoteExpandedMediaPreview.swift`

#### `UI/Platform/`
- `MacOSRemoteFileTableView.swift`
- `MacOSRemoteFileSharePicker.swift`
- `IOSRemoteFileShareSheet.swift`
- `RemoteFileDragAndDropSupport.swift`
- `MacOSWindowTopInsetBridge.swift`

Rules:
- no transport logic in UI
- no recursive transfer logic in UI
- no temp-file path generation in UI
- no conflict name generation in UI

## Dependency Injection

### Target State
The Files feature should not rely on a permanent singleton store/manager.

Target composition:
- parent integration layer constructs feature dependencies
- feature screen receives injected store/service bundle
- tests can create fake services without global state

### Migration Compatibility
This refactor should not introduce temporary compatibility shims for the Files feature.

Rules:
- no temporary `shared` bridge for the new Files architecture
- no parallel old/new feature ownership
- no wrapper layer whose only purpose is preserving the legacy structure

The refactor should be implemented as a clean cutover:
- move the feature to the new structure
- update integration points to use the new composition directly
- remove the legacy Files architecture in the same refactor sequence

## Safe Refactor Migration Plan

### Phase 1: Create Feature Tree
- create `Features/RemoteFiles/`
- move current files into the feature tree with minimal logic changes
- maintain type names where possible

Expected result:
- no UI change
- no behavior change
- mostly file moves and import updates

### Phase 2: Split Domain Types
- split `RemoteFile.swift` into `Domain/*`
- keep APIs behavior-compatible
- add unit tests around path, permissions, preview detection, and sorting before further changes

Expected result:
- no UI change
- no behavior change

### Phase 3: Extract Application Layer
- replace current broad browser manager with a store + coordinators under `Application`
- move preview orchestration out of the screen
- move transfer orchestration out of the screen

Expected result:
- no intentional UI change
- no intentional workflow change

### Phase 4: Extract Infrastructure Layer
- add `RemoteFileService`
- implement `SFTPRemoteFileService`
- add temp-storage and conflict services
- move SFTP-specific feature logic out of the broad UI-facing layer

Expected result:
- no UI change
- behavior preserved unless a correctness issue requires explicit change

### Phase 5: UI Decomposition
- split `RemoteFileBrowserView`, component, and support files into `UI/*`
- preserve layouts and controls
- reduce code-behind in screen files

Expected result:
- no intentional visual change
- same UI structure with smaller files

### Phase 6: Final Integration Cleanup
- ensure feature boundary is injected cleanly from app integration points

Expected result:
- only the new feature-first Files architecture remains
- no legacy compatibility layer remains in the codebase

## Required Safety Checks

### UI Parity
The following must remain visually/functionally equivalent before and after the refactor:
- Files tab selection and entry point
- current toolbar items and menus
- current list/table behavior
- current inspector structure
- current sheet triggers and dismissal behavior
- current iOS/macOS split of responsibilities

### Behavior Parity
The following must remain equivalent:
- initial path selection order
- refresh behavior
- hidden-file filtering
- sorting semantics
- preview load behavior
- drag/drop routes
- rename/move/delete/upload/permissions flows

### Temporary File Safety
This refactor should centralize temporary-file ownership. That is a structural/safety improvement and is allowed within the safe-refactor scope because it does not require UI changes.

### Overwrite Policy
This refactor may centralize overwrite and conflict behavior structurally, but should avoid broad user-facing workflow changes unless the existing behavior is clearly unsafe or incorrect.

If a behavior correction is required:
- keep UI unchanged where possible
- isolate the change to the minimal operation path
- document it in the release notes or follow-up issue

## Testing Plan

### Unit Tests
Create:
`VVTermTests/Features/RemoteFiles/`

Add tests for:
- `RemoteFilePathTests`
- `RemoteFilePermissionTests`
- `RemoteFilePreviewDetectorTests`
- `RemoteFileSortTests`
- `RemoteFileBrowserStoreTests`
- `RemoteFileTransferCoordinatorTests`
- `RemoteFilePreviewCoordinatorTests`
- `RemoteFileConflictResolverTests`
- `RemoteFileTemporaryStorageTests`

### UI / Integration Tests
Verify:
- Files screen still opens from server tabs
- macOS and iOS still render current Files UI correctly
- preview still opens from current interactions
- existing mutation sheets still appear from the same actions
- drag/drop still routes correctly
- switching between Terminal and Files still preserves state

### Refactor Regression Checks
For each migration phase:
- build macOS and iOS targets
- smoke-test Files on both platforms
- compare screenshots or manual behavior checklist for parity

## Rollout
- land in multiple small PRs
- prefer compile-stable file moves first
- add tests early
- keep UI and behavior changes out of the structural PRs unless unavoidable
- do a direct cutover to the new Files architecture instead of keeping compatibility adapters

## Decisions
- This refactor adopts a feature-first structure for the Files feature.
- The refactor is explicitly structural and should preserve current UI and behavior by default.
- Dependency injection is the target end state for the feature boundary.
- Temporary compatibility shims are not part of the plan; the Files feature should be cut over directly to the new structure.
- No new Files UX should be introduced as part of this refactor.
