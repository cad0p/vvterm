//
//  MacShellCommandBridge.swift
//  VVTerm
//
//  Carries the active connection's keyboard-command actions (tab + split) from
//  the hosted detail pane up to ContentView, which republishes them via
//  `focusedSceneValue` so the menu commands can reach them. SwiftUI
//  `@FocusedValue` set inside the hosted detail pane does not cross the
//  NSHostingController boundary to the scene's `Commands`, so this bridge stands
//  in for that propagation.
//

#if os(macOS)
import Combine
import Foundation

final class MacShellCommandBridge: ObservableObject {
    init() {}

    @Published private(set) var revision: Int = 0
    private(set) var serverViewTabActions: ServerViewTabActions?
    private(set) var splitActions: TerminalSplitActions?
    private(set) var activeServerId: UUID?
    private(set) var activePaneId: UUID?
    private var ownerId: String?

    /// The sidebar lives in its own NSHostingController, so its `.focusedValue`
    /// for local-device discovery never reaches the scene `Commands`. The
    /// sidebar registers the action here and ContentView republishes it.
    @Published var openLocalDiscovery: (() -> Void)?

    func update(
        ownerId: String,
        serverViewTabActions: ServerViewTabActions?,
        splitActions: TerminalSplitActions?,
        activeServerId: UUID?,
        activePaneId: UUID?
    ) {
        self.ownerId = ownerId
        self.serverViewTabActions = serverViewTabActions
        self.splitActions = splitActions
        self.activeServerId = activeServerId
        self.activePaneId = activePaneId
        revision &+= 1
    }

    func clear(ownerId: String) {
        guard self.ownerId == ownerId else { return }
        self.ownerId = nil
        serverViewTabActions = nil
        splitActions = nil
        activeServerId = nil
        activePaneId = nil
        revision &+= 1
    }
}
#endif
