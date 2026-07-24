# Terminal Custom Fonts (Spec)

## Summary

Add Pro-gated custom terminal font support for iOS and macOS.

Users can import `.ttf`, `.otf`, `.ttc`, or `.otc` font files from their device, VVTerm copies them into app-owned storage, validates and registers them for the running process, then exposes their resolved font families under a `Custom` group in Terminal Settings. Imported fonts can sync privately across the user's devices through CloudKit assets.

## Research Findings

- App-loaded fonts are feasible on Apple platforms using Core Text font registration from a font file URL. The relevant API family is `CTFontManagerRegisterFontsForURL` / `CTFontManagerRegisterFontURLs`; the registration scope can be process-local, which fits VVTerm because Ghostty only needs the font available inside the app process.
- iOS and macOS should not depend on the user installing fonts into the OS. The app can import a selected file through document/file import, copy it into Application Support, then register that copy on every launch before Ghostty config is loaded.
- On macOS, the current system picker is not complete for this feature because it only reads `NSFontManager.availableFontFamilies` and filters by `NSFont.isFixedPitch`. That is good for installed system fonts, but it does not manage app-owned imported font files.
- On iOS, the current list is intentionally narrow and incomplete: it seeds `Menlo`, `SF Mono`, `Courier New`, then probes a few Nerd Font families. A real font list should enumerate available families through UIKit/Core Text after bundled and imported fonts are registered.
- CloudKit supports binary file fields through `CKAsset`, so font file sync can live in the existing private CloudKit sync architecture instead of exposing files through iCloud Drive. Apple documents that `CKAsset` data is stored separately from its record; an archived CloudKit Web Services limit table lists 50 MB as the asset field maximum, but VVTerm should use a much smaller app-level limit for predictable sync.
- Ghostty already consumes `font-family` from the generated terminal config, so primary font selection can use the existing config reload path.

References:
- Apple Core Text font registration: https://developer.apple.com/documentation/coretext/ctfontmanagerregisterfontsforurl(_:_:_:)
- Apple Core Text font manager scope: https://developer.apple.com/documentation/coretext/ctfontmanagerscope
- Apple UIKit font enumeration: https://developer.apple.com/documentation/uikit/uifont
- Apple AppKit font manager: https://developer.apple.com/documentation/appkit/nsfontmanager
- Apple CloudKit assets: https://developer.apple.com/documentation/cloudkit/ckasset
- Apple security-scoped file access: https://developer.apple.com/documentation/foundation/nsurl/1417051-startaccessingsecurityscopedreso
- Ghostty font-family config: https://ghostty.org/docs/config/reference#font-family

## Current VVTerm Code Findings

- Terminal font preference is stored in `UserDefaults` through `TerminalDefaults.fontNameKey` and `TerminalDefaults.fontSizeKey`.
- `TerminalSettingsView` owns the current font picker UI. It keeps `availableFonts` in view state, loads macOS fonts through `NSFontManager.availableFontFamilies`, and loads iOS fonts from a short static/probed list.
- `Ghostty.ConfigBuilder` writes `font-family = "..."` into the generated Ghostty config.
- `Ghostty.App` reloads config when the font name, font size, theme, or custom theme version changes, then calls `ghostty_app_update_config` and `ghostty_surface_update_config` for active surfaces.
- Custom themes are the closest existing pattern: domain model in `Features/TerminalThemes/Domain`, manager in `Application`, file materialization in Application Support, and CloudKit sync through private records.
- Pro state is centralized through `StoreManager.shared.isPro`, with upgrade presentation helpers already available in `Features/Store/UI`.

## Goals

- Allow Pro users to import and use custom terminal fonts on iOS and macOS.
- Keep existing bundled/system font behavior for free users.
- Preserve current terminal UI behavior apart from the font selection feature.
- Register custom fonts before Ghostty app/config creation and before config reloads that reference them.
- Sync imported fonts and font preferences automatically across devices when iCloud sync is enabled.
- Keep font feature ownership under `Features/TerminalFonts`.

## Non-Goals

