//
//  TerminalDefaults.swift
//  VVTerm
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum TerminalCursorStyle: String, CaseIterable, Codable, Identifiable {
    case block
    case bar
    case underline
    case blockHollow = "block_hollow"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .block: return String(localized: "Block")
        case .bar: return String(localized: "Bar")
        case .underline: return String(localized: "Underline")
        case .blockHollow: return String(localized: "Block Hollow")
        }
    }
}

enum TerminalZoomAction {
    case zoomIn
    case zoomOut
    case reset
}

enum TerminalOptionAsAltMode: String, CaseIterable, Identifiable {
    case none
    case left
    case right
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "Neither Option Key")
        case .left: return String(localized: "Left Option Key")
        case .right: return String(localized: "Right Option Key")
        case .both: return String(localized: "Both Option Keys")
        }
    }

    func usesOptionKeyAsAlt(_ side: TerminalOptionKeySide) -> Bool {
        switch (self, side) {
        case (.none, _): false
        case (.left, .left), (.right, .right), (.both, _): true
        default: false
        }
    }
}

enum TerminalOptionKeySide {
    case left
    case right
}

struct TerminalZoomResult: Hashable {
    let presentationOverrides: TerminalPresentationOverrides
    let effectiveFontSize: Double
}

struct TerminalPresentationOverrides: Codable, Hashable, Sendable {
    nonisolated static let empty = TerminalPresentationOverrides()

    var fontSize: Double?

    init(fontSize: Double? = nil) {
        self.fontSize = fontSize.map(TerminalDefaults.clampedFontSize)
    }

    var isEmpty: Bool {
        fontSize == nil
    }

    func resolvedFontSize(defaults: UserDefaults = .standard) -> Double {
        fontSize ?? TerminalDefaults.storedFontSize(defaults: defaults)
    }

    func applyingZoom(_ action: TerminalZoomAction, defaults: UserDefaults = .standard) -> TerminalPresentationOverrides {
        var overrides = self
        let currentFontSize = resolvedFontSize(defaults: defaults)

        switch action {
        case .zoomIn:
            overrides.fontSize = TerminalDefaults.clampedFontSize(currentFontSize + TerminalDefaults.fontSizeStep)
        case .zoomOut:
            overrides.fontSize = TerminalDefaults.clampedFontSize(currentFontSize - TerminalDefaults.fontSizeStep)
        case .reset:
            overrides.fontSize = nil
        }

        return overrides
    }
}

enum TerminalZoomPresentation {
    static let pinchZoomInThreshold = 1.12
    static let pinchZoomOutThreshold = 0.89
    static let magnificationStepThreshold = 0.12
    static let indicatorFadeInDuration = 0.12
    static let indicatorFadeOutDuration = 0.18
    static let indicatorHideDelay = 0.8
    static let indicatorGestureEndHideDelay = 0.45
    static let indicatorMinimumWidth = 112.0
    static let indicatorMinimumHeight = 72.0

    static var indicatorTitle: String {
        String(localized: "Font Size")
    }

    static func formattedFontSize(_ fontSize: Double) -> String {
        String(format: "%.0f pt", fontSize)
    }
}

enum TerminalDefaults {
    static let fontNameKey = "terminalFontName"
    static let fontSizeKey = "terminalFontSize"
    static let cursorStyleKey = "terminalCursorStyle"
    static let cursorBlinkKey = "terminalCursorBlink"
    static let sshAutoReconnectKey = "sshAutoReconnect"
    static let optionAsAltModeKey = "terminalOptionAsAltMode"
    static let preserveTerminalSizeForKeyboardKey = "terminalPreserveSizeForKeyboard"
    static let legacyDefaultFontName = "JetBrainsMono Nerd Font"
    static let minimumFontSize = 4.0
    static let maximumFontSize = 32.0
    static let fontSizeStep = 1.0
    static let defaultCursorStyle: TerminalCursorStyle = .block
    static let defaultCursorBlink = true
    #if os(macOS)
    static let defaultPrimaryFontName = "Menlo"
    static let macOSFallbackFontFamilies = [
        "Apple SD Gothic Neo",
        legacyDefaultFontName
    ]
    #endif

    static func applyIfNeeded() {
        applyIfNeeded(defaults: .standard)
    }

