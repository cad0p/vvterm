# macOS Native-Feeling Tab Strip and Tab Shortcuts

Draft date: 2026-06-17
Status: Draft

## Summary

Rework the existing macOS terminal and file tab strips so they feel like native Mac/Safari-style tabs while preserving VVTerm's current session architecture.

This is a presentation and command-surface improvement. It should not replace terminal tabs with `NSTabViewController`, native window tabs, or a new session model. The current terminal/file tab managers remain the source of truth.

The first implementation should cover:

- adaptive macOS tab widths
- overflow scrolling once tabs reach a minimum width
- smooth tab chrome animation
- consistent terminal-tab and file-tab behavior
- Safari-like keyboard shortcuts for next/previous tab
- Zen Mode parity for tab navigation

Shortcut remapping, server navigation shortcuts, and a server spotlight/palette are intentionally deferred to a later spec.

## Current Baseline

### macOS Commands

`VVTerm/App/VVTermApp.swift` defines the current app command surface:

- `Cmd+T`: New Tab
- `Cmd+W`: Close Tab
- `Shift+Cmd+[`: Previous Tab
- `Shift+Cmd+]`: Next Tab

These commands route through `ServerViewTabActions`, which are provided by the focused `ConnectionTerminalContainer`. The action target is view-aware:

- when `selectedView == ConnectionViewTab.files.id`, commands apply to file tabs
- otherwise commands apply to terminal tabs

This focused command routing is correct and should be preserved.

### macOS Terminal Tabs

`VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift` owns the macOS terminal tab strip:

- `TerminalTabsScrollView`
- `TerminalTabButton`

The strip currently has:

- previous/next arrow buttons
- horizontal `ScrollView`
- tab pills
- close buttons
- new-tab button

The main sizing bug is explicit:

```swift
.frame(maxWidth: 600, maxHeight: 36)
```

This means the strip stops growing even when the toolbar has enough room.

### macOS File Tabs

`VVTerm/Features/RemoteFiles/UI/Components/RemoteFileTabChrome.swift` owns the macOS file tab strip:

- `RemoteFileTabsScrollView`
- `RemoteFileTabButton`

It mirrors terminal tab structure and has the same `maxWidth: 600` cap.

### iOS Tab Sizing Reference

iOS already has the right sizing model in:

- `iOSTerminalTabsBar`
- `iOSRemoteFileTabsBar`

The algorithm is:

1. measure available width with `GeometryReader`
2. subtract horizontal padding
3. subtract inter-tab spacing
4. divide the remaining width equally by tab count
5. use equal widths if the result is at least the minimum tab width
6. otherwise fall back to a horizontal scroll layout with minimum-width tabs

The macOS implementation should adapt this behavior for toolbar constraints instead of inventing a separate sizing rule.

### Shared Chrome

`VVTerm/Core/UI/ServerTabChrome.swift` already owns shared controls and metrics:

- `ServerViewTabNavigationButton`
- `ServerViewNewTabButton`
- `ServerViewTopTabBarMetrics`

This is the right place for shared style-only primitives or shared adaptive sizing helpers if the implementation needs them.

### Zen Mode

Zen Mode uses separate controls in `MacOSZenModePanel`, but it calls back into the same selection and tab-management closures:

- `onPreviousTab`
- `onNextTab`
- `onNewTerminalTab`
- `onCloseTerminalTab`
- `onNewFileTab`
- `onCloseFileTab`
- `onSelectFileTab`

Zen Mode should not reuse the toolbar tab strip UI. It should keep its panel/list presentation while sharing the same tab navigation semantics.

## Goals

1. Make macOS terminal and file tabs consume available toolbar width.
2. Make tab widths adapt like browser tabs:
   - grow to fill available space when tab count is low
   - shrink evenly as tab count grows
   - scroll only after tabs reach a minimum usable width
3. Remove the hard `600px` cap from both macOS tab strips.
4. Keep terminal tabs and file tabs visually and behaviorally consistent.
5. Add Safari-like `Control+Tab` and `Control+Shift+Tab` shortcuts for tab navigation.
6. Preserve existing shortcuts and focused routing.
7. Keep Zen Mode tab navigation working through the same actions.
8. Respect Reduce Motion for tab chrome animation.
9. Avoid terminal surface churn during tab strip layout and animation.

## Non-Goals

- Do not add shortcut remapping UI in this task.
- Do not add server navigation shortcuts in this task.
- Do not add a server spotlight/palette in this task.
- Do not replace app-owned terminal tabs with AppKit window tabs.
- Do not redesign the main toolbar, sidebar, server menu, settings window, or Zen Mode panel.
- Do not change Pro entitlement behavior.
- Do not change terminal/file tab persistence.
- Do not change iOS tab behavior except for shared helper extraction that preserves current output.
- Do not pass `Control+Tab` through to the terminal when it is assigned to app tab switching. This is a deliberate app-level shortcut, matching browser-style tab navigation.

