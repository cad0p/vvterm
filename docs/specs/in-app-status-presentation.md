# In-App Status and Notification Presentation (Draft Spec)

Draft date: 2026-04-07

## Summary
Refactor VVTerm's in-app status and notification presentation into a small shared system with:
- a consistent taxonomy
- shared visual primitives
- explicit ownership boundaries
- predictable placement rules

This is primarily a structural and presentation-architecture refactor.

The goal is not to add more toast types. The goal is to reduce ad hoc overlays and make status presentation stable as the app grows.

## Problem
VVTerm currently has multiple overlapping ways to communicate status:
- large center cards
- compact top banners
- bottom transfer cards
- local one-off error overlays
- native alerts for some cases

These patterns were added incrementally inside feature views. As a result:
- similar states are shown differently in different places
- placement is chosen locally instead of by product-wide rules
- terminal and split-terminal implementations duplicate the same presentation logic
- feature code mixes status semantics with view layout
- there is no shared replacement/coalescing policy
- there is no obvious place to add future statuses like sync state, background transfers, or workspace-level errors

This makes the UI feel inconsistent and makes the code harder to scale safely.

## Current State

### Existing presentation surfaces
- App-shell initial connect empty state on iOS:
  - `VVTerm/App/iOS/iOSContentView.swift`
  - `connectingStateView(serverName:)`
- Terminal blocking and progress overlays:
  - `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift`
  - `stateOverlayLayer`
  - `progressOverlayLayer`
  - `topBannerOverlayLayer`
  - `errorOverlayLayer`
- Split-terminal duplicate status stack:
  - `VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift`
- Terminal-specific banner and progress components:
  - `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalStatusCard.swift`
  - `VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift`
  - `TerminalTopBannerView`
  - `TerminalRichPasteProgressOverlay`
  - `TerminalRichPasteBannerOverlay`
- Files transfer overlay:
  - `VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift`
  - `TransferStatus`
  - `performTransfer(...)`
  - `RemoteFileTransferStatusView`
- Offline banner utility:
  - `VVTerm/Core/UI/OfflineBanner.swift`
  - currently not integrated into app root presentation

### Current inconsistency examples
- Reconnecting is shown as a large center card in some terminal paths and as a compact top banner in others.
- Rich paste owns a private banner/progress system instead of using a shared terminal or app-level presenter.
- Files uploads/downloads use a custom bottom overlay unrelated to terminal progress UI.
- Terminal errors can appear in a lightweight bottom overlay while connection failures use a center card.
- Offline infrastructure exists, but there is no common host for app-wide persistent status.

### Root cause
The current issue is not only visual inconsistency. It is ownership inconsistency.

Today, leaf views decide all of the following at once:
- what the status means
- whether it blocks interaction
- where it appears
- how long it lives
- how it is styled

That coupling does not scale.

## Goals
- Define a small, explicit taxonomy for in-app status presentation.
- Use one stable placement rule per status category.
- Separate screen-blocking state from non-blocking notices.
- Consolidate duplicated terminal and files presentation code.
- Keep shared primitives in `Core` and keep feature-specific policy in features.
- Preserve current flows unless a behavior change is required for consistency or correctness.
- Make status presentation testable without rendering whole screens.

## Non-Goals
- Replacing system notifications outside the app.
- Replacing native `alert` and `confirmationDialog` with custom UI.
- Redesigning terminal, files, or server list layouts.
- Introducing a generic queue of arbitrary toasts for every feature.
- Solving background transfer architecture in this spec.

## Platform Guidance
Apple does not provide a single generic "toast" pattern for all in-app messaging.

The relevant platform guidance is:
- alerts are for important, interruptive, actionable situations
- modality should be used sparingly
- progress should be shown consistently and be determinate when possible
- loading should prefer inline or context-aware presentation over unnecessary interruption

Relevant HIG pages:
- `https://developer.apple.com/design/human-interface-guidelines/alerts`
- `https://developer.apple.com/design/human-interface-guidelines/modality`
- `https://developer.apple.com/design/human-interface-guidelines/progress-indicators`
- `https://developer.apple.com/design/human-interface-guidelines/loading`

Product interpretation for VVTerm:
- not every status should become a toast
- routine success should usually not interrupt
- persistent degraded state belongs in a stable inline/banner region
- user-initiated operation progress belongs near the bottom edge of the active surface
- full-screen or center-card blocking UI should be reserved for states where the screen cannot meaningfully operate

## Proposed Taxonomy

