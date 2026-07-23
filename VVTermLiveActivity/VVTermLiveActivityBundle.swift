#if os(iOS)
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
@main
struct VVTermLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        VVTermLauncherWidget()
        VVTermLiveActivityWidget()
    }
}
#endif
