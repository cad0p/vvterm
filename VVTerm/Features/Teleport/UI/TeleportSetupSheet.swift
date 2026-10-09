// SPDX-License-Identifier: MIT
//
//  TeleportSetupSheet.swift
//  VVTerm
//
//  The shared Teleport setup sheet (issue #369): the single source of the
//  bootstrap → registration → login phase chain, plus the generic phase
//  wrappers that own each coordinator's `@StateObject`.
//
//  Production (`ServerSidebarView`, `ServerListScreen`) and the UI-test
//  harness (`TeleportPhaseChainUITestHarness`) all present this view, so the
//  routing switch exists once. `ServerFormSheet` keeps its own three-sheet
//  presentation model and adopts only the wrappers.
//
//  The chain rule itself lives in
//  `Features/Teleport/Application/TeleportPhaseChain.swift`; this file is
//  presentation only.
//
//  See:
//    - VVTerm/Features/Teleport/Application/TeleportPhaseChain.swift (the rule)
//    - VVTermTests/Features/Teleport/TeleportSetupSheetPinsTests.swift (the pin)
//

import SwiftUI
import TeleportCore
import TeleportAuth

/// The shared Teleport setup sheet. Renders the phase view selected by the
/// chain and dismisses via `onFinish` when a phase completes or is cancelled.
///
/// Generic over the three coordinator protocols so the live composition and
/// the UI-test mocks can both be injected without existentials.
struct TeleportSetupSheet<
    Bootstrap: TeleportBootstrapCoordinating,
    Registration: TeleportRegistrationCoordinating,
    Login: TeleportLoginCoordinating
>: View {
    let server: Server
    let initialReadiness: TeleportDeviceReadiness
    let reuseNotice: String?
    let makeBootstrapCoordinator: () -> Bootstrap
    let makeRegistrationCoordinator: () -> Registration
    let makeLoginCoordinator: () -> Login
    /// Persists the chosen host login. Production passes the server manager
    /// call; the UI-test harness passes a no-op.
    let persistHostLogin: @MainActor (String) async throws -> Void
    /// Called to dismiss the sheet on success or cancel.
    let onFinish: () -> Void

    @State private var chain: TeleportPhaseChain

    @MainActor
    init(
        server: Server,
        initialReadiness: TeleportDeviceReadiness,
        reuseNotice: String? = nil,
        makeBootstrapCoordinator: @escaping () -> Bootstrap,
        makeRegistrationCoordinator: @escaping () -> Registration,
        makeLoginCoordinator: @escaping () -> Login,
        persistHostLogin: @escaping @MainActor (String) async throws -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.server = server
        self.initialReadiness = initialReadiness
        self.reuseNotice = reuseNotice
        self.makeBootstrapCoordinator = makeBootstrapCoordinator
        self.makeRegistrationCoordinator = makeRegistrationCoordinator
        self.makeLoginCoordinator = makeLoginCoordinator
        self.persistHostLogin = persistHostLogin
        self.onFinish = onFinish
        _chain = State(initialValue: TeleportPhaseChain(readiness: initialReadiness))
    }

    var body: some View {
        let cluster = TeleportCluster(
            id: server.id,
            host: server.host,
            port: server.port,
            username: server.username
        )
        Group {
            switch chain.phase {
            case .bootstrap:
                TeleportBootstrapSheet(
                    makeCoordinator: makeBootstrapCoordinator,
                    cluster: cluster,
                    onSuccess: { result in
                        // Phase 1 → Phase 2: hold the result (TLS keypair) in
                        // memory and re-render the same sheet as registration.
                        // Do NOT dismiss — the user flows straight into Phase 2.
                        chain.bootstrapSucceeded(result)
                    },
                    onCancel: onFinish
                )
                .adaptiveSoftScrollEdges()
            case .registration(let bootstrapResult):
                TeleportRegistrationSheet(
                    makeCoordinator: makeRegistrationCoordinator,
                    cluster: cluster,
                    bootstrapResult: bootstrapResult,
                    onSuccess: {
                        // Phase 2 → Phase 3: the SEP key is registered but the
                        // live cert hasn't been issued yet.
                        chain.registrationSucceeded()
                    },
                    onCancel: onFinish
                )
                .adaptiveSoftScrollEdges()
            case .login:
                TeleportLoginSheet(
                    makeCoordinator: makeLoginCoordinator,
                    cluster: cluster,
                    storedHostLogin: server.teleportHostLogin,
                    persistHostLogin: persistHostLogin,
                    reuseNotice: reuseNotice,
                    onSuccess: { _ in
                        // Phase 3 complete — the live cert is issued and the
                        // host login is persisted. Dismiss.
                        chain.loginSucceeded()
                        onFinish()
                    },
                    onCancel: onFinish
                )
                .adaptiveSoftScrollEdges()
            case .ready:
                // Already complete (or just completed) — dismiss immediately.
                Color.clear
                    .frame(width: 0, height: 0)
                    .onAppear(perform: onFinish)
            }
        }
    }
}

