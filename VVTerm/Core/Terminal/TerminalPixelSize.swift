import CoreGraphics
import Foundation

/// Backing-pixel dimensions accepted by the SSH and ET wire protocols.
struct TerminalPixelSize: Equatable, Sendable {
    let width: Int
    let height: Int

    init?(width: CGFloat, height: CGFloat) {
        guard width.isFinite, height.isFinite,
              width > 0, height > 0,
              width <= CGFloat(Int32.max), height <= CGFloat(Int32.max) else {
            return nil
        }

        let pixelWidth = Int(width.rounded(.down))
        let pixelHeight = Int(height.rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        self.width = pixelWidth
        self.height = pixelHeight
    }

    init?(size: CGSize) {
        self.init(width: size.width, height: size.height)
    }
}