- Do not install fonts system-wide.
- Do not expose synced font files in iCloud Drive.
- Do not bypass font licensing. VVTerm should treat imported files as user-provided assets and show a short responsibility notice.
- Do not reject proportional fonts only because they are not terminal-suitable. V1 should allow them if Ghostty can load them and warn that spacing/alignment may be poor in terminal output.
- Do not implement per-ligature or OpenType feature controls in V1.
- Do not make custom font import available to non-Pro users.

## User Experience

### Terminal Settings

Replace the current single flat picker with grouped options:

- Built-in
- System
- Custom

Rows:

- `Font Family`: primary terminal font.
- `Manage Custom Fonts`: opens the custom font manager.
- `Font Size`: unchanged.

The interaction model should match custom themes:

- The manager creates, edits, deletes, and optionally applies custom entries.
- The main picker is the durable selection surface.
- Custom entries appear in a separate `Custom` picker section after they are created/imported.
- Importing a font should not be the only way to select it.

### Import Flow

1. User taps `Manage Custom Fonts`.
2. If not Pro, show the existing Pro upgrade surface.
3. User chooses `Import Font`.
4. VVTerm presents a file importer/open panel accepting font file types.
5. VVTerm copies the selected file into app-owned storage.
6. VVTerm validates the font, extracts its family/postscript names, registers it, saves metadata, and shows a save/confirm sheet when there is a user-visible choice to make.
7. User saves the font into the custom font library.
8. The imported family appears under the `Custom` group in the main font pickers.
9. User can select it from the picker, or use a manager action such as `Use Font`.

Unlike themes, fonts do not need an apply target during import because there is one primary terminal font preference. If the imported file contains multiple families, show a chooser before saving or after saving in the manager.

### Custom Font Manager

The custom font manager should mirror `ManageCustomThemesSheet`:

- Empty state when there are no imported fonts.
- Primary action menu with `Import Font`.
- Rows sorted by display name.
- Row actions: `Use Font`, `Rename` if we support display aliases, `Delete`.
- Active/assigned label: `Primary`.
- Deletion should soft-delete and should clear current assignment only if the deleted font is selected, using the default font at runtime.

The manager may offer `Use Font` immediately after import for convenience, but the main picker should remain authoritative and should show the saved custom font under `Custom`.

V1 should enforce a quiet custom-font count limit:

- Maximum custom fonts: 25 visible custom font records.
- Do not show this limit in normal UI copy.
- If a user reaches the limit, block import and show an error.

### Missing Font Flow

If a selected custom font is not available locally yet:

- Keep the preference.
- Display the row as `Font Name (syncing...)` or `Font Name (missing)`.
- Use the default primary font at runtime until the font file arrives and registers.
- After registration, reload Ghostty config.

### Entitlement Behavior

- Free users can continue using existing bundled and system fonts.
- Free users can see already-imported custom fonts in the manager as locked, but cannot import new fonts or select a custom font.
- If Pro expires, do not delete imported font files. Runtime should use default/bundled fonts while preserving the previous custom selection so it can restore when Pro returns.

### Sync Settings

Add a `Custom Fonts` row to the existing Sync Settings `Data` section, next to `Custom Themes`.

- Count only visible custom fonts, excluding soft-deleted records.
- Use a font-related symbol, such as `textformat`.
- This is informational only; font sync follows the global iCloud sync toggle.

## Technical Design

### Ownership

Create a new feature subtree:

```text
VVTerm/Features/TerminalFonts/
├── Domain/
│   ├── TerminalFont.swift
│   └── TerminalFontValidation.swift
├── Application/
│   └── TerminalFontManager.swift
├── Infrastructure/
│   ├── TerminalFontRegistrar.swift
│   └── TerminalFontStoragePaths.swift
└── UI/
    └── ManageCustomFontsSheet.swift
```

`Core/Terminal/TerminalDefaults.swift` should keep default preference keys and default behavior. Font import, validation, registration, and sync should not be added to `Core/Terminal` unless a primitive is genuinely shared outside this feature.

### Data Model