// MARK: - Phase wrappers
//
// Each Teleport phase view (bootstrap / registration / login) observes its
// coordinator via `@ObservedObject`. The coordinator MUST be held in a
// `@StateObject`-backed wrapper so SwiftUI creates it once (when the sheet
// first appears) and preserves its identity across the PARENT view's body
// re-evaluations. Constructing the coordinator inline (the previous wiring)
// orphaned the coordinator that reached `.success` when the parent
// re-rendered during the async POST — the sheet's
// `.onChange(of: coordinator.state)` then observed a fresh `.idle`
// coordinator, so `onSuccess` never fired (the live-device "stuck on Waiting
// for Safari approval" bug).
//
// The wrappers are generic over their coordinator protocols so the live
// coordinators and the UI-test mocks share one implementation.

struct TeleportBootstrapSheet<Coordinator: TeleportBootstrapCoordinating>: View {
    let makeCoordinator: () -> Coordinator
    let cluster: TeleportCluster
    let onSuccess: (TeleportBootstrapCoordinator.BootstrapResult) -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator: Coordinator

    @MainActor
    init(
        makeCoordinator: @escaping () -> Coordinator,
        cluster: TeleportCluster,
        onSuccess: @escaping (TeleportBootstrapCoordinator.BootstrapResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.makeCoordinator = makeCoordinator
        self.cluster = cluster
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: makeCoordinator())
    }

    var body: some View {
        TeleportBootstrapView(
            coordinator: coordinator,
            cluster: cluster,
            onSuccess: onSuccess,
            onCancel: onCancel
        )
    }
}

struct TeleportRegistrationSheet<Coordinator: TeleportRegistrationCoordinating>: View {
    let makeCoordinator: () -> Coordinator
    let cluster: TeleportCluster
    let bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator: Coordinator

    @MainActor
    init(
        makeCoordinator: @escaping () -> Coordinator,
        cluster: TeleportCluster,
        bootstrapResult: TeleportBootstrapCoordinator.BootstrapResult,
        onSuccess: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.makeCoordinator = makeCoordinator
        self.cluster = cluster
        self.bootstrapResult = bootstrapResult
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: makeCoordinator())
    }

    var body: some View {
        TeleportRegistrationView(
            coordinator: coordinator,
            cluster: cluster,
            bootstrapResult: bootstrapResult,
            onSuccess: onSuccess,
            onCancel: onCancel
        )
    }
}

struct TeleportLoginSheet<Coordinator: TeleportLoginCoordinating>: View {
    let makeCoordinator: () -> Coordinator
    let cluster: TeleportCluster
    let storedHostLogin: String?
    /// Persists the chosen host login. Replaces the previous direct
    /// `serverManager` dependency so the wrapper is platform/model-agnostic.
    let persistHostLogin: @MainActor (String) async throws -> Void
    var reuseNotice: String? = nil
    let onSuccess: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator: Coordinator

    /// The last persist failure, shown as an alert while the sheet stays
    /// open so the user can retry (dismissing would silently lose the pick).
    @State private var persistErrorMessage: String?

    @MainActor
    init(
        makeCoordinator: @escaping () -> Coordinator,
        cluster: TeleportCluster,
        storedHostLogin: String?,
        persistHostLogin: @escaping @MainActor (String) async throws -> Void,
        reuseNotice: String? = nil,
        onSuccess: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.makeCoordinator = makeCoordinator
        self.cluster = cluster
        self.storedHostLogin = storedHostLogin
        self.persistHostLogin = persistHostLogin
        self.reuseNotice = reuseNotice
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: makeCoordinator())
    }

    var body: some View {
        TeleportLoginView(
            coordinator: coordinator,
            cluster: cluster,
            storedHostLogin: storedHostLogin,
            onSuccess: { login in
                Task { @MainActor in
                    do {
                        try await persistHostLogin(login)
                        onSuccess(login)
                    } catch {
                        persistErrorMessage = error.localizedDescription
                    }
                }
            },
            onCancel: onCancel,
            reuseNotice: reuseNotice
        )
        .alert(
            String(localized: "Couldn't Save the Host Login"),
            isPresented: Binding(
                get: { persistErrorMessage != nil },
                set: { if !$0 { persistErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) { persistErrorMessage = nil }
        } message: {
            Text(persistErrorMessage ?? "")
        }
    }
}
