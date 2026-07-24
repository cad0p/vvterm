import SwiftUI

// MARK: - Server Row

struct ServerRow: View {
    let server: Server
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: (Server) -> Void
    var onMove: ((Server) -> Void)? = nil
    var onConnect: ((Server) -> Void)? = nil
    var onLockedTap: (() -> Void)? = nil
    /// Called when a non-ready Teleport server is tapped. The caller opens
    /// the appropriate setup sheet (bootstrap/registration/login) based on
    /// the readiness state. If nil, the tap falls through to `onSelect`.
    var onTeleportSetup: ((Server, TeleportDeviceReadiness) -> Void)? = nil

    @ObservedObject private var tabManager = TerminalTabManager.shared
    @ObservedObject private var serverManager = ServerManager.shared
    @ObservedObject private var keyRing = TeleportKeyRing.shared
    @Environment(\.privacyModeEnabled) private var privacyModeEnabled
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    private var isLocked: Bool {
        serverManager.isServerLocked(server)
    }

    /// The derived Teleport readiness for this server. Only computed for
    /// Teleport servers (`.faceIDTeleport`); non-Teleport servers return nil
    /// and the existing tab-count badge is unchanged.
    private var teleportReadiness: TeleportDeviceReadiness? {
        guard server.authMethod == .faceIDTeleport else { return nil }
        return keyRing.readiness(for: server.id)
    }

    /// Whether this Teleport server needs setup (any non-ready state).
    private var needsTeleportSetup: Bool {
        teleportReadiness?.needsSetup == true
    }

    private var tabCount: Int {
        tabManager.tabs(for: server.id).count
    }

    private var selectedForegroundColor: Color {
        #if os(macOS)
        controlActiveState == .key ? .accentColor : .accentColor.opacity(0.78)
        #else
        .accentColor
        #endif
    }

    private var selectionFillColor: Color {
        #if os(macOS)
        let base = NSColor.unemphasizedSelectedContentBackgroundColor
        let alpha: Double = controlActiveState == .key ? 0.26 : 0.18
        return Color(nsColor: base).opacity(alpha)
        #else
        return Color.primary.opacity(0.10)
        #endif
    }

    private var sessionIndicatorColor: Color {
        isSelected ? selectedForegroundColor.opacity(0.9) : .secondary
    }

    var body: some View {
        serverLabel
            .background(selectionBackground)
            .opacity(isLocked ? 0.7 : 1.0)
            .contentShape(Rectangle())
            .onTapGesture {
                if isLocked {
                    onLockedTap?()
                } else if needsTeleportSetup, let readiness = teleportReadiness, let onTeleportSetup {
                    onTeleportSetup(server, readiness)
                } else {
                    onSelect()
                }
            }
            .contextMenu {
                if isLocked {
                    Button {
                        onLockedTap?()
                    } label: {
                        Label("Unlock with Pro", systemImage: "lock.open.fill")
                    }
                    if let onMove {
                        Button { onMove(server) } label: {
                            Label("Move to Workspace", systemImage: "arrow.turn.right.up")
                        }
                    }
                    Button { onEdit(server) } label: {
                        Label("Server Settings", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) {
                        Task { try? await ServerManager.shared.deleteServer(server) }
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                    }
                } else {
                    Button {
                        if let onConnect {
                            onConnect(server)
                        } else {
                            tabManager.selectedViewByServer[server.id] = ViewTabConfigurationManager.shared.effectiveDefaultTab()
                            tabManager.connectedServerIds.insert(server.id)
                        }
                    } label: {
                        Label("Open Connection", systemImage: "point.forward.to.point.capsulepath.fill")
                    }
                    if let onMove {
                        Button { onMove(server) } label: {
                            Label("Move to Workspace", systemImage: "arrow.turn.right.up")
                        }
                    }
                    Button { onEdit(server) } label: {
                        Label("Server Settings", systemImage: "slider.horizontal.3")
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task { try? await ServerManager.shared.deleteServer(server) }
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                    }
                }
            }
    }

    private var serverLabel: some View {
        HStack(alignment: .center, spacing: 12) {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "server.rack")
                    .foregroundStyle(isSelected ? selectedForegroundColor : .secondary)
                    .imageScale(.medium)
                    .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body)
                    .foregroundStyle(isSelected ? selectedForegroundColor : Color.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(server.visibleHost(privacyModeEnabled: privacyModeEnabled))
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Circle()
                        .fill(server.environment.color)
                        .frame(width: 6, height: 6)

                    Text(server.environment.displayShortName)
                        .font(.caption2)
                        .foregroundStyle(server.environment.color)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isLocked {
                LockedBadge()
            } else if needsTeleportSetup, let readiness = teleportReadiness {
                readinessBadge(readiness)
            } else if tabCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(tabCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(sessionIndicatorColor)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(selectionFillColor)
        }
    }

    // MARK: - Teleport Readiness Badge

    /// The readiness pill for non-ready Teleport servers (design doc mockup B).
    ///   - `needsBootstrap` / `needsRegistration` → amber "Setup" pill
    ///     (`lock.rotation` icon)
    ///   - `needsLogin` → blue "Sign in" pill
    ///   - `ready` → no badge (the caller doesn't call this for ready state)
    @ViewBuilder
    private func readinessBadge(_ readiness: TeleportDeviceReadiness) -> some View {
        switch readiness {
        case .ready:
            // Ready Teleport servers behave like normal SSH servers — show
            // the tab count (or nothing if no tabs).
            if tabCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(tabCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(sessionIndicatorColor)
            }
        case .needsBootstrap, .needsRegistration:
            PillBadge(text: String(localized: "Setup"), color: .orange)
        case .needsLogin:
            PillBadge(text: String(localized: "Sign in"), color: .blue)
        }
    }
}

// MARK: - Pill Badge

struct PillBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Search Field

struct SearchField<Trailing: View>: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var spacing: CGFloat = 8
    var iconSize: CGFloat = 14
    var iconWeight: Font.Weight? = nil
    var iconColor: Color = .secondary
    var textFont: Font = .system(size: 14)
    var clearButtonSize: CGFloat = 12
    var clearButtonWeight: Font.Weight? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: spacing) {
            if let weight = iconWeight {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: iconSize, weight: weight))
                    .foregroundStyle(iconColor)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: iconSize))
                    .foregroundStyle(iconColor)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(textFont)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: clearButtonSize, weight: clearButtonWeight ?? .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            trailing()
        }
    }
}

extension SearchField where Trailing == EmptyView {
    init(placeholder: LocalizedStringKey, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
        self.spacing = 8
        self.iconSize = 14
        self.iconWeight = nil
        self.iconColor = .secondary
        self.textFont = .system(size: 14)
        self.clearButtonSize = 12
        self.clearButtonWeight = nil
        self.trailing = { EmptyView() }
    }
}