### 1. Blocking Screen State
Use when the primary surface cannot currently function.

Examples:
- initial connection before a terminal exists
- disconnected terminal with primary recovery action
- terminal startup failure
- fatal file browser load state where content cannot be shown

Presentation:
- center card or full empty-state presentation
- may disable underlying interaction
- may include primary action like `Retry`

Rules:
- this is not a toast
- this remains screen-owned state
- use a shared blocking-state component, not a global notification center

### 2. Persistent Top Banner
Use for non-blocking ongoing status or degraded mode.

Examples:
- reconnecting after the terminal has already been established
- SSH fallback for a Mosh session
- offline app-wide state
- sync paused or degraded cloud state

Presentation:
- top safe-area inset
- compact height
- non-modal
- optional dismiss action only when the state is informational rather than essential

Rules:
- one banner lane per host
- reconnecting should always use this lane once content already exists
- banner content should be concise and action-light

### 3. Bottom Operation Notice
Use for user-initiated work in progress and near-term completion/error for that same work.

Examples:
- upload
- download
- transfer
- install tmux
- install mosh-server
- rich paste upload or preparation

Presentation:
- bottom safe-area inset
- compact card
- determinate progress when available
- optional completion state in the same card

Rules:
- one operation lane per host
- the same lane shows start, progress, completion, and operation-level failure
- success should usually auto-dismiss
- routine completion should not also generate a second banner

### 4. Native Alert / Confirmation Dialog
Use only for decisions, destructive actions, permissions, or important interruptions.

Examples:
- delete confirmation
- install prompt
- permission denial explanation with immediate acknowledgement

Rules:
- do not use alerts for routine connectivity or progress status
- do not use alerts for "success"

### 5. Inline Validation / Field Feedback
Use inside the local form or control.

Examples:
- invalid folder name
- rename validation
- theme import validation

Rules:
- keep local to the form
- do not route through shared notice infrastructure

## Mapping Current VVTerm States

| Current state | Target category | Notes |
| --- | --- | --- |
| Initial connect before terminal exists | Blocking Screen State | Keep center presentation |
| Reconnecting after terminal already existed | Persistent Top Banner | Remove center reconnect card in this case |
| SSH fallback / degraded transport | Persistent Top Banner | Same lane as reconnect status |
| Rich paste progress | Bottom Operation Notice | Merge into shared operation lane |
| File upload/download progress | Bottom Operation Notice | Replace custom Files-only presenter with shared primitive |
| Install tmux / install mosh | Bottom Operation Notice | Same operation lane as other long-running tasks |
| Disconnected with retry | Blocking Screen State | Not a toast |
| Connection failed | Blocking Screen State | Not a banner |
| Offline app state | Persistent Top Banner | App/root host |
| Operation-specific failure after action started | Bottom Operation Notice | With optional retry/action when meaningful |
| Delete / install prompts | Native Alert / Confirmation Dialog | Keep native |

## Architectural Direction

### Core principle
Separate status semantics from status rendering.

Feature/application code should declare:
- scope
- category
- content
- lifetime
- progress
- actions

Shared UI infrastructure should decide:
- visual component
- placement
- transition
- spacing
- replacement behavior within a lane

### Shared vs local ownership
Not all status should go through one global bus.

The recommended split is:
- blocking screen states remain local to the owning feature/screen
- non-blocking top and bottom notices use shared models and shared hosts

This preserves clarity:
- terminal connectivity state still belongs to terminal/session features
- file transfer state still belongs to Files
- app-wide offline state belongs to app/root
- visuals and placement are still unified

## Proposed Structure

```text
VVTerm/
├── Core/
│   └── UI/
│       └── Notices/
│           ├── NoticeModels.swift
│           ├── NoticeHost.swift
│           ├── NoticeBannerView.swift
│           ├── OperationNoticeView.swift
│           ├── BlockingStatusView.swift
│           └── NoticeStyle.swift
├── App/
│   ├── NoticeAppHost.swift
│   └── ...
└── Features/
    ├── TerminalSessions/
    │   └── ...
    └── RemoteFiles/
        └── ...
```

### Shared core models
Proposed model shape:

```swift
enum NoticeLane {
    case topBanner
    case bottomOperation
}

enum NoticeLevel {
    case info
    case success
    case warning
    case error
}

enum NoticeLifetime {
    case persistent
    case autoDismiss(Duration)
}

struct NoticeProgress: Equatable {
    var completedUnitCount: Int?
    var totalUnitCount: Int?
}

struct NoticeAction: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let role: ButtonRole?
    let handler: @MainActor @Sendable () -> Void
}

struct NoticeItem: Identifiable {
    let id: String
    let lane: NoticeLane
    let level: NoticeLevel
    let title: String?
    let message: String
    let progress: NoticeProgress?
    let lifetime: NoticeLifetime
    let action: NoticeAction?
    let dismissAction: (() -> Void)?
}
```

### Shared host and host model
`NoticeHost` is the shared renderer for top and bottom lanes.

It should support two driving modes:
- direct state-driven input from the owning screen
- lightweight imperative updates through a scoped host model

This split is intentional.

State-driven screens:
- terminal reconnect and fallback status are derived from connection state
- app-level offline state is derived from `NetworkMonitor`

Imperative flows:
- file transfer progress updates over time
- future background-like operation flows that need explicit replacement by id

Use a lightweight host model per presentation scope, not one singleton queue for the whole app.

```swift
struct NoticeHost<Content: View>: View {
    let topBanner: NoticeItem?
    let bottomOperation: NoticeItem?
    let content: Content
}
```

Optional scoped model:

```swift
@MainActor
@Observable
final class NoticeHostModel {
    var topBanner: NoticeItem?
    var bottomOperation: NoticeItem?

    func show(_ item: NoticeItem)
    func dismiss(id: String)
    func update(id: String, progress: NoticeProgress?, message: String)
}
```

Rules:
- one visible item per lane per host
- updates replace by `id`
- equivalent repeated banners may be coalesced
- operation notices update in place rather than stacking
- features should not be forced through `NoticeHostModel` when the notice is already a pure function of screen state

## Shared View Primitives

### `BlockingStatusView`
Purpose:
- reusable center-card or empty-state style for blocking states

Source material today:
- `TerminalStatusCard`
- iOS `connectingStateView`

Notes:
- this should absorb the useful parts of `TerminalStatusCard`
- name should reflect that it is not terminal-specific

### `NoticeBannerView`
Purpose:
- compact top banner with optional icon, spinner, and dismiss action

Source material today:
- `TerminalTopBannerView`
- `OfflineBanner` visual direction

### `OperationNoticeView`
Purpose:
- bottom card for progress, completion, and operation-scoped failure

Source material today:
- `RemoteFileTransferStatusView`
- `TerminalRichPasteProgressOverlay`
- tmux/mosh install overlays

## Visual Direction

The system should look like one family of surfaces with three sizes, not three unrelated components.

### Shared styling principles
- use one corner radius family and one border treatment across banners and cards
- use semantic tint only for the icon/spinner/accent, not for all text
- prefer mostly opaque terminal-aware surfaces over glass when drawn above terminal content
- prefer system background or material styling on non-terminal surfaces
- keep copy short and action count low

### Top banner
- compact, stable strip inset from the top safe area
- roughly 36 to 44pt tall on iPhone, slightly roomier on macOS
- leading spinner or icon, one concise line of copy, optional lightweight action or dismiss button
- should feel persistent and quiet, not celebratory

### Bottom operation notice
- compact rounded card above the bottom safe area
- supports title, short message, optional detail, progress, and one action
- should update in place across start, progress, completion, and operation failure
- success should briefly settle in the same card, then dismiss

### Blocking status card
- centered lightweight status card, not a sheet
- used only when the screen cannot yet function
- title, short explanation, spinner or icon, optional primary action
- wider on macOS, but visually the same family as iOS

### Platform differences
- iOS should use tighter spacing and safe-area-first placement
- macOS can use slightly wider cards and more breathing room against window chrome
- terminal surfaces on both platforms must avoid translucent glass directly over terminal content
- the system should be recognizably the same on both platforms without being pixel-identical

## Presentation Hosts

### App host
Attach near app root:
- iOS root around `iOSContentView`
- macOS root around `ContentView`

Use for:
- offline
- sync paused/degraded
- future app-wide account/store/sync notices

### Terminal host
Attach inside:
- `TerminalContainerView`
- `TerminalView`

Use for:
- reconnecting banner
- fallback banner
- operation notices for tmux/mosh install and rich paste

Implementation note:
- terminal hosts should usually be driven directly by computed `NoticeItem?` values
- only use a host model here if a terminal flow becomes imperative enough to need it later

### Files host
Attach inside:
- `RemoteFileBrowserScreen`

Use for:
- upload/download/transfer progress
- transfer completion
- transfer failure

