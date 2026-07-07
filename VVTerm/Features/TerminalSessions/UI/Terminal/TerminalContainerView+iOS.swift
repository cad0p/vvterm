#if os(iOS)
import SwiftUI
import UIKit

extension TerminalContainerView {
    static func platformFallbackBackgroundColor() -> Color {
        Color(UIColor.systemBackground)
    }

    func platformTerminalWrapperDidAppear() {}

    func platformTerminalWrapperDidDisappear() {}
}
#endif
