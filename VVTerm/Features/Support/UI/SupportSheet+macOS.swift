#if os(macOS)
import AppKit
import SwiftUI

extension SupportSheet {
    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension View {
    /// Presents the diagnostics file via the macOS sharing picker,
    /// anchored to a 1pt overlay at the top trailing corner.
    func diagnosticsSharePresentation(item: Binding<FileShareItem?>) -> some View {
        overlay(alignment: .topTrailing) {
            if let shareItem = item.wrappedValue {
                FileSharePicker(item: shareItem) {
                    DiagnosticsExporter.cleanup(reportAt: shareItem.fileURL)
                    item.wrappedValue = nil
                }
                .frame(width: 1, height: 1)
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
        }
    }
}
#endif