    static func applyIfNeeded(defaults: UserDefaults) {
        seedFontDefaultsIfNeeded(defaults: defaults)
        seedCursorDefaultsIfNeeded(defaults: defaults)

        if defaults.object(forKey: ImagePasteBehavior.userDefaultsKey) == nil {
            let imagePasteBehavior = RichClipboardSettings.resolvedImagePasteBehavior(defaults: defaults)
            defaults.set(imagePasteBehavior.rawValue, forKey: ImagePasteBehavior.userDefaultsKey)
        }
    }

    nonisolated static func clampedFontSize(_ fontSize: Double) -> Double {
        min(max(fontSize.rounded(), minimumFontSize), maximumFontSize)
    }

    static func storedFontSize(defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.object(forKey: fontSizeKey) as? Double ?? defaultFontSize
        return clampedFontSize(stored)
    }

    static func sshAutoReconnectEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: sshAutoReconnectKey) as? Bool) ?? true
    }

    static func optionAsAltMode(defaults: UserDefaults = .standard) -> TerminalOptionAsAltMode {
        guard let rawValue = defaults.string(forKey: optionAsAltModeKey) else { return .none }
        return TerminalOptionAsAltMode(rawValue: rawValue) ?? .none
    }

    static var defaultFontSize: Double {
        #if os(macOS)
        return 12.0
        #elseif os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return 12.0
        case .phone:
            return 9.0
        default:
            return 10.0
        }
        #else
        return 10.0
        #endif
    }

    #if os(macOS)
    static var defaultFontName: String {
        defaultPrimaryFontName
    }
    #else
    static var defaultFontName: String {
        legacyDefaultFontName
    }
    #endif

    private static func seedFontDefaultsIfNeeded(defaults: UserDefaults) {
        #if os(macOS)
        seedMacOSFontDefaultsIfNeeded(defaults: defaults)
        #else
        if let fontName = defaults.string(forKey: fontNameKey) {
            if fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.set(defaultFontName, forKey: fontNameKey)
            }
        } else {
            defaults.set(defaultFontName, forKey: fontNameKey)
        }

        if defaults.object(forKey: fontSizeKey) == nil {
            defaults.set(defaultFontSize, forKey: fontSizeKey)
        }
        #endif
    }

    private static func seedCursorDefaultsIfNeeded(defaults: UserDefaults) {
        if let rawStyle = defaults.string(forKey: cursorStyleKey),
           TerminalCursorStyle(rawValue: rawStyle) != nil {
            // Existing value is valid.
        } else {
            defaults.set(defaultCursorStyle.rawValue, forKey: cursorStyleKey)
        }

        if defaults.object(forKey: cursorBlinkKey) == nil {
            defaults.set(defaultCursorBlink, forKey: cursorBlinkKey)
        }
    }

    #if os(macOS)
    private static func seedMacOSFontDefaultsIfNeeded(defaults: UserDefaults) {
        let storedFontName = defaults.string(forKey: fontNameKey)
        let normalizedStoredFontName = storedFontName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedFontSize = defaults.object(forKey: fontSizeKey) as? Double

        if normalizedStoredFontName == nil || normalizedStoredFontName?.isEmpty == true {
            defaults.set(defaultPrimaryFontName, forKey: fontNameKey)
        }

        if storedFontSize == nil {
            defaults.set(defaultFontSize, forKey: fontSizeKey)
        }

        guard let resolvedFontName = defaults.string(forKey: fontNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resolvedFontName.isEmpty else {
            return
        }

        let normalizedFontName = normalizedMacOSFontName(
            storedFontName: resolvedFontName,
            fontAvailability: { isAvailableMacOSFont(named: $0) }
        )

        if normalizedFontName != resolvedFontName {
            defaults.set(normalizedFontName, forKey: fontNameKey)
        }
    }

    static func normalizedMacOSFontName(
        storedFontName: String,
        fontAvailability: (String) -> Bool
    ) -> String {
        fontAvailability(storedFontName) ? storedFontName : defaultPrimaryFontName
    }

    private static func isAvailableMacOSFont(named fontName: String) -> Bool {
        NSFont(name: fontName, size: 12) != nil
    }
    #endif
}