```swift
struct TerminalFont: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var familyNames: [String]
    var postScriptNames: [String]
    var originalFilename: String
    var storedFilename: String
    var fileExtension: String
    var fileSize: Int64
    var sha256: String
    var isFixedPitch: Bool?
    var source: TerminalFontSource
    var updatedAt: Date
    var deletedAt: Date?
}

enum TerminalFontSource: String, Codable {
    case imported
}

struct TerminalFontPreference: Codable, Equatable {
    static let recordName = "terminal-font-preference.v1"

    var primaryFamilyName: String
    var updatedAt: Date
}
```

Persist metadata locally under a new key:

```swift
CloudKitSyncConstants.terminalCustomFontsStorageKey = "terminalCustomFontsV1"
CloudKitSyncConstants.terminalFontPreferenceUpdatedAtKey = "terminalFontPreferenceUpdatedAt"
```

Keep `TerminalDefaults.fontNameKey` as the primary font preference key for compatibility.

### Local Storage

Store font files in Application Support:

```text
Application Support/<bundle-id>/CustomFonts/<uuid>/<sanitized-original-name>.<ext>
```

Use UUID directories to avoid filename collisions. Metadata should reference the stored relative path, not an arbitrary user-selected file path.

On launch:

1. Load font metadata.
2. Register all visible imported font files.
3. Build available font lists.
4. Start/reload Ghostty config.

`TerminalFontManager` should expose:

- `availablePrimaryFonts`
- `customFonts`
- `visibleCustomFontCount`
- `importFont(from:)`
- `deleteCustomFont(id:)`
- `resolveFamily(_:)`
- `registerAvailableFonts()`

Limits:

- `maxCustomFonts = 25`
- Check the limit before copying or registering a newly imported font.
- Deduped imports that resolve to an existing visible font should not count as a new font.

### Font Validation

For each imported file:

- Require extension/type to be `.ttf`, `.otf`, `.ttc`, or `.otc`.
- Copy to app storage before long-term use.
- Use `startAccessingSecurityScopedResource()` only while reading the picked file, then stop.
- Use Core Text to inspect descriptors from the font file URL.
- Extract family names and PostScript names.
- Register using process scope.
- Compute SHA-256 for deduplication.
- If fixed-pitch detection is false, show a warning but still allow import. Suggested copy: `This font is not monospaced. Terminal columns, prompts, tables, and box drawing may not align correctly.`
- If fixed-pitch detection is unknown, do not block import.
- Enforce a size limit. V1 limit: reject font files larger than 5 MB. Most terminal fonts are comfortably below this, and it keeps CloudKit asset sync cheap and predictable even though CloudKit can handle larger assets.
- Enforce a count limit. V1 limit: reject imports when the user already has 25 visible custom fonts.

Deduplication:

- If SHA-256 already exists and is not deleted, do not copy another file. Reuse the existing record.
- If same family exists with different bytes, allow import but show filename/source in manager to disambiguate.

### Font Registration

Implement registration in `TerminalFontRegistrar`.

Registration should be process-local:

```swift
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
```

For collections, inspect all descriptors and expose all family names.

Registration must happen before `Ghostty.App.start()` loads config. The composition root should call `TerminalFontManager.shared.registerAvailableFonts()` before the `Ghostty.App` object starts, or `Ghostty.App.loadConfigIntoGhostty` must synchronously ensure registration before writing `font-family`.

Prefer composition-root registration so Ghostty remains a terminal renderer wrapper, not a font asset manager.

### System Font Enumeration

macOS:

- Continue using `NSFontManager.availableFontFamilies`.
- Filter fixed-pitch fonts for the primary picker.
- Include custom registered families regardless of whether `availableFontFamilies` reports them immediately.

iOS:

- Replace the static list with `UIFont.familyNames`, plus bundled/custom registered families.
- Keep bundled Nerd Fonts in the built-in group.
- Filter/warn rather than strictly hide fonts unless fixed-pitch detection is reliable.

### Ghostty Config

Change `Ghostty.ConfigBuilder` from:

```swift
fontFamilyLines(primaryFamily: terminalFontName)
```

to:

```swift
fontFamilyLines(primaryFamily: resolvedPrimary)
```

