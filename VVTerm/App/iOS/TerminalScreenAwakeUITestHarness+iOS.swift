#if os(iOS) && DEBUG
import SwiftUI
import UIKit

struct TerminalScreenAwakeUITestHarness: View {
    private static let routeID = UUID(uuidString: "B166D8E5-E32E-44B8-BB0D-91145D4F7200")!

    /// Fault modes for issue #389 (the scoped `:92` lost-tap fix under #264),
    /// parsed from the launch arguments once per process:
    ///
    /// * `--vvterm-ui-test-screen-awake-drop-toggle-writes N` (separated or
    ///   `=N`) makes the harness swallow the first `N` Keep Screen Awake
    ///   writes, with the production row's own identifier, so the measured
    ///   signature — "the tap synthesized, the preference never flipped" —
    ///   reproduces deterministically.
    /// * `--vvterm-ui-test-screen-awake-skip-idle-sync N` lets the preference
    ///   write land but skips the harness's `.onChange(of:
    ///   keepScreenAwakeEnabled)` `updateRequest` for the first `N` changes:
    ///   the preference flips, the idle timer does not. This is the fold
    ///   round 1 hazard the preference-only early return masked (a preference
    ///   at target reported success without the idle half).
    ///
    /// Any active mode resets `terminalKeepScreenAwake` to
    /// `TerminalDefaults.defaultKeepScreenAwake` at process start for the
    /// deterministic counterfactual start state. Absent in the CI path (the
    /// args are only passed by the counterfactual runs).
    ///
    /// A `static let` (not `init`) because SwiftUI can rebuild the root view
    /// value when `VVTermApp`'s `@StateObject`s publish: a `static let` runs at
    /// most once per process, so the fixture reset below and the drop/skip
    /// counts cannot be re-applied mid-test. The reset is required because a
    /// previous run may have left the preference flipped; the
    /// `-terminalKeepScreenAwake YES` launch-arg form is NOT usable — measured:
    /// `NSArgumentDomain` shadows writes, so `UserDefaults.standard.set(false,
    /// …)` still reads back `true`.
    private struct FaultConfig {
        let writesToDrop: Int
        let idleSyncsToSkip: Int

        var isActive: Bool {
            writesToDrop > 0 || idleSyncsToSkip > 0
        }
    }

    private static let fault: FaultConfig = {
        let arguments = Foundation.ProcessInfo.processInfo.arguments
        let config = FaultConfig(
            writesToDrop: faultCount(
                for: "--vvterm-ui-test-screen-awake-drop-toggle-writes",
                in: arguments
            ),
            idleSyncsToSkip: faultCount(
                for: "--vvterm-ui-test-screen-awake-skip-idle-sync",
                in: arguments
            )
        )
        if config.isActive {
            UserDefaults.standard.set(
                TerminalDefaults.defaultKeepScreenAwake,
                forKey: TerminalDefaults.keepScreenAwakeKey
            )
        }
        return config
    }()

