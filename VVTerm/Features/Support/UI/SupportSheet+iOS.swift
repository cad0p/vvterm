#if os(iOS)
import SwiftUI
import UIKit

extension SupportSheet {
    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

extension View {
    /// Presents the diagnostics file via the iOS share sheet.
    func diagnosticsSharePresentation(item: Binding<FileShareItem?>) -> some View {
        sheet(item: item) { shareItem in
            FileShareSheet(item: shareItem) {
                DiagnosticsExporter.cleanup(reportAt: shareItem.fileURL)
                item.wrappedValue = nil
            }
        }
    }
}

#endif