Resolve the selected family through `TerminalFontManager` before writing config. If the selected custom font is unavailable, write `TerminalDefaults.defaultFontName` while preserving the stored selection.

## CloudKit Sync

Use CloudKit private database records, not iCloud Documents.

Record types:

- `TerminalFont`
- `TerminalFontPreference`

`TerminalFont` fields:

- `name`
- `familyNames`
- `postScriptNames`
- `originalFilename`
- `storedFilename`
- `fileExtension`
- `fileSize`
- `sha256`
- `isFixedPitch`
- `updatedAt`
- `deletedAt`
- `asset` as `CKAsset`

Sync behavior:

- Upload the copied font file as a `CKAsset`.
- Fetch remote assets into the same Application Support `CustomFonts/<uuid>/` directory.
- Merge by `id`, then newer `updatedAt`.
- Soft delete fonts with `deletedAt`, matching custom theme behavior.
- Keep pending mutations in `CloudKitSyncCoordinator`, adding font upsert/delete and preference upsert cases.
- Sync custom fonts automatically when global iCloud sync is enabled.
- Do not sync custom fonts when global iCloud sync is disabled.

Rationale:

- CloudKit private database matches current server/theme/accessory sync ownership.
- `CKAsset` avoids putting binary font bytes into normal record fields.
- iCloud Documents would expose implementation files to the user, require document coordination concerns, and would not fit the existing private sync model.

## Error Handling

- Import denied or unavailable file: show a normal non-destructive error.
- Unsupported type: reject before copying.
- Invalid font: reject after Core Text descriptor inspection fails.
- Registration failure: keep the file only if descriptors were valid; mark as unavailable until retry, or remove it if the error is permanent.
- CloudKit quota/network failure: keep local font and enqueue retry.
- Missing synced asset: keep metadata, show missing/syncing state, and use the default font at runtime.
- Non-Pro import attempt: show upgrade surface before presenting file importer.
- More than 25 visible custom fonts: block import and show `Custom font limit reached. Delete a custom font before importing another one.`
- More than 5 MB: block import and show `Font files must be 5 MB or smaller.`

## Migration

- Keep existing `terminalFontName` values.
- During first run after this feature:
  - If stored primary is available as system/built-in/custom, keep it.
  - If missing, keep the value for UI continuity but resolve runtime primary to `TerminalDefaults.defaultFontName`.

## Testing Plan

Unit tests:

- Font metadata encoding/decoding.
- Storage path generation and filename sanitization.
- SHA-256 deduplication.
- Font list grouping and selected-missing-font injection.
- Config builder primary font resolution.
- Entitlement guard: free users cannot import or select custom fonts.
- Import limit: 25 visible custom fonts maximum.
- Import size limit: 5 MB maximum.
- Preference merge by `updatedAt`.
- Soft delete merge.
- Sync Settings custom font count excludes soft-deleted fonts.

Integration tests:

- Import a small fixture `.ttf`, register it, and confirm family extraction.
- Reload Ghostty config after primary font change.
- Fetch a `CKAsset` into local storage and register it.

Manual QA:

- iOS import from Files.
- macOS import from Downloads and from a security-scoped provider.
- Import a `.ttc` collection and confirm all usable families appear.
- Select primary custom font, quit, relaunch, confirm terminal starts with it.
- Import 25 custom fonts, then confirm the next distinct import is blocked.
- Disable iCloud sync and confirm local custom fonts still work.
- Expire Pro/review mode and confirm custom font preference is preserved but runtime uses the default font.

## Rollout

1. Add `TerminalFonts` domain, storage paths, registrar, manager, and tests.
2. Register imported fonts before Ghostty startup.
3. Replace settings font list with grouped built-in/system/custom data from `TerminalFontManager`.
4. Add import/manage UI with Pro gate and theme-like row actions.
5. Add primary font preference sync and Ghostty config resolver.
6. Add CloudKit `TerminalFont` and `TerminalFontPreference` support with `CKAsset`.
7. Add `Custom Fonts` count to Sync Settings.

## Open Questions

- Should bundled Nerd Fonts be displayed as Built-in even if UIKit/AppKit reports them as system-available after bundle registration?
