//
//  NavigationBarAppearanceConfigurator.swift
//  VVTerm
//

#if os(iOS)
import SwiftUI
import UIKit

struct NavigationBarAppearanceConfigurator: UIViewControllerRepresentable {
    let backgroundColor: UIColor
    var isTranslucent: Bool = false
    var shadowColor: UIColor? = nil
    var onDisappearBackgroundColor: UIColor? = nil
    var onDisappearIsTranslucent: Bool? = nil
    var onDisappearShadowColor: UIColor? = nil

    func makeUIViewController(context: Context) -> AppearanceController {
        AppearanceController()
    }

    func updateUIViewController(_ uiViewController: AppearanceController, context: Context) {
        uiViewController.updateConfig(
            backgroundColor: backgroundColor,
            isTranslucent: isTranslucent,
            shadowColor: shadowColor,
            onDisappearBackgroundColor: onDisappearBackgroundColor,
            onDisappearIsTranslucent: onDisappearIsTranslucent,
            onDisappearShadowColor: onDisappearShadowColor
        )
        uiViewController.applyAppearance()
    }
}

final class AppearanceController: UIViewController {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    private struct AppearanceConfig: Equatable {
        let backgroundColor: UIColor
        let isTranslucent: Bool
        let shadowColor: UIColor?

        static func == (lhs: AppearanceConfig, rhs: AppearanceConfig) -> Bool {
            lhs.isTranslucent == rhs.isTranslucent &&
            lhs.backgroundColor.isEqual(rhs.backgroundColor) &&
            ((lhs.shadowColor == nil && rhs.shadowColor == nil) ||
             (lhs.shadowColor?.isEqual(rhs.shadowColor) == true))
        }
    }

    private var backgroundColor: UIColor = .clear
    private var isTranslucent: Bool = false
    private var shadowColor: UIColor? = nil
    private var onDisappearBackgroundColor: UIColor? = nil
    private var onDisappearIsTranslucent: Bool? = nil
    private var onDisappearShadowColor: UIColor? = nil
    private var lastAppliedConfig: AppearanceConfig?
    private var lastAppliedNavigationBarID: ObjectIdentifier?

    func updateConfig(
        backgroundColor: UIColor,
        isTranslucent: Bool,
        shadowColor: UIColor?,
        onDisappearBackgroundColor: UIColor?,
        onDisappearIsTranslucent: Bool?,
        onDisappearShadowColor: UIColor?
    ) {
        self.backgroundColor = backgroundColor
        self.isTranslucent = isTranslucent
        self.shadowColor = shadowColor
        self.onDisappearBackgroundColor = onDisappearBackgroundColor
        self.onDisappearIsTranslucent = onDisappearIsTranslucent
        self.onDisappearShadowColor = onDisappearShadowColor
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppearance()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let bg = onDisappearBackgroundColor else { return }
        applyAppearance(
            backgroundColor: bg,
            isTranslucent: onDisappearIsTranslucent ?? isTranslucent,
            shadowColor: onDisappearShadowColor ?? shadowColor,
            disableAnimation: true
        )
    }

    func applyAppearance() {
        applyAppearance(
            backgroundColor: backgroundColor,
            isTranslucent: isTranslucent,
            shadowColor: shadowColor,
            disableAnimation: true
        )
    }

    private func applyAppearance(
        backgroundColor: UIColor,
        isTranslucent: Bool,
        shadowColor: UIColor?,
        disableAnimation: Bool
    ) {
        guard let navBar = navigationController?.navigationBar else { return }
        let config = AppearanceConfig(
            backgroundColor: backgroundColor,
            isTranslucent: isTranslucent,
            shadowColor: shadowColor
        )
        let navigationBarID = ObjectIdentifier(navBar)

        guard lastAppliedConfig != config || lastAppliedNavigationBarID != navigationBarID else {
            return
        }

        let applyBlock = {
            let appearance = UINavigationBarAppearance()
            if isTranslucent {
                appearance.configureWithTransparentBackground()
            } else {
                appearance.configureWithOpaqueBackground()
            }
            appearance.backgroundColor = backgroundColor
            appearance.shadowColor = shadowColor

            navBar.standardAppearance = appearance
            navBar.scrollEdgeAppearance = appearance
            navBar.compactAppearance = appearance
            navBar.isTranslucent = isTranslucent
            navBar.layer.removeAllAnimations()
            navBar.setNeedsLayout()
        }

        if disableAnimation {
            UIView.performWithoutAnimation {
                applyBlock()
            }
        } else {
            applyBlock()
        }

        lastAppliedConfig = config
        lastAppliedNavigationBarID = navigationBarID
    }
}

extension View {
    func navigationBarAppearance(
        backgroundColor: UIColor,
        isTranslucent: Bool = false,
        shadowColor: UIColor? = nil,
        onDisappearBackgroundColor: UIColor? = nil,
        onDisappearIsTranslucent: Bool? = nil,
        onDisappearShadowColor: UIColor? = nil
    ) -> some View {
        background(
            NavigationBarAppearanceConfigurator(
                backgroundColor: backgroundColor,
                isTranslucent: isTranslucent,
                shadowColor: shadowColor,
                onDisappearBackgroundColor: onDisappearBackgroundColor,
                onDisappearIsTranslucent: onDisappearIsTranslucent,
                onDisappearShadowColor: onDisappearShadowColor
            )
        )
    }
}
#endif
