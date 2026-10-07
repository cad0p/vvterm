//
//  Ghostty.App.swift
//  VVTerm
//
//  Minimal Ghostty app wrapper
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import OSLog
import SwiftUI

// MARK: - Ghostty Namespace

enum Ghostty {
    static let logger = Logger.forCategory("Ghostty")

    /// Notification posted when terminal config is reloaded and views should refresh
    static let configDidReloadNotification = Notification.Name("GhosttyConfigDidReload")

    /// Wrapper to hold reference to a surface for tracking
    /// Note: ghostty_surface_t is an opaque pointer, so we store it directly
    /// The surface is freed when the GhosttyTerminalView is deallocated
    class SurfaceReference {
        // Explicit nonisolated deinit: the compiler-synthesized deinit of a
        // MainActor-isolated class takes the back-deployed isolated-deinit path,
        // which aborts (invalid free) when released outside a task context —
        // swiftlang/swift#85663, #88036. Empty body, no behavior change.
        nonisolated deinit {}
        let surface: ghostty_surface_t
        weak var terminalView: GhosttyTerminalView?
        var isValid: Bool = true

        init(_ surface: ghostty_surface_t, terminalView: GhosttyTerminalView) {
            self.surface = surface
            self.terminalView = terminalView
        }

        func invalidate() {
            isValid = false
        }
    }

    @MainActor
    private struct TitleDeliveryLogCache {
        static var lastUndeliveredTitleBySurface: [String: String] = [:]
    }

}

// MARK: - #327 clipboard confirmation

/// Which ghostty clipboard-request kinds may prompt the user (#327).
///
/// Only the user-initiated paste kind may prompt. `.osc_52_read` cannot exist
/// under `clipboard-read = deny` (`Surface.zig:5898-5904` refuses before a
/// request is allocated) and must never be user-authorized if that config ever
/// changes; `.osc_52_write` cannot reach the confirm callback at all (its write
/// path never travels through `startClipboardRequest`).
enum ClipboardConfirmationPolicy {
    static func requiresUserPrompt(_ request: ghostty_clipboard_request_e) -> Bool {
        request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
    }
}

/// One unsafe-paste confirmation request: the payload the completion will use
/// if the user allows the paste, plus the neutral presentation copy.
///
/// The copy never claims more than the code checked: `input.paste.isSafe`
/// rejects a bare `ESC[201~` as well as `\n` (`input/paste.zig:175-177`), so
/// the body says "newlines or control characters" and shows only the payload's
/// line count — never the payload itself.
struct ClipboardConfirmationRequest {
    let payload: String

    /// The neutral prompt title shared by both platform presenters. One
    /// constant, not one literal per platform, so the parity contract has a
    /// single source of truth (source-pinned by P-F).
    static let promptTitle = "Paste Unsafe Text?"

    var lineCount: Int { Self.lineCount(for: payload) }
    var promptBody: String { Self.promptBody(lineCount: lineCount) }

    static func lineCount(for payload: String) -> Int {
        // Count LF bytes directly. `components(separatedBy: "\n")` would
        // materialize one substring per line for a remote-seeded payload that
        // can be arbitrarily large, just to render a count; the byte scan is
        // exactly equivalent for LF (0x0A can only appear as LF in UTF-8) and
        // allocation-free.
        1 + payload.utf8.reduce(0) { count, byte in count + (byte == 0x0A ? 1 : 0) }
    }

    static func promptBody(lineCount: Int) -> String {
        "This text may be unsafe to paste: it can contain newlines or control "
            + "characters. It contains \(lineCount) line\(lineCount == 1 ? "" : "s")."
    }
}