## Product Behavior

### Adaptive Width Rules

Use one shared sizing policy for macOS terminal and file tabs.

Suggested initial constants:

- minimum tab width: `120`
- preferred maximum tab width: `220...240`
- inter-tab spacing: `ServerViewTopTabBarMetrics.tabSpacing`
- inner horizontal padding: `ServerViewTopTabBarMetrics.horizontalPadding`
- tab height: current macOS height, aligned with existing toolbar height

Algorithm:

```swift
availableTabWidth = containerWidth
    - leadingNavigationWidth
    - trailingNewButtonWidth
    - outerPadding
    - totalInterItemSpacing

candidateWidth = (availableTabWidth - totalTabSpacing) / tabCount
resolvedWidth = min(candidateWidth, maxTabWidth)

if resolvedWidth >= minTabWidth {
    render non-scrolling HStack with fixed width resolvedWidth
} else {
    render horizontal ScrollView with each tab minWidth minTabWidth
}
```

When `tabCount == 1`, the tab should not become comically wide. Cap it with `maxTabWidth`.

When there is unused space after applying `maxTabWidth`, align tabs leading and leave the remaining toolbar space to the rest of the toolbar.

When there is not enough space for even minimum tabs, the tab area scrolls horizontally.

### Toolbar Space Ownership

The tab strip should be allowed to grow inside the toolbar. The implementation should not use a fixed maximum width.

If SwiftUI toolbar item measurement prevents reliable expansion, use a small macOS bridge or a top-level `GeometryReader`-backed view inside the toolbar item, but keep it local to tab chrome. Do not move terminal tabs out of the toolbar as part of V1 unless toolbar measurement proves impossible.

### Selection and Overflow

Selecting a tab should:

- update the same selected tab binding currently used by terminal/file tabs
- keep the selected tab visible when the strip is scrollable
- avoid recreating terminal surfaces

If SwiftUI `ScrollViewReader` is reliable inside the toolbar, use it to scroll the selected tab into view when:

- selection changes
- a new tab is created
- a tab is closed and adjacent selection moves

Scrolling should be minimal, not a large animated jump. Respect Reduce Motion.

### Animation

Animate only tab chrome:

- width changes during window resize
- selected-state background transition
- insertion/removal layout changes
- hover/close affordances

Do not animate:

- terminal content opacity beyond current behavior
- Ghostty surface creation/destruction
- file browser content reloads
- Zen Mode entering/exiting beyond existing behavior

Use `@Environment(\.accessibilityReduceMotion)` in the tab strip or shared helper:

- Reduce Motion off: short smooth animation, roughly `0.12...0.18s`
- Reduce Motion on: no explicit tab layout animation

Avoid broad `.animation(..., value: tabs)` modifiers that animate unrelated content. Prefer scoped transactions or explicit animation around tab strip layout values.

### Close Button Behavior

Keep close buttons on each tab.

Native-feeling refinement allowed in this task:

- selected tab: close button visible
- hovered tab: close button visible
- unselected non-hovered tab: close affordance may be subtle or hidden if the hit target remains accessible by hover

Do not make the close target smaller than the current effective hit area.

### Context Menus

File tab context menus already support:

- Close Tab
- Close Other Tabs
- Close All to the Left
- Close All to the Right
- Duplicate Tab

Terminal tabs currently do not expose equivalent context menu behavior in `TerminalTabButton`.

V1 does not need to add terminal context menu parity unless it falls out naturally. The adaptive strip should not remove file tab context menus.

## Shortcuts

### Keep Existing Defaults

Keep:

- `Cmd+T`: New Tab
- `Cmd+W`: Close Tab
- `Shift+Cmd+[`: Previous Tab
- `Shift+Cmd+]`: Next Tab

### Add Safari-Like Shortcuts

Add:

- `Control+Tab`: Next Tab
- `Control+Shift+Tab`: Previous Tab

Implementation should reuse `serverViewTabActions?.selectNext()` and `serverViewTabActions?.selectPrevious()`.

Menu placement:

- Existing Previous/Next Tab commands can remain after `.windowArrangement`.
- Add duplicate menu command items only if SwiftUI allows multiple shortcuts for the same visible command cleanly.
- If SwiftUI does not support two shortcuts on one command item cleanly, add hidden or alternate command entries only if they do not clutter menus.

Preferred implementation order:

1. Try to express alternate shortcuts through menu commands.
2. If SwiftUI menu commands cannot represent both shortcut sets cleanly, use a local macOS key handling bridge scoped to the active main window and only for these tab navigation shortcuts.
3. Keep all command execution routed through `ServerViewTabActions`.

