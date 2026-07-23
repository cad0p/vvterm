import CoreGraphics

nonisolated enum TerminalAccessoryAppearancePolicy {
    static func isDarkBackground(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        return luminance < 0.55
    }
}
