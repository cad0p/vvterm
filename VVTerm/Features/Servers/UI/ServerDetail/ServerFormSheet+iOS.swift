#if os(iOS)
import SwiftUI

extension ServerFormSheet {
    var platformBody: some View {
        formContent
    }
}

extension MoveServerSheet {
    var platformBody: some View {
        formContent
    }
}
#endif
