# Terminal Pane Zoom and Cursor Controls

Draft date: 2026-06-03
Status: Implemented

## Summary

Add presentation controls for active terminal panes:

- Pinch zoom in/out to change font size for the current terminal pane.
- Terminal settings for cursor style and cursor blink.

The main product constraint is that gesture zoom must affect the active pane only. It must not silently rewrite the global terminal font size preference.

## Current Baseline

- Terminal default font settings are stored in `TerminalDefaults`.
- `TerminalSettingsView` exposes a global font family picker and global font size control.
- `Ghostty.ConfigBuilder` writes the configured font size into Ghostty config.
- `GhosttyRenderingSetup` initializes each Ghostty surface with the current global font size.
- iOS terminal views already own terminal touch, pan, selection, keyboard focus, and scroll gesture handling.
- Ghostty config currently hardcodes cursor blink on with `cursor-style-blink = true`.
- There is no app-owned cursor style or cursor blink preference.
- There is no per-pane terminal presentation override state.

## Product Goals

1. Make pinch zoom feel like a terminal pane operation, not an app settings operation.
2. Keep settings as the place for global defaults.
3. Let users disable cursor blink.
4. Let users choose a cursor style from a small supported set.
5. Preserve current behavior by default.
6. Keep synced server metadata untouched. These are local presentation preferences and runtime pane state.

## Non-Goals

- Do not sync per-pane zoom through CloudKit.
- Do not mutate server models for font size, cursor style, or cursor blink.
- Do not make pinch zoom change the global terminal font size in V1.
- Do not add per-server or per-workspace cursor preferences in V1.
- Do not expose arbitrary Ghostty config text editing.
- Do not redesign terminal settings.
- Do not add visible zoom buttons, overflow menu actions, or keyboard shortcuts in V1.

## UX Decisions

### Pane Zoom

Pinch zoom applies to the active terminal pane only.

- Pinch out increases the current pane font size.
- Pinch in decreases the current pane font size.
- The effective range should match terminal settings: `4...32`.
- The gesture should snap to whole-point sizes unless testing shows half-point sizing is meaningfully better.
- A pinch should update only after the accumulated gesture crosses a threshold, so small finger noise does not resize text.
- The terminal should remain focused after a zoom gesture.
- The gesture should be ignored while native terminal selection is active.
- The gesture should not trigger keyboard focus by itself.
- Scroll/pan should be disabled only while an active pinch is being handled.

The current pane override should persist for the lifetime of the tab/pane. It should be cleared only when the tab/pane is closed or the terminal disconnects. If the app restores an existing tab/pane across backgrounding or restart, the restored pane should keep its runtime zoom until that tab/pane is closed or disconnected.

### No V1 Command UI

V1 should ship pinch zoom only. The goal is the gesture itself: quickly changing font size in the current tab/pane. Do not add toolbar controls, overflow menu items, or keyboard shortcuts as part of the first implementation.

### Cursor Controls

Cursor controls are global terminal presentation preferences in V1.

Add a compact Cursor section to terminal settings:

- Cursor Style: Block, Bar, Underline, Block Hollow
- Cursor Blink: On/Off

Defaults should preserve current behavior:

- Cursor style: Block, unless the current Ghostty default is different.
- Cursor blink: On.

Cursor controls should apply to all terminal panes after config reload. Existing panes should update without requiring app restart if Ghostty supports live reload for these config values.

Ghostty allows programs to request cursor style/blink using terminal escape sequences. These settings define the default app preference; terminal programs may still temporarily override the cursor while they are running.

## Technical Design

### Ownership

Use existing ownership boundaries:

- `Core/Terminal` owns shared terminal presentation defaults and pure preference types.
- `Features/Settings/UI` owns settings controls.
- `Features/TerminalSessions/Application` owns active pane/session runtime presentation state.
- `GhosttyTerminal` owns platform terminal view gesture recognition and Ghostty config application.

No server, workspace, or CloudKit sync models should be changed.

### Preference Model

Add cursor preference keys to `TerminalDefaults`:

- `terminalCursorStyle`
- `terminalCursorBlink`

Add a small typed cursor style model:

```swift
enum TerminalCursorStyle: String, CaseIterable, Codable, Identifiable {
    case block
    case bar
    case underline
    case blockHollow = "block_hollow"

    var id: String { rawValue }
}
```

Ghostty's public config reference lists `block`, `bar`, `underline`, and `block_hollow` as valid `cursor-style` values. It lists `true` and `false` as valid explicit values for `cursor-style-blink`.

### Pane Presentation State

Introduce runtime pane presentation override state rather than writing to `UserDefaults`.

Conceptually:

```swift
struct TerminalPresentationOverrides: Codable, Hashable {
    var fontSize: Double?
}
```

Effective font size:

```swift
effectiveFontSize = pane.presentationOverrides.fontSize ?? TerminalDefaults.fontSize
```

The override value belongs with local session/pane application state:

- iOS single terminal sessions: keyed by `ConnectionSession.id` or owned by the session object if that model is already local-only.
- macOS tabs/splits: keyed by the active pane/session identifier, not by server id.

The state must be local-only. It should survive normal tab/pane restoration while the tab/pane still exists, and it should be discarded on tab/pane close or disconnect.

Use a single override value instead of separate per-setting properties. Future pane-local presentation settings should extend `TerminalPresentationOverrides` rather than adding parallel manager dictionaries, wrapper callbacks, and surface properties.

