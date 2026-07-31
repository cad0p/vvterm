#if os(macOS)
import SwiftUI
import AppKit

/// Generic sharing picker for a local file. Host in a 1pt overlay where the
/// picker should anchor; `onComplete` clears the presenting state.
struct FileSharePicker: NSViewRepresentable {
    let item: FileShareItem
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.presentIfNeeded(item: item, from: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        private let onComplete: () -> Void
        private var activeItemID: UUID?
        private var activePicker: NSSharingServicePicker?
        private var activeService: NSSharingService?
        private var didFinish = false

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func presentIfNeeded(item: FileShareItem, from view: NSView) {
            guard activeItemID != item.id else { return }

            activeItemID = item.id
            didFinish = false

            let picker = NSSharingServicePicker(items: [item.fileURL])
            picker.delegate = self
            activePicker = picker

            DispatchQueue.main.async { [weak self, weak view] in
                guard self != nil, let view else { return }
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard let service else {
                finish()
                return
            }

            activeService = service
            service.delegate = self
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish()
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            finish()
        }

        private func finish() {
            guard !didFinish else { return }
            didFinish = true
            activePicker = nil
            activeService = nil
            activeItemID = nil
            onComplete()
        }
    }
}
#endif