    @EnvironmentObject private var screenAwakeCoordinator: TerminalScreenAwakeCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(TerminalDefaults.keepScreenAwakeKey) private var keepScreenAwakeEnabled = TerminalDefaults.defaultKeepScreenAwake
    @State private var idleTimerDisabled = false
    @State private var backgroundReleaseObserved = false
    /// The fault-mode writes still to drop (0 in the normal path). Seeded from
    /// the once-per-process static; SwiftUI keeps the first `@State` value
    /// across root-view rebuilds.
    @State private var remainingDroppedWrites = TerminalScreenAwakeUITestHarness.fault.writesToDrop
    /// The fault-mode preference changes still to skip the coordinator update
    /// for (0 in the normal path); the preference write itself always lands.
    @State private var remainingIdleSyncsToSkip = TerminalScreenAwakeUITestHarness.fault.idleSyncsToSkip

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if TerminalScreenAwakeUITestHarness.fault.writesToDrop > 0 {
                        // The fault-only row: same label + identifier as the
                        // production `TerminalScreenAwakeSettingRow`, but the
                        // setter drops the first N writes instead of writing.
                        // The getter reads the harness's `@AppStorage` the same
                        // way the production row does.
                        Toggle("Keep screen awake", isOn: faultToggleBinding)
                            .accessibilityIdentifier("vvterm.settings.terminal.keepScreenAwake")
                    } else {
                        TerminalScreenAwakeSettingRow()
                    }
                } header: {
                    Text("Terminal Behavior")
                }
            }
            .navigationTitle("Terminal")
        }
        .overlay(alignment: .bottomLeading) {
            Text(diagnostics)
                .font(.system(size: 10, design: .monospaced))
                .padding(6)
                .background(.black.opacity(0.8))
                .foregroundStyle(.white)
                .allowsHitTesting(false)
                .accessibilityIdentifier("vvterm.screenAwakeTest.diagnostics")
        }
        .onAppear {
            updateRequest(for: scenePhase)
        }
        .onChange(of: keepScreenAwakeEnabled) { _ in
            // Skip-idle-sync fault (fold round 1): the preference write landed,
            // but the toggle→coordinator update is skipped for the first N
            // changes, so the idle timer does not follow.
            guard remainingIdleSyncsToSkip == 0 else {
                remainingIdleSyncsToSkip -= 1
                return
            }
            updateRequest(for: scenePhase)
        }
        .onChange(of: scenePhase) { phase in
            updateRequest(for: phase)
        }
        .onDisappear {
            screenAwakeCoordinator.update(isRequested: false, for: Self.routeID)
        }
    }

    /// The fault-mode binding: drops the first `remainingDroppedWrites` changes
    /// (no write, no `onChange`, no animation) and writes normally afterwards.
    /// A write-then-revert in `onChange` was rejected: it leaves a live
    /// transient value and a second write, so the red counterfactual could race
    /// green.
    private var faultToggleBinding: Binding<Bool> {
        Binding(
            get: { keepScreenAwakeEnabled },
            set: { newValue in
                guard remainingDroppedWrites == 0 else {
                    remainingDroppedWrites -= 1
                    return
                }
                keepScreenAwakeEnabled = newValue
            }
        )
    }

    private var diagnostics: String {
        "preference=\(keepScreenAwakeEnabled) idleTimerDisabled=\(idleTimerDisabled) backgroundReleased=\(backgroundReleaseObserved)"
    }

    private func updateRequest(for phase: ScenePhase) {
        let sceneIsInBackground = sceneIsInBackground(phase)
        let isRequested = TerminalScreenAwakeCoordinator.shouldRequest(
            preferenceEnabled: keepScreenAwakeEnabled,
            routeVisible: true,
            terminalSelected: true,
            sceneIsInBackground: sceneIsInBackground
        )
        screenAwakeCoordinator.update(isRequested: isRequested, for: Self.routeID)

        let currentValue = UIApplication.shared.isIdleTimerDisabled
        if sceneIsInBackground {
            backgroundReleaseObserved = !currentValue
        }
        idleTimerDisabled = currentValue
    }

    private func sceneIsInBackground(_ phase: ScenePhase) -> Bool {
        switch phase {
        case .active, .inactive:
            false
        case .background:
            true
        @unknown default:
            true
        }
    }

    /// Parses a fault-count arg (`--flag N` separated or `--flag=N`) for the
    /// screen-awake harness. Returns 0 (the normal path) when absent or
    /// unparsable.
    private static func faultCount(for flag: String, in arguments: [String]) -> Int {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == flag, arguments.index(after: index) < arguments.endIndex {
                return max(0, Int(arguments[arguments.index(after: index)]) ?? 0)
            }
            if argument.hasPrefix(flag + "=") {
                return max(0, Int(argument.dropFirst(flag.count + 1)) ?? 0)
            }
            index = arguments.index(after: index)
        }
        return 0
    }
}
#endif