### Ghostty Config

Extend config generation so it receives:

- presentation overrides for the target surface/pane
- cursor style
- cursor blink

Current global config reload is enough for cursor controls. Pane zoom should use a targeted per-surface update path.

Verified Ghostty bridge support:

- `ghostty_surface_config_s` includes `font_size` for surface creation.
- The vendored C API exposes `ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t)`.
- The current Swift wrapper already calls `ghostty_surface_update_config` for each registered surface when propagating global config reloads.

Pane zoom should add a targeted wrapper method that builds a config from `TerminalPresentationOverrides` and calls `ghostty_surface_update_config` only for the active surface. It should not call `ghostty_app_update_config` and should not loop over all active surfaces.

Do not ship pane zoom by writing `TerminalDefaults.fontSizeKey` from a pinch gesture.

### iOS Gesture Handling

Add a `UIPinchGestureRecognizer` to `GhosttyTerminalView`.

Rules:

- Recognize simultaneously with other gestures only when it does not conflict with active selection.
- While pinching, suppress terminal scroll handling.
- Do not convert a pinch into a terminal mouse/touch event.
- Emit a semantic zoom intent to the host layer, for example:

```swift
enum TerminalZoomAction {
    case zoomIn
    case zoomOut
    case reset
}
```

Avoid letting the low-level terminal view mutate app preferences directly.

### macOS Gesture Handling

macOS does not need command UI in V1. Trackpad pinch is included because it fits cleanly through the AppKit terminal view's magnification event path.

macOS trackpad magnification:

- It must target the focused pane.
- It must use the same pane runtime font-size state.
- It must not modify global settings.

### Settings UI

Update `TerminalSettingsView`:

- Keep the existing font section as global defaults.
- Add a Cursor section near font/theme presentation controls.
- Use a segmented control or picker for cursor style.
- Use a toggle for cursor blink.

Copy should be minimal and should not explain terminal behavior inline.

### Config Serialization

Expected Ghostty config shape:

```text
cursor-style = block
cursor-style-blink = true
```

Use `bar`, not `beam`, for the bar cursor. Use `block_hollow` for the hollow block cursor.

## Edge Cases

- If the current pane uses the global default and the global font size changes in settings, the pane should follow the new global default.
- If the current pane has a runtime override and the global font size changes, the override should remain until reset or pane close.
- Reset Pane Font Size should clear the runtime override and return to the current global default.
- New panes should start with the global default, not a copied override from another pane.
- Split panes should resize independently.
- Reconnecting a pane should keep its runtime override while the pane object remains alive.
- Closing a tab/pane or disconnecting should clear the runtime override.
- Restoring the same tab/pane should preserve the runtime override while that tab/pane still exists.
- Cursor settings should affect existing and future panes consistently.

## Delivery Plan

### Phase 1: Cursor Preferences

- Add `TerminalCursorStyle` and defaults.
- Extend Ghostty config generation.
- Add Terminal Settings UI.
- Verify existing panes update on preference change.

### Phase 2: Pane Zoom State

- Add local pane/session presentation state.
- Add effective font size resolution.
- Thread effective font size into Ghostty surface/config setup.
- Add zoom/reset actions at the terminal session boundary.

### Phase 3: iOS Pinch Zoom

- Add pinch recognizer to the iOS terminal view.
- Convert scale deltas into zoom actions.
- Handle selection, scroll, keyboard, and focus interactions.

### Phase 4: macOS Trackpad Pinch

- Add macOS trackpad magnification through the existing terminal view stack.
- Confirm split-pane targeting.

## Validation Plan

### Automated

- Unit-test font size clamping.
- Unit-test reset behavior.
- Unit-test cursor style config serialization.
- Unit-test cursor blink config serialization.

### Manual

- iPhone: pinch active terminal with keyboard shown.
- iPhone: pinch active terminal with keyboard hidden.
- iPhone: confirm pinch does not trigger when selection is active.
- iPhone: confirm two-finger scroll still scrolls when not pinching.
- iPad: verify pinch targets the current tab/pane.
- macOS: verify trackpad pinch targets the focused pane.
- macOS: verify split panes keep independent zoom.
- Settings: toggle cursor blink and confirm existing terminal updates.
- Settings: change cursor style and confirm existing terminal updates.
- Tab close/disconnect: confirm runtime pane zoom resets to global default.
- Tab restore: confirm runtime pane zoom persists while the same tab/pane still exists.

### Builds

- Build iOS simulator target.
- Build macOS target.

## Resolved Decisions

1. The vendored Ghostty bridge supports targeted surface config updates with `ghostty_surface_update_config`.
2. V1 zoom UI is pinch only.
3. Pane zoom persists until the tab/pane is closed or the terminal disconnects.
4. Cursor style and blink are global-only preferences.
5. Ghostty uses `bar`, not `beam`, for the bar cursor config value.
6. macOS trackpad pinch is included without adding command UI.

## References

- Ghostty config reference: https://ghostty.org/docs/config/reference
- Vendored Ghostty C header: `Vendor/libghostty/include/ghostty.h`
- Current Swift config propagation: `VVTerm/GhosttyTerminal/Ghostty.App.swift`

## Recommendation

Build cursor controls first because they fit the existing global preference/config reload path.

For pane zoom, add targeted per-surface config update support before adding the pinch recognizer. The expected model is current pane zoom, and global mutation would feel surprising.
