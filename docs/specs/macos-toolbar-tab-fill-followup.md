# macOS Toolbar Tab Strip — Edge-to-Edge Fill Follow-Up

Draft date: 2026-06-19
Status: Draft / not implemented
Depends on: `docs/specs/macos-native-tab-strip-and-shortcuts.md`

## Why this doc exists

The shared tab chrome (`Core/UI/ServerTabChrome.swift`) now sizes individual
tabs like a browser (equal width, capped, shrink, then scroll) and gives the
strip a content-driven ideal width so it claims more toolbar space as tabs are
added. That is the best a pure SwiftUI `.toolbar` item can reliably do today.

What pure SwiftUI cannot do reliably, and why exact Safari behavior is still
out of reach without one of the options below:

- A `ToolbarItem(placement: .navigation)` with `.frame(maxWidth: .infinity)`
  is **not** stretched by the macOS toolbar to fill the gap up to the trailing
  `.primaryAction` items. The toolbar grants the item roughly its *ideal*
  width and leaves the slack as empty space between the leading and trailing
  groups.
- A `ToolbarSpacer(.flexible)` *would* consume that slack, but it puts the
  empty space into the spacer, not into the tabs — so the tabs do not get
  wider. (This is the "flexible spacer steals the width" failure we already
  rejected.)
- There is **no public SwiftUI API** to set an `NSToolbarItem`-style
  `visibilityPriority`, force an item to stay out of the `»` overflow menu, or
  supply a usable `menuRepresentation` for a custom-view item when it does
  overflow. (`UINavigationItem.style = .browser` is iOS-only; macOS has no
  equivalent surfaced through SwiftUI.)
- Whether the macOS toolbar *compresses* a `maxWidth: .infinity` custom item
  toward its `minWidth` (good: tabs shrink/scroll internally) or *overflows*
  it whole into `»` (bad) once its ideal no longer fits is undocumented and
  version-dependent. We keep `minWidth` small to bias toward compression, but
  it is not guaranteed.

Net: the strip fills "as much as SwiftUI allows," but for **many tabs on a very
wide window** the strip caps at its ideal width and leaves a gap, and on a
narrow window the whole item can still be pushed into `»` instead of scrolling.

Two options below close the gap. **Option A is now implemented** (see status
on its heading); **Option B is not** and is kept here as the fallback if Option
A's measurement proves unreliable across window states. Both need on-device
visual iteration to confirm.

## Hard constraints both options must respect

- No `SwiftUI.BarAppearanceBridge` crash. The crash came from installing or
  replacing `window.toolbar` from inside a SwiftUI view / `NSViewRepresentable`
  hosted by `ConnectionTabsView`. Do not do that.
- Do not use `NSTitlebarAccessoryViewController(.bottom)`.
- Do not use native `NSWindow` tabs. VVTerm tabs are per *selected server*
  runtime tabs, not whole windows. The terminal/file tab managers remain the
  source of truth.
- Keep the toolbar groups visually separated:
  `[view switcher] [tabs] [files if active] [zen] [server menu]`.
- Sidebar toggle stays in sidebar/window chrome, not the connected-server tab
  strip.
- Selected tab stays a real Liquid Glass inner capsule (height
  `toolbarTabCapsuleHeight`), never a full-height background.
- Preserve Zen Mode behavior and the focused `ServerViewTabActions` routing.

## Option A — Read-only width-measurement bridge (IMPLEMENTED 2026-06-19)

Keep the SwiftUI-owned `.toolbar`. Add a **read-only** geometry probe (never
mutates `window.toolbar`, never registers bar-appearance observers) that
measures the real available gap and pins the strip's width to it. This is the
same class of bridge already used by `MacOSZenWindowChromeBridge` in
`ConnectionTabsView.swift` (it only reads window geometry and writes a binding
with a change threshold).

Implemented as `ToolbarTabStripLayoutModel` + `ToolbarTabStripLeadingProbe` in
`Core/UI/ServerTabChrome.swift`, owned as a `@StateObject` in
`ConnectionTerminalContainer` and threaded through `TerminalTabsScrollView` /
`RemoteFileTabsScrollView`. The probe is a leading-aligned 1pt background so
`convert(bounds, to: nil).minX` is unambiguously the strip's left edge (a
center-aligned probe would report mid-X). The strip falls back to its
content-driven ideal width until the geometry has been measured.

### Mechanism (window width minus a fixed trailing reserve)

- A shared `ToolbarTabStripLayoutModel: ObservableObject` holds `leadingX`
  (the strip's leading edge, window points) and `windowWidth`.
- One probe — a 1pt leading-aligned `.background` of the strip — reports
  `convert(bounds, to: nil).minX` and `window.frame.width` on layout and on
  `NSWindow` resize/move/key notifications.
- `availableWidth = windowWidth - leadingX - trailingReserve`, where
  `trailingReserve` is a fixed per-view constant covering the trailing buttons
  plus the window's right inset (`ConnectionTerminalContainer`
  `terminalTrailingReserve` / `filesTrailingReserve`).
