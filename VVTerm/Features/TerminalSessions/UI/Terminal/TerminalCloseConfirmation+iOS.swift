#if os(iOS)
import SwiftUI
import UIKit

enum TerminalRouteModalPresentationPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    func terminalCloseConfirmationAlert(
        isPresented: Binding<Bool>,
        message: String,
        onCancel: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) -> some View {
        background {
            TerminalCloseConfirmationPresenter(
                isPresented: isPresented,
                message: message,
                onCancel: onCancel,
                onClose: onClose
            )
            .frame(width: 0, height: 0)
        }
        .preference(
            key: TerminalRouteModalPresentationPreferenceKey.self,
            value: isPresented.wrappedValue
        )
    }
}

private struct TerminalCloseConfirmationPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let message: String
    let onCancel: () -> Void
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> TerminalCloseAlertHostController {
        TerminalCloseAlertHostController()
    }

    func updateUIViewController(
        _ controller: TerminalCloseAlertHostController,
        context: Context
    ) {
        guard isPresented else {
            controller.update(request: nil)
            return
        }

        controller.update(
            request: TerminalCloseAlertRequest(
                message: message,
                cancel: {
                    isPresented = false
                    onCancel()
                },
                close: {
                    isPresented = false
                    onClose()
                }
            )
        )
    }

    static func dismantleUIViewController(
        _ controller: TerminalCloseAlertHostController,
        coordinator: ()
    ) {
        controller.update(request: nil)
    }
}

private struct TerminalCloseAlertRequest {
    let message: String
    let cancel: () -> Void
    let close: () -> Void
}

enum TerminalCloseAlertFactory {
    static func make(
        message: String,
        onCancel: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> UIAlertController {
        let alert = UIAlertController(
            title: String(localized: "Close this terminal?"),
            message: message,
            preferredStyle: .alert
        )
        let cancel = UIAlertAction(
            title: String(localized: "Cancel"),
            style: .cancel,
            handler: { _ in onCancel() }
        )
        let close = UIAlertAction(
            title: String(localized: "Close"),
            style: .destructive,
            handler: { _ in onClose() }
        )
        alert.addAction(cancel)
        alert.addAction(close)
        alert.preferredAction = close
        return alert
    }
}

private final class TerminalCloseAlertHostController: UIViewController {
    private var request: TerminalCloseAlertRequest?
    private var closeAlert: UIAlertController?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if
            let request,
            closeAlert != nil,
            presentedViewController == nil
        {
            resolve {
                request.cancel()
            }
            return
        }
        synchronizePresentation()
    }

    func update(request: TerminalCloseAlertRequest?) {
        self.request = request
        synchronizePresentation()
    }

    private func synchronizePresentation() {
        guard let request else {
            closeAlert?.dismiss(animated: true)
            closeAlert = nil
            return
        }
        guard isViewLoaded, view.window != nil else { return }
        guard closeAlert == nil, presentedViewController == nil else { return }

        let alert = TerminalCloseAlertFactory.make(
            message: request.message,
            onCancel: { [weak self] in
                self?.resolve {
                    request.cancel()
                }
            },
            onClose: { [weak self] in
                self?.resolve {
                    request.close()
                }
            }
        )
        closeAlert = alert
        present(alert, animated: true) { [weak self] in
            guard
                let focusSystem = UIFocusSystem.focusSystem(for: alert),
                let preferredEnvironment = alert.preferredFocusEnvironments.first
            else {
                self?.monitorSystemDismissal(of: alert)
                return
            }
            focusSystem.requestFocusUpdate(to: preferredEnvironment)
            focusSystem.updateFocusIfNeeded()
            self?.monitorSystemDismissal(of: alert)
        }
    }

    private func monitorSystemDismissal(of alert: UIAlertController) {
        Task { @MainActor [weak self, weak alert] in
            while !Task.isCancelled {
                guard
                    let self,
                    let alert,
                    closeAlert === alert,
                    let request
                else {
                    return
                }

                guard alert.viewIfLoaded?.window != nil else {
                    resolve {
                        request.cancel()
                    }
                    return
                }

                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func resolve(action: () -> Void) {
        guard request != nil else { return }
        self.request = nil
        closeAlert = nil
        action()
    }
}
#endif
