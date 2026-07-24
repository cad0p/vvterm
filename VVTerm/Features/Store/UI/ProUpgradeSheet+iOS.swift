#if os(iOS)
import SwiftUI
import UIKit

extension ProUpgradeSheet {
    func openSubscriptionManagement() {
        showManageSubscription = true
    }

    var sheetBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }
}

extension ProUpgradePresentationModifier {
    func platformBody(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                ProUpgradeSheet(source: source)
                    .adaptiveSoftScrollEdges()
            }
    }
}

var paywallTableGridColor: Color {
    Color.primary.opacity(0.10)
}

var paywallCardFillColor: Color {
    Color(uiColor: .secondarySystemGroupedBackground)
}

var paywallCardBorderColor: Color {
    Color.primary.opacity(0.10)
}
#endif
