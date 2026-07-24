# Terminal iPhone Keyboard and Selection Interaction

Draft date: 2026-04-24
Status: draft, updated for current vendored Ghostty baseline

## Summary
This spec defines the iPhone terminal interaction work we will do next.

- Phase 1 stays entirely in VVTerm app code and finishes the software-keyboard browse-mode behavior.
- Phase 2 moves iPhone touch selection toward a native-feeling app-owned interaction model while keeping Ghostty as the renderer.
- No additional Ghostty fork work is planned up front.
- We only reopen fork work later if the app-side selection spike proves that the current APIs are still missing a concrete geometry primitive we need.

The recent Ghostty vendor update changes the plan in one important way: we now have better selection metadata available in the vendored headers, so we can start Phase 2 with stronger read-side primitives and without immediately changing the fork again.

## Current Baseline

### What Is Already Landed
- `GhosttyTerminalView+iOS.swift` already has a `TerminalKeyboardFocusPolicy`.
- `SSHTerminalWrapper.swift`, `iOSContentView.swift`, and `ConnectionSessionManager.swift` already route some focus flows through higher-level helpers instead of only raw responder calls.
- Vendored `ghostty.h` now exposes newer `ghostty_text_s` metadata:
  - `tl_px_x`
  - `tl_px_y`
  - `offset_start`
  - `offset_len`
- Vendored Ghostty already exposes:
  - `ghostty_surface_read_selection(...)`
  - `ghostty_surface_read_text(...)`

### What Is Still Wrong On iPhone
- Plain touch still reopens the software keyboard from `touchesBegan`.
- Selection gestures still call keyboard-focus helpers and can reopen the keyboard.
- iPhone selection is still Ghostty-style terminal selection plus a custom menu, not a native-feeling text-selection flow.
- `supports_selection_clipboard` is still enabled, so touch selection still behaves too much like copy-on-select.
- `selectionRects(for:)` still returns `[]`, so UIKit does not yet have real selection geometry from VVTerm.

## Product Goals
- After explicit keyboard dismissal, keep the software keyboard hidden until the user explicitly asks for it again.
- Preserve scroll and selection while the keyboard is hidden.
- Keep fast initial typing on terminal open and active-terminal restore.
- Make iPhone touch selection feel closer to native text selection.
- Remove implicit copy-on-select for iPhone touch selection.
- Keep Ghostty as the renderer and terminal engine.
- Avoid new fork work unless Phase 2 proves it is necessary.

## Non-Goals
- Rewriting terminal rendering.
- Redesigning the whole terminal chrome.
- Changing hardware-keyboard behavior.
- Changing macOS behavior.
- Full upstream/fork rework before app-side validation.
- Forcing the terminal into a full `UITextView` text-document model.

## Delivery Plan

### Phase 1: Finish Keyboard Browse Mode
Scope:
- app-side only
- no additional Ghostty fork changes

Outcome:
- explicit dismiss puts the session into `browse`
- plain taps do not reopen the keyboard while in `browse`
- selection and scrolling still work while in `browse`
- keyboard returns only from explicit `Show Keyboard`

### Phase 2: App-Owned iPhone Selection
Scope:
- still app-first
- use the newer vendored Ghostty selection metadata as a primitive

Outcome:
- touch selection ownership moves toward VVTerm instead of Ghostty mouse-selection semantics
- explicit `Copy` replaces implicit copy-on-select
- selection can evolve toward native handles, loupe, and native actions

### Phase 3: Optional Fork Follow-Up
Scope:
- only if Phase 2 reveals a concrete missing primitive

Trigger:
- we cannot place handles, anchors, or action menus with acceptable fidelity using current APIs and the updated vendored metadata

## UX Decision

### Keyboard
Use an explicit post-dismiss browse mode.

Rules:
1. When a terminal first opens or becomes active, VVTerm may still auto-focus the keyboard.
2. When the user explicitly hides the software keyboard, that session enters `browse`.
3. While in `browse`, incidental touch interactions do not reopen the keyboard.
4. The keyboard returns only from an explicit `Show Keyboard` action.
5. Once the user explicitly shows the keyboard again, the session returns to normal typing mode.

### Selection
Selection should stop feeling like desktop mouse selection on a phone.

Target behavior:
- long press starts selection
- drag adjusts selection
- `Copy` is explicit
- menu actions are native-feeling
- the keyboard does not reopen just because the user is selecting text

V1 note:
- Phase 1 keeps the current selection gestures
- it only removes their authority to reopen the keyboard accidentally

## Technical Design

### Keyboard Focus Ownership
We already have a `TerminalKeyboardFocusPolicy`. We should refine and finish that design, not introduce a second policy system.

Required rule:
- no iPhone code path should reclaim terminal keyboard focus without going through the shared policy-aware helper

Recommended shape:

```swift
enum TerminalKeyboardFocusReason {
    case explicitUserRequest
    case initialActivation
    case reconnectRestore
    case directTouch
    case selectionGesture
}
```

We do not need to expose this exact type publicly, but we do need this distinction in the implementation.

Policy:
- explicit requests are allowed when the terminal is eligible for text input
- incidental requests are denied while in `browse`
- reconnect restore is denied while in `browse`

### Phase 1 Keyboard Work
We will tighten the existing implementation instead of redesigning it.

Required changes:
- `GhosttyTerminalView+iOS.swift`
  - treat plain touch as incidental focus
  - keep plain touch from reopening the keyboard while in `browse`
  - treat double tap, triple tap, and long-press selection as incidental focus
  - let selection proceed without reopening the keyboard
