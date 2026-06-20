//
//  MacToolbarBridge.swift
//  VVTerm
//
//  The SwiftUI↔AppKit contract for the macOS connection toolbar: the payload
//  types the detail pane publishes (menu entries, view-picker data) and the
//  channel object that carries them to the AppKit toolbar controller. The
//  controller (see MacConnectionToolbarController) renders this with native
//  AppKit controls.
//

#if os(macOS)
import Combine
import SwiftUI

/// One entry in a toolbar pull-down menu (Files / Server).
struct ToolbarMenuEntry {
    var title: String
    var systemImage: String?
    var isEnabled: Bool = true
    var isDestructive: Bool = false
    var action: () -> Void = {}

    static let separator = ToolbarMenuEntry(title: "-", systemImage: nil, isEnabled: false, action: {})
    var isSeparator: Bool { title == "-" && systemImage == nil }
}

/// Data for the native segmented view picker.
struct ToolbarViewPickerData {
    struct Segment {
        let id: String
        let systemImage: String
        let help: String
    }
    var segments: [Segment]
    var selectedId: String
    var onSelect: (String) -> Void
}

/// Channel between the SwiftUI detail pane (owns content + actions) and the
/// AppKit toolbar. The detail pane publishes structured data; the toolbar
/// renders it with native controls.
final class MacToolbarBridge: ObservableObject {
    static let shared = MacToolbarBridge()
    private init() {}

    /// Bumped whenever hosted content (the tab strip) should re-render.
    @Published private(set) var revision: Int = 0

    private(set) var isActive = false
    private(set) var showsViewPicker = false
    private(set) var showsTabStrip = false
    private(set) var showsFilesMenu = false
    private(set) var isZenMode = false
    private(set) var zenTitle = ""
    private(set) var zenIcon = ""
    var zenSubtitle: () -> String = { "" }
    private var activeOwnerId: String?

    var viewPicker: () -> ToolbarViewPickerData? = { nil }
    var tabStrip: () -> AnyView = { AnyView(EmptyView()) }
    var filesMenu: () -> [ToolbarMenuEntry] = { [] }
    var serverMenu: () -> [ToolbarMenuEntry] = { [] }
    var onEnterZen: () -> Void = {}
    var zenPanelContent: () -> AnyView = { AnyView(EmptyView()) }
    /// App-level sidebar toggle is the system .toggleSidebar item (handled by
    /// the NSSplitViewController), so no closure is needed here.

    /// Set by the toolbar controller; invoked when the visible item set changes.
    var onItemSetChange: (() -> Void)?

    func activate(
        ownerId: String,
        showsViewPicker: Bool,
        showsTabStrip: Bool,
        showsFilesMenu: Bool,
        isZenMode: Bool,
        zenTitle: String,
        zenIcon: String,
        zenSubtitle: @escaping () -> String,
        viewPicker: @escaping () -> ToolbarViewPickerData?,
        tabStrip: @escaping () -> AnyView,
        filesMenu: @escaping () -> [ToolbarMenuEntry],
        serverMenu: @escaping () -> [ToolbarMenuEntry],
        onEnterZen: @escaping () -> Void,
        zenPanelContent: @escaping () -> AnyView
    ) {
        let setChanged = !isActive
            || self.showsViewPicker != showsViewPicker
            || self.showsTabStrip != showsTabStrip
            || self.showsFilesMenu != showsFilesMenu
            || self.isZenMode != isZenMode
            || activeOwnerId != ownerId
        activeOwnerId = ownerId
        isActive = true
        self.showsViewPicker = showsViewPicker
        self.showsTabStrip = showsTabStrip
        self.showsFilesMenu = showsFilesMenu
        self.isZenMode = isZenMode
        self.zenTitle = zenTitle
        self.zenIcon = zenIcon
        self.zenSubtitle = zenSubtitle
        self.viewPicker = viewPicker
        self.tabStrip = tabStrip
        self.filesMenu = filesMenu
        self.serverMenu = serverMenu
        self.onEnterZen = onEnterZen
        self.zenPanelContent = zenPanelContent
        revision &+= 1
        if setChanged { onItemSetChange?() }
    }

    func deactivate(ownerId: String) {
        guard isActive, activeOwnerId == ownerId else { return }
        isActive = false
        showsViewPicker = false
        showsTabStrip = false
        showsFilesMenu = false
        isZenMode = false
        zenTitle = ""
        zenIcon = ""
        zenSubtitle = { "" }
        activeOwnerId = nil
        viewPicker = { nil }
        tabStrip = { AnyView(EmptyView()) }
        filesMenu = { [] }
        serverMenu = { [] }
        zenPanelContent = { AnyView(EmptyView()) }
        revision &+= 1
        onItemSetChange?()
    }
}
#endif