Implementation note:
- Files is the primary example of a scoped `NoticeHostModel` because transfers update by id over time

## Feature Integration Rules

### TerminalSessions
- keep `disconnected` and `failed` as blocking states
- keep initial terminal boot as blocking state
- treat reconnect after first successful connection as a top banner only
- move rich paste banner/progress into the shared notice host
- remove terminal-specific duplicate top/bottom presenter types after migration

### RemoteFiles
- replace `TransferStatus` screen-local presenter with shared bottom operation notice primitives
- keep destructive decisions in native alerts/sheets
- keep create/rename/move form validation local to forms

### App / Network / Sync
- replace standalone offline banner utility with app-host banner integration
- app-wide network and sync states must not compete with screen-local operation notices
- app-level notices should live only in the app host's top lane

## Behavior Rules

### Reconnect behavior
- Before terminal exists:
  - blocking center state allowed
- After terminal exists:
  - reconnect uses top banner
  - no center reconnect card

### Success behavior
- Default: do not show a generic success toast if the UI already makes the outcome clear
- Operation lane may briefly show completion if:
  - the result is not obvious from surrounding content
  - there is a useful follow-up action

Examples:
- file download export ready: allowed in bottom operation lane
- upload complete while file list visibly refreshed: brief completion allowed, separate top banner not needed
- reconnect success: no success toast

### Error behavior
- Blocking failures:
  - center state with action
- Non-blocking operation failures:
  - bottom operation lane
- Destructive confirmations or permission decisions:
  - native alert/dialog

## Migration Plan

### Phase 1: Extract shared primitives
- Create `Core/UI/Notices/`.
- Move or adapt:
  - `TerminalStatusCard` -> `BlockingStatusView`
  - `TerminalTopBannerView` -> `NoticeBannerView`
  - shared visual pieces from `RemoteFileTransferStatusView` -> `OperationNoticeView`
- Do not change feature behavior yet.

### Phase 2: Introduce `NoticeHostModel` and `NoticeHost`
- Add `NoticeHost` as the shared top/bottom lane renderer using `safeAreaInset`.
- Add a simple optional host model with:
  - `topBanner`
  - `bottomOperation`
- Add preview fixtures for each lane.

### Phase 3: Migrate terminal container
- Replace `topBannerOverlayLayer` and `progressOverlayLayer` with shared notice host lanes.
- Keep blocking states local.
- Convert reconnect, fallback, tmux install, mosh install, and rich paste progress/banner into typed notices.

### Phase 4: Migrate split terminal
- Remove duplicated overlay implementation from `TerminalView`.
- Reuse the same terminal notice primitives and policies as `TerminalContainerView`.

### Phase 5: Migrate Files
- Replace `TransferStatus` and `RemoteFileTransferStatusView` plumbing with shared bottom operation notices.
- Preserve current transfer logic and timing behavior.

### Phase 6: Add app/root host
- Integrate offline and future sync notices at the app/root level.
- Retire `OfflineBanner.swift` or reduce it to a style helper if useful.

### Phase 7: Cleanup
- Remove terminal-specific presenter duplication.
- Remove dead banner/progress types that are superseded by shared primitives.
- Add documentation comments describing lane rules.

## Testing Strategy

### Unit tests
- mapping tests for connection state -> blocking state vs banner
- operation notice update/coalescing tests
- auto-dismiss behavior tests
- replacement-by-id tests

### UI tests
- reconnect after established session shows top banner, not center card
- upload/download progress appears in bottom lane
- connection failure still shows blocking retry state

### Preview coverage
- banner info/warning/error
- operation progress, success, and failure
- blocking connecting/disconnected/failed states

## Risks
- Over-centralizing true screen state into a generic notice bus
- Breaking safe-area behavior around terminal chrome, navigation bars, and keyboard accessories
- Losing contextual actions during migration if notice actions are over-simplified
- Treating multiple concurrent operations as one lane when feature requirements actually need a queue later

## Open Questions
- Should the operation lane stay single-item in V1, or should Files reserve the option for a future transfer queue UI?
- Should app-wide offline always be shown, or only when the current feature requires network?
- Should operation failure always remain in the bottom lane, or should some failures escalate to blocking state when the owning screen cannot recover?

## Recommended First Cut
The first implementation cut should be:
- shared top banner
- shared bottom operation notice
- shared blocking status card
- terminal reconnect policy cleanup

That gets the biggest consistency win quickly without introducing a heavyweight global notification system.