#if DEBUG
/// DEBUG-only telemetry for the #327 confirm/completion contract. Records the
/// request kind and the completion's byte length and confirmed flag — never
/// payload content. Precedent: `SSHClientUITestDebug`
/// (`VVTerm/Core/SSH/SSHClient.swift`).
nonisolated enum GhosttyClipboardConfirmDebug {
    struct Completion: Equatable {
        let kind: ghostty_clipboard_request_e
        let byteLength: Int
        let confirmed: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedCallbackKinds: [ghostty_clipboard_request_e] = []
    nonisolated(unsafe) private static var recordedCompletions: [Completion] = []
    nonisolated(unsafe) private static var recordedTeardownDrains: [ghostty_clipboard_request_e] = []

    /// Every `confirmReadClipboard` invocation's kind.
    static var callbackKinds: [ghostty_clipboard_request_e] {
        lock.lock(); defer { lock.unlock() }
        return recordedCallbackKinds
    }

    /// Every completion routed through `complete(...)` — including the deny
    /// completions a surface-teardown drain issues (#329).
    static var completions: [Completion] {
        lock.lock(); defer { lock.unlock() }
        return recordedCompletions
    }

    /// Every request released by a surface-teardown drain (#329), in
    /// registry-drain order — unspecified across multiple entries, of which
    /// only `.paste` is reachable today. The origin label that separates a
    /// drain completion from a completion-path one in `completions`.
    static var teardownDrains: [ghostty_clipboard_request_e] {
        lock.lock(); defer { lock.unlock() }
        return recordedTeardownDrains
    }

    static func noteCallback(kind: ghostty_clipboard_request_e) {
        lock.lock(); defer { lock.unlock() }
        recordedCallbackKinds.append(kind)
    }

    static func noteCompletion(kind: ghostty_clipboard_request_e, byteLength: Int, confirmed: Bool) {
        lock.lock(); defer { lock.unlock() }
        recordedCompletions.append(Completion(kind: kind, byteLength: byteLength, confirmed: confirmed))
    }

    static func noteTeardownDrain(kind: ghostty_clipboard_request_e) {
        lock.lock(); defer { lock.unlock() }
        recordedTeardownDrains.append(kind)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recordedCallbackKinds.removeAll()
        recordedCompletions.removeAll()
        recordedTeardownDrains.removeAll()
    }
}
#endif

// MARK: - Ghostty.App

extension Ghostty {
    enum ConfigBuilder {
        /// Fallback font families appended after the primary family. Production
        /// uses the macOS stack on macOS and none elsewhere; injectable so a
        /// test can build either platform's config on any destination.
        static var defaultFallbackFontFamilies: [String] {
            #if os(macOS)
            return TerminalDefaults.macOSFallbackFontFamilies
            #else
            return []
            #endif
        }

        /// Whether the config carries the `macos-option-as-alt` platform line.
        /// Production emits it on macOS only; injectable for the same reason.
        static var defaultEmitsPlatformInputConfig: Bool {
            #if os(macOS)
            return true
            #else
            return false
            #endif
        }

        static func sanitizedFontFamilies(
            primaryFamily: String,
            fallbackFamilies: [String] = defaultFallbackFontFamilies
        ) -> [String] {
            let candidates = [primaryFamily] + fallbackFamilies

            var seen = Set<String>()
            var families: [String] = []

            for candidate in candidates {
                let family = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !family.isEmpty else { continue }
                guard seen.insert(family).inserted else { continue }
                families.append(family)
            }

            return families
        }

        /// Sanitize a value that is emitted inside a double-quoted Ghostty config
        /// value. Ghostty's line parser strips the surrounding quotes and does
        /// **not** decode escape sequences (`src/cli/args.zig`, `LineIterator`),
        /// so the value must be emitted verbatim: escaping a `\\` or `"` would
        /// make the loader look for a file whose name literally contains the
        /// backslash. Only the characters that would break the line structure
        /// are removed. Used for every quoted value (`theme`, `font-family`).
        static func sanitizedConfigValue(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
        }

        /// The value to emit for `theme`. Ghostty treats an absolute path as a
        /// direct file reference and otherwise searches the themes directory
        /// *and* the bundled resources directory, so fall back to the bare name
        /// whenever the copy in `themesDirectory` is missing (a purgeable
        /// `TMPDIR`, or a custom theme added without refreshing the copies).
        static func themeConfigValue(
            themeName: String,
            themesDirectory: String,
            isFile: (String) -> Bool
        ) -> String {
            // An empty name would resolve to the themes directory itself.
            guard !themeName.isEmpty else { return "" }
            let absolutePath = (themesDirectory as NSString).appendingPathComponent(themeName)
            return isFile(absolutePath) ? absolutePath : themeName
        }

        /// `FileManager.fileExists` is also true for directories, so it would
        /// accept the themes directory itself as a "theme file" and ghostty
        /// would then drop the theme. Only a regular file is a theme.
        static func isRegularFile(_ path: String) -> Bool {
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }

        static func fontFamilyLines(
            primaryFamily: String,
            fallbackFamilies: [String] = defaultFallbackFontFamilies
        ) -> String {
            sanitizedFontFamilies(primaryFamily: primaryFamily, fallbackFamilies: fallbackFamilies)
                .map { "font-family = \"\(sanitizedConfigValue($0))\"" }
                .joined(separator: "\n")
        }

        static func optionAsAltConfigValue(_ mode: TerminalOptionAsAltMode) -> String {
            switch mode {
            case .none: "false"
            case .left: "left"
            case .right: "right"
            case .both: "true"
            }
        }

        static func configContent(
            primaryFontFamily: String,
            fontSize: Double,
            shellName: String,
            theme: String,
            cursorStyle: TerminalCursorStyle = TerminalDefaults.defaultCursorStyle,
            cursorBlink: Bool = TerminalDefaults.defaultCursorBlink,
            optionAsAltMode: TerminalOptionAsAltMode = .none,
            fallbackFontFamilies: [String] = defaultFallbackFontFamilies,
            emitsPlatformInputConfig: Bool = defaultEmitsPlatformInputConfig
        ) -> String {
            let platformInputConfig = emitsPlatformInputConfig
                ? "macos-option-as-alt = \(optionAsAltConfigValue(optionAsAltMode))"
                : ""

            // An empty theme name has no usable value (it would resolve to the
            // themes directory), so the directive is omitted entirely.
            let themeLine = theme.isEmpty ? "" : "theme = \"\(sanitizedConfigValue(theme))\""

            return """
            \(fontFamilyLines(primaryFamily: primaryFontFamily, fallbackFamilies: fallbackFontFamilies))
            font-size = \(Int(fontSize))
            window-inherit-font-size = false
            window-padding-balance = false
            window-padding-x = 0
            window-padding-y = 0
            window-padding-color = extend-always

            # Enable shell integration (resources dir auto-detected from app bundle)
            shell-integration = \(shellName)
            shell-integration-features = no-cursor,sudo,title

            # Cursor
            cursor-style = \(cursorStyle.rawValue)
            cursor-style-blink = \(cursorBlink ? "true" : "false")

            \(themeLine)

            # The audible bell is already off: the `bell-features` default
            # enables only `attention` and `title`. The old `audible-bell` key
            # was removed upstream and is now rejected as an unknown field
            # (verified against the vendored core with a config probe).

            # Limit scrollback to prevent unbounded memory growth.
            # `scrollback-limit` is a deprecated alias for `scrollback-limit-bytes`
            # (bytes, not lines), so the line-based key has to be used explicitly:
            # 10000 lines is plenty for most use cases (~5-10MB).
            scrollback-limit-lines = 10000

            # Faster scroll speed (especially for iOS touch)
            mouse-scroll-multiplier = 3

            # Custom keybinds
            keybind = shift+enter=text:\\n

            # Remote programs may not read the local clipboard (OSC 52 read).
            # Denied explicitly rather than left to the default `ask`: the app
            # has no clipboard-read prompt, and a denied read never starts a
            # request, so no clipboard-request state can be retained.
            clipboard-read = deny

            \(platformInputConfig)

            """
        }
    }

    /// Minimal wrapper for ghostty_app_t lifecycle management
    @MainActor
    class App: ObservableObject {
        enum Readiness: String {
            case idle, loading, error, ready
        }

        // MARK: - Published Properties

        /// The ghostty app instance
        @Published var app: ghostty_app_t? = nil

        /// Readiness state
        @Published var readiness: Readiness = .loading

        /// Track active surfaces for config propagation
        private var activeSurfaces: [Ghostty.SurfaceReference] = []
        private var surfaceConfigCache: [SurfaceConfigCacheKey: ghostty_config_t] = [:]
        #if os(macOS)
        /// Track last known appearance to detect changes
        private var lastKnownAppearance: NSAppearance.Name?
        #endif

        /// Track last known theme to detect changes
        private var lastKnownTheme: String?

        /// Observer for in-app appearance setting changes
        private var appearanceSettingObserver: NSObjectProtocol?

        // MARK: - Terminal Settings from AppStorage

        @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = TerminalDefaults.defaultFontName
        @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
        @AppStorage(TerminalDefaults.cursorStyleKey) private var terminalCursorStyleRaw = TerminalDefaults.defaultCursorStyle.rawValue
        @AppStorage(TerminalDefaults.cursorBlinkKey) private var terminalCursorBlink = TerminalDefaults.defaultCursorBlink
        #if os(macOS)
        @AppStorage(TerminalDefaults.optionAsAltModeKey) private var terminalOptionAsAltModeRaw = TerminalOptionAsAltMode.none.rawValue
        #endif
        @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
        @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
        @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
        @AppStorage("appearanceMode") private var appearanceMode = "system"

        private var effectiveThemeName: String {
            guard usePerAppearanceTheme else { return terminalThemeName }

            // Check in-app appearance setting first
            switch appearanceMode {
            case "light":
                return terminalThemeNameLight
            case "dark":
                return terminalThemeName
            default:
                // System mode - follow actual system appearance
                #if os(macOS)
                let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                #else
                let isDark = UITraitCollection.current.userInterfaceStyle == .dark
                #endif
                return isDark ? terminalThemeName : terminalThemeNameLight
            }
        }

        private var terminalCursorStyle: TerminalCursorStyle {
            TerminalCursorStyle(rawValue: terminalCursorStyleRaw) ?? TerminalDefaults.defaultCursorStyle
        }

        private var terminalOptionAsAltMode: TerminalOptionAsAltMode {
            #if os(macOS)
            TerminalOptionAsAltMode(rawValue: terminalOptionAsAltModeRaw) ?? .none
            #else
            .none
            #endif
        }

        // MARK: - Initialization

        private var didStart = false

        private struct SurfaceConfigCacheKey: Hashable {
            let fontName: String
            let fontSize: Double
            let themeName: String
            let cursorStyleRaw: String
            let cursorBlink: Bool
            let optionAsAltModeRaw: String
        }

        init(autoStart: Bool = true) {
            if autoStart {
                startIfNeeded()
            } else {
                readiness = .idle
            }
        }

        func startIfNeeded() {
            guard !didStart else { return }
            didStart = true
            readiness = .loading
            start()
        }

        private func start() {
            ensureProcessEnvironment()

            // CRITICAL: Initialize libghostty first
            let initResult = ghostty_init(0, nil)
            if initResult != GHOSTTY_SUCCESS {
                Ghostty.logger.critical("ghostty_init failed with code: \(initResult)")
                readiness = .error
                return
            }

            // iPhone touch selection now owns copy explicitly, so don't let
            // Ghostty mirror selection changes into the pasteboard on iOS.
            #if os(iOS)
            let supportsSelectionClipboard = false
            #else
            let supportsSelectionClipboard = true
            #endif

            // Create runtime config with callbacks
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: supportsSelectionClipboard,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state in App.readClipboard(userdata, location: loc, state: state) },
                confirm_read_clipboard_cb: { userdata, str, state, request in App.confirmReadClipboard(userdata, string: str, state: state, request: request) },
                write_clipboard_cb: { userdata, loc, content, count, confirm in
                    App.writeClipboard(userdata, location: loc, contents: content, count: count, confirm: confirm)
                },
                close_surface_cb: { userdata, processAlive in App.closeSurface(userdata, processAlive: processAlive) }
            )

            // Create config and load Aizen terminal settings
            guard let config = ghostty_config_new() else {
                Ghostty.logger.critical("ghostty_config_new failed")
                readiness = .error
                return
            }

            // Load config from settings
            loadConfigIntoGhostty(config)

            // Finalize config (required before use)
            ghostty_config_finalize(config)

            // Create the ghostty app
            guard let app = ghostty_app_new(&runtime_cfg, config) else {
                Ghostty.logger.critical("ghostty_app_new failed")
                ghostty_config_free(config)
                readiness = .error
                return
            }

            // Free config after app creation (app clones it)
            ghostty_config_free(config)

            self.app = app
            self.readiness = .ready

            // Store initial theme
            lastKnownTheme = effectiveThemeName

            #if os(macOS)
            // Store initial appearance
            lastKnownAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])

            // Observe system appearance changes via DistributedNotificationCenter
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(systemAppearanceDidChange),
                name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil
            )
            #endif

            // Observe in-app appearance setting changes
            appearanceSettingObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkAppearanceSettingChange()
                }
            }

            Ghostty.logger.info("Ghostty app initialized successfully")
        }

        /// Called at the top of `start()`, before `ghostty_init`. libghostty
        /// snapshots the process environment by pointer during init, so the
        /// mutations below are safe here: adding a variable with `setenv`
        /// replaces the environment table, which would invalidate that
        /// snapshot if it happened after init, and the config loader's
        /// `getenv` walk would then read unowned memory (issue #225).
        /// `unsetenv` after init is dead code today but is a latent hazard for
        /// the same reason. Keep environment mutations in this function only.
        private func ensureProcessEnvironment() {
            #if os(iOS)
            let homeDirectory = NSHomeDirectory()
            if !homeDirectory.isEmpty {
                if let currentHome = getenv("HOME"), !String(cString: currentHome).isEmpty {
                    // Keep the system-provided value when it exists.
                } else {
                    setenv("HOME", homeDirectory, 1)
                }
            }

            let temporaryDirectory = NSTemporaryDirectory()
            if !temporaryDirectory.isEmpty {
                if let currentTemporaryDirectory = getenv("TMPDIR"),
                   !String(cString: currentTemporaryDirectory).isEmpty {
                    // Keep the system-provided value when it exists.
                } else {
                    setenv("TMPDIR", temporaryDirectory, 1)
                }
            }
            #endif
        }

        #if os(macOS)
        @objc private func systemAppearanceDidChange(_ notification: Notification) {
            handleAppearanceChange()
        }

        private func handleAppearanceChange() {
            guard usePerAppearanceTheme else { return }

            let currentAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            guard currentAppearance != lastKnownAppearance else { return }

            lastKnownAppearance = currentAppearance
            reloadIfThemeChanged()
        }
        #endif

        private func checkAppearanceSettingChange() {
            guard usePerAppearanceTheme else { return }
            reloadIfThemeChanged()
        }

        private func reloadIfThemeChanged() {
            let newTheme = effectiveThemeName
            guard newTheme != lastKnownTheme else { return }

            lastKnownTheme = newTheme
            Ghostty.logger.info("Theme changed, reloading terminal config with theme: \(newTheme)")
            reloadConfig()
        }

        deinit {
            // Note: Cannot access @MainActor isolated properties in deinit
            // The app will be freed when the instance is deallocated
            // For proper cleanup, call a cleanup method before deinitialization
        }

        // MARK: - App Operations

        /// Clean up the ghostty app resources
        func cleanup() {
            #if os(macOS)
            DistributedNotificationCenter.default().removeObserver(self)
            #endif

            if let observer = appearanceSettingObserver {
                NotificationCenter.default.removeObserver(observer)
                appearanceSettingObserver = nil
            }

            clearSurfaceConfigCache()

            if let app = self.app {
                ghostty_app_free(app)
                self.app = nil
            }
        }

        func appTick() {
            guard let app = self.app else { return }
            ghostty_app_tick(app)
        }

        /// Register a surface for config update tracking
        /// Returns the surface reference that should be stored by the view
        @discardableResult
        func registerSurface(_ surface: ghostty_surface_t, terminalView: GhosttyTerminalView) -> Ghostty.SurfaceReference {
            let ref = Ghostty.SurfaceReference(surface, terminalView: terminalView)
            activeSurfaces.append(ref)
            // Clean up invalid surfaces
            activeSurfaces = activeSurfaces.filter { $0.isValid }
            return ref
        }

        /// Unregister a surface when it's being deallocated
        func unregisterSurface(_ ref: Ghostty.SurfaceReference) {
            ref.invalidate()
            activeSurfaces = activeSurfaces.filter { $0.isValid }
        }

        func terminalView(for surface: ghostty_surface_t) -> GhosttyTerminalView? {
            activeSurfaces = activeSurfaces.filter { $0.isValid && $0.terminalView != nil }
            return activeSurfaces.first { $0.surface == surface }?.terminalView
        }

        func activeSurfaceCount() -> Int {
            activeSurfaces = activeSurfaces.filter { $0.isValid && $0.terminalView != nil }
            return activeSurfaces.count
        }

        /// Reload configuration (call when settings change)
        func reloadConfig() {
            guard let app = self.app else { return }
            clearSurfaceConfigCache()

            // Create new config with updated settings
            guard let config = makeConfig(refreshThemes: true) else { return }

            // Update the app config
            ghostty_app_update_config(app, config)

            // Propagate config to all existing surfaces
            for surfaceRef in activeSurfaces where surfaceRef.isValid {
                if let presentationOverrides = surfaceRef.terminalView?.surfacePresentationOverrides,
                   !presentationOverrides.isEmpty,
                   let surfaceConfig = cachedSurfaceConfig(for: presentationOverrides) {
                    ghostty_surface_update_config(surfaceRef.surface, surfaceConfig)
                } else {
                    ghostty_surface_update_config(surfaceRef.surface, config)
                }
            }

            // Clean up invalid surfaces
            activeSurfaces = activeSurfaces.filter { $0.isValid }

            ghostty_config_free(config)

            Ghostty.logger.info("Configuration reloaded and propagated to \(self.activeSurfaces.count) surfaces")

            // Notify views to refresh their rendering
            NotificationCenter.default.post(name: Ghostty.configDidReloadNotification, object: nil)
        }

        func updateSurfaceConfig(_ surface: ghostty_surface_t, presentationOverrides: TerminalPresentationOverrides) {
            guard let config = cachedSurfaceConfig(for: presentationOverrides) else { return }
            ghostty_surface_update_config(surface, config)
            Ghostty.logger.info("Updated surface presentation overrides")
        }

        // MARK: - Private Helpers

        private func makeConfig(
            presentationOverrides: TerminalPresentationOverrides = .empty,
            refreshThemes: Bool
        ) -> ghostty_config_t? {
            guard let config = ghostty_config_new() else {
                Ghostty.logger.error("ghostty_config_new failed during reload")
                return nil
            }

            loadConfigIntoGhostty(
                config,
                presentationOverrides: presentationOverrides,
                refreshThemes: refreshThemes
            )
            ghostty_config_finalize(config)
            return config
        }

        private func cachedSurfaceConfig(for presentationOverrides: TerminalPresentationOverrides) -> ghostty_config_t? {
            let key = SurfaceConfigCacheKey(
                fontName: terminalFontName,
                fontSize: presentationOverrides.resolvedFontSize(),
                themeName: effectiveThemeName,
                cursorStyleRaw: terminalCursorStyle.rawValue,
                cursorBlink: terminalCursorBlink,
                optionAsAltModeRaw: terminalOptionAsAltMode.rawValue
            )

            if let cachedConfig = surfaceConfigCache[key] {
                return cachedConfig
            }

            guard let config = makeConfig(presentationOverrides: presentationOverrides, refreshThemes: false) else {
                return nil
            }

            surfaceConfigCache[key] = config
            return config
        }

        private func clearSurfaceConfigCache() {
            for config in surfaceConfigCache.values {
                ghostty_config_free(config)
            }
            surfaceConfigCache.removeAll()
        }

        /// Generate and load config content into a ghostty_config_t
        private func loadConfigIntoGhostty(
            _ config: ghostty_config_t,
            presentationOverrides: TerminalPresentationOverrides = .empty,
            refreshThemes: Bool = true
        ) {
            // Create temp config directory and use Ghostty themes
            let tempDir = NSTemporaryDirectory()
            let ghosttyConfigDir = (tempDir as NSString).appendingPathComponent(".config/ghostty")
            let configFilePath = (ghosttyConfigDir as NSString).appendingPathComponent("config")
            let tempThemesDir = (ghosttyConfigDir as NSString).appendingPathComponent("themes")

            do {
                let themesDirectoryExists = FileManager.default.fileExists(atPath: tempThemesDir)
                try FileManager.default.createDirectory(atPath: ghosttyConfigDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(atPath: tempThemesDir, withIntermediateDirectories: true)

                if refreshThemes || !themesDirectoryExists {
                    setupThemes(tempThemesDir: tempThemesDir)
                }

                // Detect shell for integration
                let shell = Foundation.ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let shellName = (shell as NSString).lastPathComponent

                // Create config with font settings, shell integration, and theme
                let effectiveFontSize = presentationOverrides.fontSize ?? TerminalDefaults.clampedFontSize(terminalFontSize)
                let themeValue = ConfigBuilder.themeConfigValue(
                    themeName: effectiveThemeName,
                    themesDirectory: tempThemesDir,
                    isFile: ConfigBuilder.isRegularFile
                )
                let configContent = ConfigBuilder.configContent(
                    primaryFontFamily: terminalFontName,
                    fontSize: effectiveFontSize,
                    shellName: shellName,
                    theme: themeValue,
                    cursorStyle: terminalCursorStyle,
                    cursorBlink: terminalCursorBlink,
                    optionAsAltMode: terminalOptionAsAltMode
                )

                Ghostty.logger.info("Loading Ghostty theme: \(self.effectiveThemeName)")

                try configContent.write(toFile: configFilePath, atomically: true, encoding: String.Encoding.utf8)

                // Load the generated config by absolute path. The theme is
                // also an absolute path, so this path never consults the
                // process environment: libghostty captures `environ` once
                // inside `ghostty_init`, and a later `setenv` that adds a
                // variable replaces the environment table, leaving that
                // capture pointing at unowned memory that `getenv` then walks
                // (issue #225).
                guard (configFilePath as NSString).isAbsolutePath else {
                    // `ghostty_config_load_file` asserts an absolute path and
                    // traps in debug/safe builds; a relative path here would be
                    // a programming error, so log rather than trap.
                    Ghostty.logger.error("Generated config path is not absolute; skipping config load: \(configFilePath, privacy: .public)")
                    return
                }
                ghostty_config_load_file(config, configFilePath)

                Ghostty.logger.info("Loaded terminal settings - Font: \(self.terminalFontName) \(Int(effectiveFontSize))pt, Theme: \(self.effectiveThemeName)")
            } catch {
                Ghostty.logger.warning("Failed to write config: \(error)")
            }
        }

        /// Setup themes in temp directory - handles both structured and flattened bundle resources
        private func setupThemes(tempThemesDir: String) {
            guard let resourcePath = Bundle.main.resourcePath else { return }

            let fm = FileManager.default

            // Check if themes are in structured path (folder reference)
            let structuredThemesPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
            if fm.fileExists(atPath: structuredThemesPath) {
                // Themes are structured - create symlink or copy
                copyThemesFromDirectory(structuredThemesPath, to: tempThemesDir)
                return
            }

            // Fallback: themes might be flattened in Resources root
            // Theme files have no extension and aren't known system files
            let knownNonThemes = Set(["Info", "Assets", "PkgInfo", "ghostty", "xterm-ghostty",
                                       "CodeSignature", "embedded", "_CodeSignature"])

            guard let files = try? fm.contentsOfDirectory(atPath: resourcePath) else { return }

            for file in files {
                let fullPath = (resourcePath as NSString).appendingPathComponent(file)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)

                // Skip directories, hidden files, files with extensions, and known non-themes
                guard !isDir.boolValue else { continue }
                guard !file.hasPrefix(".") else { continue }
                guard !file.contains(".") else { continue }
                guard !knownNonThemes.contains(file) else { continue }

                // This looks like a theme file - copy to temp themes dir
                let destPath = (tempThemesDir as NSString).appendingPathComponent(file)
                if !fm.fileExists(atPath: destPath) {
                    try? fm.copyItem(atPath: fullPath, toPath: destPath)
                }
            }

            copyCustomThemes(to: tempThemesDir)
            Ghostty.logger.info("Copied themes from flattened resources to \(tempThemesDir)")
        }

        /// Copy themes from a directory to temp themes dir
        private func copyThemesFromDirectory(_ sourcePath: String, to destPath: String) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: sourcePath) else { return }

            for file in files {
                guard !file.hasPrefix(".") else { continue }
                let src = (sourcePath as NSString).appendingPathComponent(file)
                let dst = (destPath as NSString).appendingPathComponent(file)

                var isDir: ObjCBool = false
                fm.fileExists(atPath: src, isDirectory: &isDir)
                guard !isDir.boolValue else { continue }

                if !fm.fileExists(atPath: dst) {
                    try? fm.copyItem(atPath: src, toPath: dst)
                }
            }

            copyCustomThemes(to: destPath)
            Ghostty.logger.info("Copied themes from \(sourcePath) to \(destPath)")
        }

        private func copyCustomThemes(to tempThemesDir: String) {
            let fm = FileManager.default
            let customThemesDir = TerminalThemeStoragePaths.customThemesDirectoryPath()
            guard fm.fileExists(atPath: customThemesDir) else { return }
            guard let files = try? fm.contentsOfDirectory(atPath: customThemesDir) else { return }

            for file in files {
                guard !file.hasPrefix(".") else { continue }
                let src = (customThemesDir as NSString).appendingPathComponent(file)
                let dst = (tempThemesDir as NSString).appendingPathComponent(file)

                var isDir: ObjCBool = false
                fm.fileExists(atPath: src, isDirectory: &isDir)
                guard !isDir.boolValue else { continue }

                if fm.fileExists(atPath: dst) {
                    try? fm.removeItem(atPath: dst)
                }
                try? fm.copyItem(atPath: src, toPath: dst)
            }
        }

        // MARK: - Callbacks (macOS)

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata = userdata else { return }
            let state = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                state.appTick()
            }
        }

        /// Opens a URL in the platform's default handler. Swappable seam so
        /// tests can observe link activations without launching Safari.
        static var externalURLHandler: (URL) -> Void = { url in
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url) { success in
                Ghostty.logger.diagInfo(
                    "terminal-link",
                    "open result success=\(success)"
                )
            }
            #endif
        }

        /// Presents a link-activation confirmation and calls back with the
        /// user's decision. Swappable so tests can auto-confirm/auto-cancel.
        /// macOS has hover preview (the safe affordance) → direct open, no
        /// dialog.
        static var linkConfirmationHandler: (URL, @escaping (Bool) -> Void) -> Void = { url, completion in
            #if os(macOS)
            completion(true)
            #else
            Ghostty.App.presentLinkConfirmation(for: url, completion: completion)
            #endif
        }

        #if os(macOS)
        /// Per-window hover state: the title captured when a hover preview
        /// started and the URL currently shown. Restore is conditional —
        /// the saved title is only written back while the title still shows
        /// the hovered URL, so a session SET_TITLE during the hover wins.
        /// Pruned against the live window set on each hover.
        private static var hoverPreviewState: [ObjectIdentifier: (savedTitle: String, hoveredURL: String)] = [:]

        private static func pruneHoverPreviewState() {
            let liveWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
            hoverPreviewState = hoverPreviewState.filter { liveWindows.contains($0.key) }
        }
        #endif

        static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            // Get the terminal view from surface userdata if target is a surface
            var titleTargetDescription = "target \(target.tag.rawValue)"
            // The active-surface registry is MainActor state and is only read
            // on the main thread, so the warning below must not print a
            // meaningful-looking count for an off-main action: it stays
            // "unavailable" unless the registry was actually consulted.
            var activeSurfaceCountDescription = "active surfaces: unavailable"
            let terminalView: GhosttyTerminalView? = {
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
                guard let surface = target.target.surface else { return nil }
                titleTargetDescription = String(describing: surface)

                // #310: resolve the retained context first. It is
                // lock-protected and safe to read off the main actor; a dead
                // view resolves to nil without touching MainActor state, so
                // this also retires the unchecked off-main registry access.
                let contextView = Ghostty.SurfaceCallbackContext
                    .fromOpaque(ghostty_surface_userdata(surface))?
                    .resolve()

                // The registry stays the preferred route, but it is MainActor
                // state: only consult it on the main thread. Off-main the
                // context above has already resolved the same weak view.
                if Thread.isMainThread, let appUserdata = ghostty_app_userdata(app) {
                    let state = Unmanaged<App>.fromOpaque(appUserdata).takeUnretainedValue()
                    activeSurfaceCountDescription = "active surfaces: \(state.activeSurfaceCount())"
                    if let registeredView = state.terminalView(for: surface) {
                        return registeredView
                    }
                }
                return contextView
            }()

            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE:
                // Window/tab title change
                if let titlePtr = action.action.set_title.title {
                    let title = String(cString: titlePtr)

                    // Propagate to terminal view callback
                    DispatchQueue.main.async {
                        guard let terminalView else {
                            if TitleDeliveryLogCache.lastUndeliveredTitleBySurface[titleTargetDescription] != title {
                                TitleDeliveryLogCache.lastUndeliveredTitleBySurface[titleTargetDescription] = title
                                Ghostty.logger.warning(
                                    "Ghostty title received without terminal view: \(title, privacy: .public), target: \(titleTargetDescription, privacy: .public), \(activeSurfaceCountDescription)"
                                )
                            }
                            return
                        }

                        guard terminalView.onTitleChange != nil else {
                            if TitleDeliveryLogCache.lastUndeliveredTitleBySurface[titleTargetDescription] != title {
                                TitleDeliveryLogCache.lastUndeliveredTitleBySurface[titleTargetDescription] = title
                                Ghostty.logger.warning(
                                    "Ghostty title received before title callback was installed: \(title, privacy: .public), target: \(titleTargetDescription, privacy: .public)"
                                )
                            }
                            return
                        }

                        terminalView.onTitleChange?(title)
                    }
                }
                return true

            case GHOSTTY_ACTION_PWD:
                // Working directory change
                if let pwdPtr = action.action.pwd.pwd {
                    let pwd = String(cString: pwdPtr)
                    Ghostty.logger.info("PWD changed: \(pwd)")
                    DispatchQueue.main.async {
                        #if DEBUG
                        #if os(iOS)
                        terminalView?.keyboardUITestLastPwdRaw = pwd
                        #endif
                        #endif
                        terminalView?.onPwdChange?(pwd)
                    }
                }
                return true

            case GHOSTTY_ACTION_PROMPT_TITLE:
                // Prompt title update (for shell integration)
                Ghostty.logger.debug("Prompt title action received")
                return true

            case GHOSTTY_ACTION_PROGRESS_REPORT:
                let report = action.action.progress_report
                let state = GhosttyProgressState(cState: report.state)
                let value = report.progress >= 0 ? Int(report.progress) : nil
                DispatchQueue.main.async {
                    terminalView?.onProgressReport?(state, value)
                }
                return true

            case GHOSTTY_ACTION_START_SEARCH:
                #if os(iOS)
                let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
                DispatchQueue.main.async {
                    terminalView?.handleGhosttySearchStarted(needle: needle)
                }
                return true
                #else
                return false
                #endif

            case GHOSTTY_ACTION_END_SEARCH:
                #if os(iOS)
                DispatchQueue.main.async {
                    terminalView?.handleGhosttySearchEnded()
                }
                return true
                #else
                return false
                #endif

            case GHOSTTY_ACTION_SEARCH_TOTAL:
                #if os(iOS)
                let total = action.action.search_total.total >= 0 ? Int(action.action.search_total.total) : nil
                DispatchQueue.main.async {
                    terminalView?.handleGhosttySearchTotalChange(total)
                }
                return true
                #else
                return false
                #endif

            case GHOSTTY_ACTION_SEARCH_SELECTED:
                #if os(iOS)
                let selected = action.action.search_selected.selected >= 0 ? Int(action.action.search_selected.selected) : nil
                DispatchQueue.main.async {
                    terminalView?.handleGhosttySearchSelectedChange(selected)
                }
                return true
                #else
                return false
                #endif

            case GHOSTTY_ACTION_CELL_SIZE:
                // Cell size update - used for row-to-pixel conversion in scrollbar
                #if os(macOS)
                let cellSize = action.action.cell_size
                let backingSize = NSSize(width: Double(cellSize.width), height: Double(cellSize.height))
                DispatchQueue.main.async {
                    guard let terminalView = terminalView else { return }
                    // Convert from backing (pixel) coordinates to points
                    terminalView.cellSize = terminalView.convertFromBacking(backingSize)
                }
                #else
                let cellSize = action.action.cell_size
                DispatchQueue.main.async {
                    guard let terminalView = terminalView else { return }
                    // Convert from backing (pixel) coordinates to points
                    let scale = terminalView.window?.screen.scale ?? max(terminalView.traitCollection.displayScale, 1)
                    terminalView.cellSize = CGSize(
                        width: Double(cellSize.width) / scale,
                        height: Double(cellSize.height) / scale
                    )
                }
                #endif
                return true

            case GHOSTTY_ACTION_SCROLLBAR:
                // Scrollbar state update - post notification for scroll view
                let scrollbar = Ghostty.Action.Scrollbar(c: action.action.scrollbar)
                NotificationCenter.default.post(
                    name: .ghosttyDidUpdateScrollbar,
                    object: terminalView,
                    userInfo: [Notification.Name.ScrollbarKey: scrollbar]
                )
                return true

            case GHOSTTY_ACTION_READONLY:
                let isReadonly = action.action.readonly == GHOSTTY_READONLY_ON
                DispatchQueue.main.async {
                    terminalView?.updateReadonlyState(isReadonly)
                }
                return true

            case GHOSTTY_ACTION_MOUSE_SHAPE,
                 GHOSTTY_ACTION_MOUSE_VISIBILITY:
                #if os(iOS)
                return true
                #else
                Ghostty.logger.debug("Action received: \(action.tag.rawValue) on target: \(target.tag.rawValue)")
                return false
                #endif

            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                // Hover preview (macOS): while the pointer is over an OSC 8
                // hyperlink, surface the URL in the window title — the safe
                // affordance that shows where a link goes before clicking.
                // An empty URL means the pointer left the link: restore the
                // pre-hover title. iOS swallows the action; link activation
                // goes through the confirmation dialog instead.
                #if os(iOS)
                return true
                #else
                guard let terminalView, let window = terminalView.window else {
                    return true
                }
                let overLink = action.action.mouse_over_link
                let urlString: String? = if let urlPtr = overLink.url, overLink.len > 0 {
                    // C string is [CChar] (Int8); String(decoding:as:) needs
                    // UInt8 — rebind for the duration of the copy (same as
                    // the open_url path).
                    urlPtr.withMemoryRebound(
                        to: UInt8.self,
                        capacity: Int(overLink.len)
                    ) { bytes in
                        String(
                            decoding: UnsafeBufferPointer(start: bytes, count: Int(overLink.len)),
                            as: UTF8.self
                        )
                    }
                } else {
                    nil
                }
                // The action callback can run off-main; AppKit state must be
                // touched on the main thread. Main-queue hops are FIFO, so
                // the leave-restore is order-preserving after any pending
                // hover sets.
                DispatchQueue.main.async {
                    Self.pruneHoverPreviewState()
                    let windowKey = ObjectIdentifier(window)
                    if let urlString, !urlString.isEmpty {
                        if Self.hoverPreviewState[windowKey] == nil {
                            Self.hoverPreviewState[windowKey] = (window.title, urlString)
                        }
                        window.title = urlString
                    } else if let state = Self.hoverPreviewState.removeValue(forKey: windowKey) {
                        if window.title == state.hoveredURL {
                            window.title = state.savedTitle
                        }
                    }
                }
                return true
                #endif

            case GHOSTTY_ACTION_OPEN_URL:
                // OSC 8 hyperlink activated (or file/text link). The core's
                // own fallback `internal_os.open` is `error.Unimplemented`
                // on iOS, so an unhandled action means link clicks are
                // silent no-ops. Only http(s) is routed to the platform
                // opener: a remote host controls this string, and arbitrary
                // schemes would let it drive `file://`, `itms-apps://`, …
                // on the device. Non-http(s) falls through to the core's
                // fallback (macOS `open` handles file://; iOS no-ops).
                let openURL = action.action.open_url
                guard let urlPtr = openURL.url else { return false }
                // C string is [CChar] (Int8); String(decoding:as:) needs
                // UInt8 — rebind for the duration of the copy.
                let urlString = urlPtr.withMemoryRebound(
                    to: UInt8.self,
                    capacity: Int(openURL.len)
                ) { bytes in
                    String(
                        decoding: UnsafeBufferPointer(start: bytes, count: Int(openURL.len)),
                        as: UTF8.self
                    )
                }
                // Diagnostics (no raw host in the shareable report — scheme
                // + length only; full URL stays in os_log as .private).
                guard let url = URL(string: urlString),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else {
                    let scheme = URL(string: urlString)?.scheme ?? "none"
                    Ghostty.logger.diagInfo(
                        "terminal-link",
                        "open_url action REJECTED scheme=\(scheme) length=\(urlString.count)"
                    )
                    Ghostty.logger.debug("open_url rejected url=\(urlString, privacy: .private)")
                    return false
                }
                Ghostty.logger.diagInfo(
                    "terminal-link",
                    "open_url action handled scheme=\(scheme) length=\(urlString.count)"
                )
                Ghostty.logger.debug("open_url url=\(urlString, privacy: .private)")
                DispatchQueue.main.async {
                    Ghostty.App.linkConfirmationHandler(url) { confirmed in
                        if confirmed { Ghostty.App.externalURLHandler(url) }
                    }
                }
                return true

            default:
                // Log unhandled actions
                Ghostty.logger.debug("Action received: \(action.tag.rawValue) on target: \(target.tag.rawValue)")
                return false
            }
        }

        // Upstream changed this callback to return Bool: true when the
        // clipboard content was provided to libghostty, false when it can't
        // be read so performable paste bindings fall through to the terminal.
        static func readClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
            // userdata is the surface's retained callback context (#310).
            // Thread contract: the core's termio stream handler (OSC 52,
            // `termio/stream_handler.zig:963-977`) sends `.clipboard_read` to
            // the surface MAILBOX from the I/O thread; `Surface.handleMessage`
            // — documented "Called from the app thread" (`Surface.zig:970-972`,
            // handler at `:1055-1062`) — handles it on the app thread, which
            // VVTerm's `wakeup` ticks on the main queue. That is the same
            // thread the main-actor `free()` runs on, so the surface-handle
            // read below is not a live race. The context is what makes the
            // view resolution safe for the callbacks that can run off-main
            // (the write callback and the `action` fallback); it is not needed
            // to make these reads race-free.
            guard let context = Ghostty.SurfaceCallbackContext.fromOpaque(userdata),
                  let terminalView = context.resolve()
            else { return false }
            guard let surface = terminalView.surface?.unsafeCValue else { return false }

            // Read from macOS clipboard
            guard let clipboardString = Clipboard.readString() else { return false }

            // Complete the clipboard request by providing data to Ghostty
            clipboardString.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }

            Ghostty.logger.debug("Read clipboard: \(clipboardString.prefix(50), privacy: .private)...")
            return true
        }

        /// #327: the ghostty clipboard-confirmation contract. The core calls
        /// this after a clipboard read when the request needs confirmation;
        /// the embedder must then complete the request exactly once
        /// (`apprt/embedded.zig:60-68`, `:1998-2010`). Only the user-initiated
        /// paste kind prompts; every other kind is denied immediately, without
        /// a prompt and without copying the payload.
        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            #if DEBUG
            GhosttyClipboardConfirmDebug.noteCallback(kind: request)
            #endif

            // Kind policy first: a kind that will be denied must not even copy
            // the payload, whose pointer is only valid inside this frame.
            //
            // `.osc_52_read` cannot reach here under `clipboard-read = deny`
            // (`Surface.zig:1055-1058`, `:5898-5904`); if that config ever
            // becomes `ask`, this branch must present a read-specific prompt
            // (upstream macOS: `macos/Sources/Ghostty/Ghostty.App.swift:305-334`)
            // or the read is denied.
            guard ClipboardConfirmationPolicy.requiresUserPrompt(request) else {
                Ghostty.logger.warning("clipboard request denied without prompt kind=\(request.rawValue)")
                guard let context = Ghostty.SurfaceCallbackContext.fromOpaque(userdata),
                      let view = context.resolve(),
                      let surface = view.surface?.unsafeCValue
                else {
                    // Accepted residual: no live surface handle to complete on.
                    Ghostty.logger.warning("clipboard request deny skipped: dead surface kind=\(request.rawValue)")
                    return
                }
                // #329: register the request before completing it so the
                // completion's claim consumes the entry it just added; a
                // deniable request must never leave a registry entry behind.
                if let state {
                    context.registerPendingClipboardRequest(state: state, kind: request)
                }
                // Empty data is the deny form: for `.paste` the core returns
                // before pasting (`Surface.zig:5918`); for `.osc_52_read` it
                // replies with an empty OSC 52 payload (`:6006-6027`). Either
                // way the completion destroys the request state
                // (`embedded.zig:751`).
                complete(surface: surface, payload: "", state: state, confirmed: true, kind: request, context: context)
                return
            }

            // `userdata` is unretained (`Ghostty.SurfaceCallbackContext.swift`)
            // and only valid inside this frame, so the completion closure must
            // keep the resolved context (and the view) alive itself: a
            // completion-time `fromOpaque(userdata)` would be a #310-class UAF.
            guard let context = Ghostty.SurfaceCallbackContext.fromOpaque(userdata),
                  let view = context.resolve(),
                  let surface = view.surface?.unsafeCValue
            else {
                // Accepted residual: the surface is gone, so there is no live
                // handle to complete on (the core exports no cancel route).
                // Reachable only from a user-driven paste on a surface that died
                // during this call — never from remote input. The resolve guard
                // sits above the payload copy so this path never copies
                // clipboard content it cannot deliver.
                Ghostty.logger.warning("clipboard confirmation skipped: dead surface")
                return
            }

            // Copy NOW: `string` points at the core's request state and is only
            // valid for the duration of this callback frame (the confirm route
            // forwards `str.ptr` without copying — `embedded.zig:736-744`).
            let payload = string.map { String(cString: $0) } ?? ""

            // #329: register the in-flight request so a surface free while the
            // prompt is open releases it as a deny completion instead of
            // retaining the core's allocation for the surface's lifetime.
            if let state {
                context.registerPendingClipboardRequest(state: state, kind: request)
            }

            // Keep the alert off the binding stack: this frame returns before
            // any presentation starts.
            Task { @MainActor in
                let confirmation = ClipboardConfirmationRequest(payload: payload)
                let allow: Bool
                if let decision = view.clipboardConfirmationDecision {
                    // Test seam: per-view, so parallel tests cannot cross-talk.
                    allow = decision(confirmation)
                } else {
                    allow = await Ghostty.App.presentClipboardConfirmation(confirmation, on: view)
                }

                // Completion-time gate: the captured surface handle must still
                // be the view's live surface. `unsafeCValue` is nil after
                // `cleanup()` freed it while the view lives on, and a recreated
                // surface would carry a different handle.
                guard let liveView = context.resolve(),
                      liveView.surface?.unsafeCValue == surface
                else {
                    Ghostty.logger.warning("clipboard confirmation completion skipped: surface no longer live")
                    return
                }

                complete(
                    surface: surface,
                    payload: allow ? payload : "",
                    state: state,
                    confirmed: true,
                    kind: request,
                    context: context
                )
            }
        }

        /// Completes a clipboard request. The core's shim owns the one-shot
        /// contract — "can only be called once for a given request. Once it is
        /// called with a request the request pointer will be invalidated"
        /// (`apprt/embedded.zig:1998-2010`) — so every exit path of
        /// `confirmReadClipboard` routes through here and the DEBUG telemetry
        /// records each call, making "at most once" checkable in one place.
        ///
        /// #329: the completion first claims its registered request from the
        /// context. The claim removes the registry entry so a later teardown
        /// drain cannot re-complete an already-destroyed request state; a claim
        /// that fails means the request was already released, already claimed,
        /// or never registered, and the completion must not run. The `context`
        /// parameter is deliberately non-optional: a `nil` context would bypass
        /// the claim entirely. The order inside this body is load-bearing:
        /// nil-state guard, then claim, then telemetry, then the C call.
        private static func complete(
            surface: ghostty_surface_t,
            payload: String,
            state: UnsafeMutableRawPointer?,
            confirmed: Bool,
            kind: ghostty_clipboard_request_e,
            context: Ghostty.SurfaceCallbackContext
        ) {
            guard let state else {
                Ghostty.logger.warning("clipboard completion skipped: no request state kind=\(kind.rawValue)")
                return
            }
            guard context.claimPendingClipboardRequest(state) else {
                Ghostty.logger.warning(
                    "clipboard completion skipped: request not pending (teardown-drained, already claimed, or never registered) kind=\(kind.rawValue)"
                )
                return
            }
            #if DEBUG
            GhosttyClipboardConfirmDebug.noteCompletion(
                kind: kind,
                byteLength: payload.utf8.count,
                confirmed: confirmed
            )
            #endif
            payload.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
            }
        }

        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            contents: UnsafePointer<ghostty_clipboard_content_s>?,
            count: Int,
            confirm: Bool
        ) {
            guard let contents = contents, count > 0 else { return }
            #if os(iOS)
            guard location != GHOSTTY_CLIPBOARD_SELECTION else { return }
            #endif

            // The runtime passes an array of clipboard entries; prefer the first
            // textual entry. The API does not supply a byte length, so we treat
            // the data as a null-terminated UTF-8 C string.
            for idx in 0..<count {
                let entry = contents.advanced(by: idx).pointee
                guard let dataPtr = entry.data else { continue }

                var string = String(cString: dataPtr)
                if !string.isEmpty {
                    // Apply copy transformations from settings
                    string = TerminalTextCleaner.cleanText(string, settings: .current())

                    Clipboard.copy(string)
                    Ghostty.logger.debug("Wrote to clipboard: \(string.prefix(50))...")
                    return
                }
            }
        }

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            // userdata is the surface's retained callback context (#310); a
            // view already released without `cleanup()` resolves to nil, so
            // the close callback becomes a no-op instead of a UAF.
            guard let context = Ghostty.SurfaceCallbackContext.fromOpaque(userdata),
                  let terminalView = context.resolve()
            else { return }

            Ghostty.logger.info("Close surface: processAlive=\(processAlive)")

            // Trigger process exit callback on main thread
            DispatchQueue.main.async {
                terminalView.onProcessExit?()
            }
        }
    }
}

#if os(iOS)
extension Ghostty.App {
    /// Default iOS link-activation confirmation: an alert showing the exact
    /// URL that would open. Fail-safe: without a presentation context, or
    /// while another alert is already presented, the request is dropped
    /// (logged, never opened). Runs on the main actor — callers dispatch to
    /// main before invoking the confirmation seam.
    private static func presentLinkConfirmation(for url: URL, completion: @escaping (Bool) -> Void) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }),
            let rootViewController = window.rootViewController
        else {
            Ghostty.logger.debug("open_url confirmation dropped: no key window")
            completion(false)
            return
        }
        // Walk the presented-view-controller chain to the top-most presenter.
        var presenter = rootViewController
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        // Drop while an alert is already on screen: the top-most presenter
        // IS the alert in that case (a UIAlertController presenting another
        // alert is not supported). Without this, rapid link taps would
        // stack alerts.
        guard !(presenter is UIAlertController) else {
            Ghostty.logger.debug("open_url confirmation dropped: alert already presented")
            completion(false)
            return
        }
        let alert = UIAlertController(
            title: "Open Link",
            message: url.absoluteString,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        })
        alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in
            completion(true)
        })
        presenter.present(alert, animated: true)
    }
}
#endif
