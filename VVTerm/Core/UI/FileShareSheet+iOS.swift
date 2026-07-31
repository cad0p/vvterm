#if os(iOS)
import SwiftUI
import UIKit

/// Generic share sheet for a local file, presented via `.sheet(item:)`.
struct FileShareSheet: UIViewControllerRepresentable {
    let item: FileShareItem
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [item.fileURL],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            context.coordinator.finish()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    final class Coordinator {
        private let onComplete: () -> Void
        private var didFinish = false

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func finish() {
            guard !didFinish else { return }
            didFinish = true
            onComplete()
        }
    }
}
#endif