- The strip uses `.frame(width: min(naturalContentWidth, availableWidth))`,
  falling back to the content-driven `idealWidth` until measured.

### Why it does NOT measure the trailing buttons' live position

The first implementation measured a second probe on the leading edge of the
first trailing button and set the strip to fill up to it. That **fed back into
a runaway**: growing the strip pushed the trailing buttons toward the `»`
overflow; once overflowed, the trailing probe measured them further right, so
the strip grew more — and every trailing button ended up in `»`.

Window width and the strip's leading edge are both independent of the strip's
width, so `availableWidth` here is a genuine fixed point. A generous
`trailingReserve` guarantees the strip never grows under the trailing buttons,
so they never overflow. Recompute happens only on the window notifications
above, with a 0.5pt threshold (same pattern as the Zen bridge).

### Risks / why it still needs visual iteration

- `trailingReserve` is an estimate, not a measurement. Too small → buttons can
  still overflow; too large → a slightly bigger gap before the trailing
  buttons. It is biased generous (overflow is the worse failure) and is a
  one-line tune in `ConnectionTerminalContainer`.
- The content-driven natural width keeps the per-tab `maximumTabWidth` cap
  meaningful: the strip shrinks to fit its tabs, so a few tabs do not leave an
  empty region *inside* the strip — the leftover space sits *after* the strip,
  before the trailing buttons (matching the spec's "few tabs leave toolbar
  space").

### Scope

- `Core/UI/ServerTabChrome.swift`: the model + leading probe + `trailingReserve`
  on `ServerToolbarTabStrip` (drives `explicitWidth`).
- `ConnectionTabsView.swift`: owns the `@StateObject` model, passes it and the
  per-view `trailingReserve` into the terminal/file strips. The tab toolbar
  item drops its `maxWidth: .infinity` so the item sizes to the fixed-width
  strip rather than centering it.
- `RemoteFiles/UI/Components/RemoteFileTabChrome.swift`: threads `layoutModel`
  and `trailingReserve` through `RemoteFileTabsScrollView`.

## Option B — AppKit-owned window with a real `NSToolbar` (larger)

The deterministic, fully native-feeling path. Larger architecture work; do not
start without an explicit request.

### Shape

1. Create an AppKit `NSWindowController` that owns the window.
2. Set `window.toolbar = NSToolbar(...)` **before** SwiftUI content is hosted —
   in the controller, never from inside a hosted SwiftUI view. This is the key
   difference from the crashing approach.
3. Host the SwiftUI detail content with an `NSHostingController`, and **remove**
   the SwiftUI `.toolbar` from `ConnectionTabsView` so the two toolbars do not
   fight (no bar-appearance observer churn → no crash).
4. Toolbar item layout:
   - fixed `NSToolbarItem`s for the view switcher, files menu, Zen, server menu
   - one **expandable** custom `NSToolbarItem` (or a centered tracking item)
     hosting the SwiftUI tab strip via `NSHostingView`; give it a high content
     hugging/expansion priority so AppKit stretches it to fill the gap
   - a real overflow `menuRepresentation` on the tab item so a `»` collapse
     still lets the user switch tabs
5. Keep the per-server runtime tab model exactly as-is. The `NSToolbar` only
   renders the strip for the currently selected server/mode; selection still
   flows through `TerminalTabManager` / `RemoteFileTabManager` and
   `ServerViewTabActions`.

### Why this gets exact Safari behavior

- `NSToolbar` natively stretches a flexible item to the available width and
  has first-class overflow with a working menu representation — the two things
  SwiftUI does not expose.

### Cost

- App composition root changes (window ownership), bridging focused commands
  and Zen Mode chrome into the AppKit-owned window, and re-verifying every
  toolbar interaction and the title-bar buttons. Plan a dedicated branch.

## Recommendation / status

1. **Done:** the SwiftUI per-tab tuning and **Option A** (read-only measurement
   bridge) are implemented and build clean.
2. Verify Option A on real windows: 1 / 2 / 4 / 10 tabs, wide and narrow, in
   both Terminal and Files, plus full-screen and dragging the window between
   displays. Confirm the strip fills up to the trailing buttons, shrinks then
   scrolls internally past many tabs, and never collapses into `»`.
3. Reach for **Option B** only if Option A's measurement proves unreliable in
   any of those states. Option A falls back to the ideal-width behavior whenever
   a measurement is missing or the two probes report from different windows, so
   the failure mode is "the gap comes back," not a crash or overflow.