Avoid global event monitors for V1.

### Direct Numeric Tab Selection

Do not implement `Cmd+1...Cmd+9` in this task unless explicitly pulled in later.

Reason:

- terminal apps often need conservative shortcut ownership
- numeric selection is more valuable after remapping infrastructure exists
- this task is already valuable with adaptive tabs and Safari next/previous shortcuts

## Zen Mode Requirements

Zen Mode hides the normal toolbar, so the tab strip itself is not visible. Still, shortcuts and panel actions must work.

Required behavior:

- `Control+Tab` and `Control+Shift+Tab` work while Zen Mode is active.
- Existing `Shift+Cmd+[` and `Shift+Cmd+]` keep working while Zen Mode is active.
- `Cmd+T` opens a new terminal tab or file tab based on the active view.
- `Cmd+W` closes the selected terminal tab or file tab based on the active view.
- The Zen Mode panel `Previous Tab` and `Next Tab` buttons use the same selection semantics as keyboard shortcuts.
- The Zen Mode panel tab lists stay visually unchanged unless a small label/count update is needed.
- Exiting Zen Mode should reveal the normal toolbar with the selected tab still active.

Implementation note:

- Keep focused values available from `ConnectionTerminalContainer` even when `isZenModeEnabled == true`.
- Do not tie shortcut availability to the toolbar tab strip being rendered.

## Architecture

### Preferred Shape

Create a shared adaptive tab strip helper in `Core/UI` only for generic chrome/layout behavior.

Possible additions:

- `AdaptiveServerTabStrip`
- `AdaptiveServerTabSizing`
- `AdaptiveServerTabMetrics`

The helper should be generic over tab identity/content and should not know about terminal sessions or remote file tabs.

Terminal-specific and file-specific wrappers remain in their current feature files:

- `TerminalTabsScrollView`
- `RemoteFileTabsScrollView`

These wrappers provide:

- tab data
- title/status/icon content
- selection binding
- close/new callbacks
- context menus

### Avoid

- moving terminal-specific models into `Core/UI`
- making `RemoteFiles` depend on `TerminalSessions/UI`
- adding a new app-wide tab manager
- changing the tab persistence model
- duplicating the sizing algorithm in terminal and file components

### Existing Files to Touch

Expected:

- `VVTerm/Core/UI/ServerTabChrome.swift`
- `VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift`
- `VVTerm/Features/RemoteFiles/UI/Components/RemoteFileTabChrome.swift`
- `VVTerm/App/VVTermApp.swift`

Possible:

- `VVTerm/Features/TerminalSessions/UI/Splits/TerminalSplitContainerView.swift`
  - only if `ServerViewTabActions` needs direct tab-selection actions or capability flags
- localized strings
  - only if new menu item labels are introduced

Do not touch:

- terminal/session persistence
- file-tab persistence
- Store/Pro entitlement logic
- Settings shortcut UI
- server spotlight/palette code

## Implementation Plan

### Step 1: Extract Adaptive Layout Primitive

Add a reusable macOS-capable adaptive tab strip layout helper in `Core/UI/ServerTabChrome.swift` or a nearby `Core/UI` file.

The helper should accept:

- item count
- selected ID
- minimum tab width
- maximum tab width
- tab spacing
- leading controls
- trailing controls
- tab content builder

It should produce:

- non-scrolling equal-width layout when possible
- scrollable minimum-width layout when necessary
- selected-tab scroll-into-view behavior when scrollable

Keep it style-only.

### Step 2: Move Terminal Tabs Onto Adaptive Layout

Update `TerminalTabsScrollView` to use the shared adaptive layout.

Preserve:

- arrows
- plus button
- tab close behavior
- status indicator
- split pane count indicator
- selected binding

Remove:

- `.frame(maxWidth: 600, maxHeight: 36)`

Add:

- fixed/equal tab width parameter to `TerminalTabButton`
- title truncation inside fixed width
- accessibility label/value if missing

### Step 3: Move File Tabs Onto Adaptive Layout

Update `RemoteFileTabsScrollView` to use the same adaptive layout.

Preserve:

- arrows
- plus button
- close button
- folder icon
- file tab context menu
- `onSelect(tab)` side effects

Remove:

- `.frame(maxWidth: 600, maxHeight: 36)`

Add:

- fixed/equal tab width parameter to `RemoteFileTabButton`
- title truncation inside fixed width

### Step 4: Add Shortcuts

Update `VVTermCommands` to add:

- `Control+Tab` -> `selectNext`
- `Control+Shift+Tab` -> `selectPrevious`

Keep the command target routed through `serverViewTabActions`.

If SwiftUI cannot attach multiple shortcuts to the same visible command:

- keep visible menu commands with current shortcuts
- add a focused key handler bridge scoped to the main window for `Control+Tab` and `Control+Shift+Tab`
- document this in code with a short comment

### Step 5: Zen Mode Verification

Do not redesign Zen Mode.

Verify:

- shortcuts work while toolbar is hidden
- Zen panel previous/next buttons still work
- new/close tab commands still route by active view
- selected tab persists after exiting Zen Mode

Only edit Zen Mode code if the focused action surface is lost while Zen Mode is active.

## Acceptance Criteria

### Layout

- With one tab, the tab is a reasonable browser-like width and does not consume the entire toolbar.
- With two to four tabs in a wide window, tabs expand evenly and use the available area up to the max width.
- With many tabs, tabs shrink evenly until the minimum width.
- After the minimum width is reached, the tab strip scrolls horizontally.
- There is no hard `600px` cap.
- File tabs and terminal tabs follow the same width behavior.
- The trailing server/Zen/files toolbar buttons remain visible.
- Text truncates cleanly inside tabs.

### Interaction

- Clicking a tab selects it.
- Clicking close closes only that tab.
- New tab button still works.
- Previous/next arrows still work.
- File tab context menus still work.
- Selected tab remains visible in scroll overflow when navigated by keyboard or arrows.

### Shortcuts

- `Cmd+T` opens a tab in the active view.
- `Cmd+W` closes the selected tab in the active view.
- `Shift+Cmd+[` selects previous tab in the active view.
- `Shift+Cmd+]` selects next tab in the active view.
- `Control+Tab` selects next tab in the active view.
- `Control+Shift+Tab` selects previous tab in the active view.
- Shortcuts are disabled or no-op when there is no focused connection tab context.

### Zen Mode

- All tab shortcuts work while Zen Mode is active.
- Zen Mode panel tab buttons still work.
- Creating/closing/selecting tabs in Zen Mode updates the same selected tab seen after leaving Zen Mode.
- No terminal content receives glass/material treatment.
- No terminal surface is recreated due only to tab chrome animation.

### Accessibility

- Reduce Motion disables explicit tab layout animation.
- Tab buttons expose usable labels.
- Close buttons remain keyboard/accessibility reachable.
- Toolbar controls keep their existing help text or equivalent labels.

## Verification Plan

Manual checks:

1. macOS wide window with one, two, four, and ten terminal tabs.
2. macOS narrow window with ten terminal tabs.
3. Repeat the same checks in `Files`.
4. Switch between `Terminal` and `Files` and confirm each strip keeps its selection.
5. Use all tab shortcuts in normal mode.
6. Enter Zen Mode and repeat all tab shortcuts.
7. Open the Zen panel and use previous/next/new/close tab controls.
8. Close selected tabs at first, middle, and last positions.
9. Verify file tab context menu actions after adaptive layout changes.
10. Enable Reduce Motion and confirm layout changes are non-animated or minimally animated.

Automated/build checks:

- `xcodebuild` macOS Debug build for VVTerm.
- If preview/test infrastructure exists for SwiftUI views, add focused coverage for the sizing helper as pure logic.
- At minimum, unit-test the pure sizing calculation if extracted as a function.

Suggested pure sizing cases:

- zero tabs
- one tab, large container
- three tabs, large container
- many tabs, just above minimum threshold
- many tabs, below minimum threshold
- container smaller than controls

## Risks

### SwiftUI Toolbar Measurement

SwiftUI toolbar items can be difficult to measure and may not grant the child view all available width.

Mitigation:

- first try a pure SwiftUI `GeometryReader` inside the toolbar item
- if unreliable, use a small `NSViewRepresentable` measurement bridge
- keep the bridge local to tab chrome

### Shortcut Capture Conflicts

`Control+Tab` can have focus-navigation meaning in some macOS contexts.

Mitigation:

- install it as an app command only when a connection tab context is focused
- route through existing focused actions
- avoid global event monitors

### Terminal Shortcut Expectations

Some terminal users may expect every control sequence to pass through to the remote shell.

Mitigation:

- only claim browser-standard tab switching shortcuts in V1
- defer broader shortcut ownership to the remapping spec
- document this as app-level navigation behavior

### Animation Affecting Terminal Stability

Animating parent containers around `Ghostty` surfaces can cause rendering or focus issues.

Mitigation:

- animate only tab strip chrome
- keep terminal content hierarchy and IDs stable
- do not wrap terminal surface containers in new animated layout state

## Deferred Follow-Up Spec

The next task should cover:

- keyboard shortcut model
- remapping UI in Settings
- conflict detection
- reset to defaults
- server next/previous shortcuts
- focus server search
- server spotlight/palette
- Settings section navigation shortcuts

This spec should not grow to include those features.