- `SSHTerminalWrapper.swift`
  - keep auto-focus and reconnect restore gated by the shared policy
  - do not reclaim keyboard focus just because the terminal is visible if the session is in `browse`
- `iOSContentView.swift`
  - keep explicit dismiss routed through `dismissKeyboardForUser()`
  - expose an explicit `Show Keyboard` action for the active terminal
- `ConnectionSessionManager.swift`
  - keep replacement-terminal focus routed through `requestKeyboardFocus()`
- `ZenModeControls.swift`
  - add a `Show Keyboard` action in the iPhone zen panel

Implementation constraint:
- no new raw `becomeFirstResponder()` call sites outside the view-owned helper path

### Chrome Decision
V1 will expose `Show Keyboard` explicitly.

Recommended placement:
- iPhone terminal navigation chrome
- iPhone zen mode panel

Recommendation:
- keep the button always available while the terminal is active

Reason:
- stable chrome
- easier discoverability
- less UIKit/SwiftUI state plumbing

### Selection Architecture Direction
Phase 2 will be app-owned on iPhone.

That means:
- Ghostty stays the renderer
- VVTerm owns touch selection interaction
- VVTerm owns the visible selection state and action menu behavior
- Ghostty is used as a text-read primitive, not as the sole owner of phone selection UX

Proposed local model:

```swift
struct TerminalGridPoint: Equatable {
    var row: Int
    var column: Int
}

enum TerminalSelectionGranularity {
    case character
    case word
    case line
}

struct TerminalGridSelection: Equatable {
    var anchor: TerminalGridPoint
    var focus: TerminalGridPoint
    var granularity: TerminalSelectionGranularity
}
```

Expected app-owned responsibilities:
- map touch points to terminal grid positions
- own anchor and focus state
- position the selection menu and future handles
- read selected text for explicit actions
- cooperate with keyboard browse mode so selection never forces keyboard reopen

### How The Updated Ghostty Vendor Helps
The updated vendored headers now give us better read-side metadata for selection/text reads.

Useful now:
- selected text reads
- text reads for explicit ranges
- top-left pixel anchor metadata
- offset metadata inside the returned text

Useful implication:
- we can start the app-owned selection spike without immediately changing the fork again

Important limitation:
- this is still not full UIKit selection geometry
- it does not by itself provide native selection rects, handles, or loupe behavior

### Phase 2 Selection Plan
We will not try to make the current Ghostty mouse-selection path feel native by piling more gesture tweaks on top of it.

Instead:
1. Build a small app-side spike around touch selection ownership.
2. Validate whether `UITextInteraction` can be used cleanly on top of `GhosttyTerminalView`.
3. If it works cleanly, use it.
4. If it does not, build a native-like custom overlay with the same user-facing behavior goals.

Decision rule:
- prefer the simplest path that gives stable iPhone selection semantics
- do not force a UIKit text-document model if it creates more complexity than value

### Clipboard Ownership
Phase 2 should make copy explicit on iPhone.

Required direction:
- stop relying on implicit selection clipboard behavior for touch selection
- keep explicit `Copy`
- keep keyboard shortcuts working through the active selection path

Likely implementation step:
- revisit `supports_selection_clipboard` in `Ghostty.App.swift` for iPhone once the app-owned copy path is ready

## Implementation Checklist

### Phase 1
- refine the existing keyboard focus policy instead of replacing it
- gate direct-touch refocus while in `browse`
- gate selection-triggered refocus while in `browse`
- keep reconnect restore policy-aware
- add explicit `Show Keyboard` in iPhone terminal chrome
- add explicit `Show Keyboard` in iPhone zen mode
- verify browse mode survives normal session reuse and tab switching

### Phase 2
- add an iPhone touch-selection controller under `VVTerm/GhosttyTerminal/`
- define app-owned grid-based selection state
- evaluate `UITextInteraction` on the current view stack
- if needed, add a custom selection overlay for highlight, handles, and menu anchoring
- switch iPhone copy from implicit selection clipboard behavior to explicit action flow

### Phase 3, Only If Needed
- add narrowly scoped fork work for missing geometry primitives
- rebuild vendored Ghostty only after the missing primitive is proven

## Affected Files
- `VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift`
- `VVTerm/GhosttyTerminal/Ghostty.App.swift`
- `VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift`
- `VVTerm/App/iOS/iOSContentView.swift`
- `VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift`
- `VVTerm/Features/TerminalSessions/UI/Terminal/ZenModeControls.swift`
- `VVTermTests/TerminalHardwareTextInputRoutingPolicyTests.swift` or a dedicated keyboard-focus-policy test file
- likely one or more new iPhone selection files under `VVTerm/GhosttyTerminal/`

## Testing Plan

### Phase 1
- terminal open still auto-focuses for fast typing
- explicit dismiss enters `browse`
- plain tap does not reopen the keyboard in `browse`
- double tap still selects without reopening the keyboard in `browse`
- long press still selects without reopening the keyboard in `browse`
- explicit `Show Keyboard` returns to typing mode
- reconnect restore stays suppressed while in `browse`

### Phase 2
- selecting text does not implicitly copy it on iPhone
- copy action returns the expected text for single-line and multi-line selections
- menu placement is stable
- selection remains usable near screen edges
- keyboard shortcuts still operate on the active selection

## Open Questions
- Can `UITextInteraction` provide enough native behavior on top of the current view stack without excessive adapter complexity?
- Do we want the eventual app-owned selection flow to replace double-tap and triple-tap semantics, or preserve them as shortcuts on top of the new model?

Current recommendation:
- answer the first question with a short spike
- preserve current multi-tap shortcuts unless Phase 2 proves they fight the native-feeling model
