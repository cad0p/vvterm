import Foundation

@MainActor
final class TmuxAttachResolver {
    var sessionNames: [UUID: String] = [:]
    var sessionOwnership: [UUID: TmuxSessionOwnership] = [:]
    private(set) var confirmedManagedSessions: Set<UUID> = []

    private(set) var currentPrompt: TmuxAttachPrompt?
    private var promptQueue: [TmuxAttachPrompt] = []
    private var promptContinuations: [UUID: CheckedContinuation<TmuxAttachSelection, Never>] = [:]

    // MARK: - Settings

    var tmuxEnabledDefault: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "terminalTmuxEnabledDefault") == nil {
            return true
        }
        return defaults.bool(forKey: "terminalTmuxEnabledDefault")
    }

    var tmuxStartupBehaviorDefault: TmuxStartupBehavior {
        let defaults = UserDefaults.standard
        guard let rawValue = defaults.string(forKey: "terminalTmuxStartupBehaviorDefault") else {
            return .askEveryTime
        }
        return TmuxStartupBehavior(rawValue: rawValue) ?? .askEveryTime
    }

    func isTmuxEnabled(for serverId: UUID) -> Bool {
        if let server = ServerManager.shared.servers.first(where: { $0.id == serverId }),
           let override = server.tmuxEnabledOverride {
            return override
        }
        return tmuxEnabledDefault
    }

    func tmuxStartupBehavior(for serverId: UUID) -> TmuxStartupBehavior {
        guard let server = ServerManager.shared.servers.first(where: { $0.id == serverId }) else {
            return tmuxStartupBehaviorDefault
        }
        if let override = server.tmuxStartupBehaviorOverride {
            return override
        }
        return tmuxStartupBehaviorDefault
    }

    // MARK: - Session Naming

    func managedSessionName(for entityId: UUID) -> String {
        "vvterm_\(DeviceIdentity.id)_\(entityId.uuidString)"
    }

    func sessionName(for entityId: UUID) -> String {
        sessionNames[entityId] ?? managedSessionName(for: entityId)
    }

    // MARK: - Attachment State

    func clearAttachmentState(for entityId: UUID) {
        sessionNames.removeValue(forKey: entityId)
        sessionOwnership.removeValue(forKey: entityId)
        confirmedManagedSessions.remove(entityId)
    }

    func confirmManagedSession(for entityId: UUID) {
        guard sessionOwnership[entityId] == .managed,
              sessionNames[entityId] != nil else { return }
        confirmedManagedSessions.insert(entityId)
    }

    func hasConfirmedManagedSession(for entityId: UUID) -> Bool {
        confirmedManagedSessions.contains(entityId)
    }

    func clearAllAttachmentState() {
        sessionNames.removeAll()
        sessionOwnership.removeAll()
        confirmedManagedSessions.removeAll()
    }

    func clearRuntimeState(for entityId: UUID, setPrompt: (TmuxAttachPrompt?) -> Void) {
        clearAttachmentState(for: entityId)
        if promptContinuations[entityId] != nil {
            resolvePrompt(entityId: entityId, selection: .skipTmux, setPrompt: setPrompt)
            return
        }
        if currentPrompt?.id == entityId {
            currentPrompt = nil
            advancePromptQueue(setPrompt: setPrompt)
        }
        promptQueue.removeAll { $0.id == entityId }
    }

    func updateAttachmentState(for entityId: UUID, selection: TmuxAttachSelection, setPrompt: (TmuxAttachPrompt?) -> Void) {
        switch selection {
        case .createManaged:
            let managedName = managedSessionName(for: entityId)
            if sessionNames[entityId] != managedName || sessionOwnership[entityId] != .managed {
                confirmedManagedSessions.remove(entityId)
            }
            sessionNames[entityId] = managedName
            sessionOwnership[entityId] = .managed
        case .attachExisting(let name):
            confirmedManagedSessions.remove(entityId)
            sessionNames[entityId] = name
            sessionOwnership[entityId] = ownership(for: name)
        case .skipTmux:
            clearRuntimeState(for: entityId, setPrompt: setPrompt)
        }
    }

    // MARK: - Selection Resolution

    func resolveSelection(
        for entityId: UUID,
        serverId: UUID,
        client: SSHClient,
        setPrompt: @escaping (TmuxAttachPrompt?) -> Void
    ) async -> TmuxAttachSelection {
        // On reconnect, reuse the previous session choice for this tab/pane
        if let existingName = sessionNames[entityId],
           let ownership = sessionOwnership[entityId] {
            switch ownership {
            case .managed:
                return .createManaged
            case .external:
                let sessions = await RemoteTmuxManager.shared.listSessions(using: client)
                if sessions.contains(where: { $0.name == existingName }) {
                    return .attachExisting(sessionName: existingName)
                }
                // Session no longer exists, fall through to normal resolution
                sessionNames.removeValue(forKey: entityId)
                sessionOwnership.removeValue(forKey: entityId)
            }
        }

        let behavior = tmuxStartupBehavior(for: serverId)

        switch behavior {
        case .vvtermManaged:
            return .createManaged
        case .skipTmux:
            return .skipTmux
        case .askEveryTime:
            let sessions = await RemoteTmuxManager.shared.listSessions(using: client)
            return await requestSelection(
                entityId: entityId,
                serverId: serverId,
                availableSessions: sessionInfosForPrompt(from: sessions),
                setPrompt: setPrompt
            )
        }
    }

    // MARK: - Prompt Queue

    func resolvePrompt(entityId: UUID, selection: TmuxAttachSelection, setPrompt: (TmuxAttachPrompt?) -> Void) {
        guard let continuation = promptContinuations.removeValue(forKey: entityId) else { return }

        if currentPrompt?.id == entityId {
            currentPrompt = nil
            advancePromptQueue(setPrompt: setPrompt)
            continuation.resume(returning: selection)
            return
        }

        promptQueue.removeAll { $0.id == entityId }
        continuation.resume(returning: selection)
    }

    func cancelPrompt(entityId: UUID, setPrompt: (TmuxAttachPrompt?) -> Void) {
        resolvePrompt(entityId: entityId, selection: .skipTmux, setPrompt: setPrompt)
    }

    // MARK: - Cleanup

    func runCleanupIfNeeded(
        serverId: UUID,
        cleanupSet: inout Set<UUID>,
        managedNames: Set<String>,
        using client: SSHClient
    ) async {
        guard !cleanupSet.contains(serverId) else { return }
        cleanupSet.insert(serverId)
        await RemoteTmuxManager.shared.cleanupLegacySessions(using: client)
        await RemoteTmuxManager.shared.cleanupDetachedSessions(
            deviceId: DeviceIdentity.id,
            keeping: managedNames,
            using: client
        )
    }

    // MARK: - Command Building

    func buildAttachCommand(
        for entityId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String? {
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            return RemoteTmuxManager.shared.attachCommand(
                sessionName: sessionName(for: entityId),
                workingDirectory: workingDirectory,
                context: .startupExec,
                backend: backend
            )
        case .attachExisting(let name):
            return RemoteTmuxManager.shared.attachExistingCommand(
                sessionName: name,
                context: .startupExec,
                backend: backend
            )
        }
    }

    func buildAttachExecCommand(
        for entityId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String? {
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            return RemoteTmuxManager.shared.attachExecCommand(
                sessionName: sessionName(for: entityId),
                workingDirectory: workingDirectory,
                backend: backend
            )
        case .attachExisting(let name):
            return RemoteTmuxManager.shared.attachExistingExecCommand(sessionName: name, backend: backend)
        }
    }

    // MARK: - Filtering

    func sessionInfosForPrompt(from sessions: [RemoteTmuxSession]) -> [TmuxAttachSessionInfo] {
        let filtered = sessions.filter { !isInternalSessionName($0.name) || $0.attachedClients > 0 }
        let source = filtered.isEmpty ? sessions : filtered
        return source.map {
            TmuxAttachSessionInfo(
                name: $0.name,
                attachedClients: max(0, $0.attachedClients),
                windowCount: max(1, $0.windowCount)
            )
        }
    }

    func isInternalSessionName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasPrefix("vvterm_")
            || lowercased.hasPrefix("vvterm-")
            || lowercased.hasPrefix("vivyterm_")
            || lowercased.hasPrefix("vivyterm-")
    }

    func isCurrentDeviceManagedSessionName(_ name: String) -> Bool {
        name.hasPrefix("vvterm_\(DeviceIdentity.id)_")
    }

    // MARK: - Private

    private func requestSelection(
        entityId: UUID,
        serverId: UUID,
        availableSessions: [TmuxAttachSessionInfo],
        setPrompt: @escaping (TmuxAttachPrompt?) -> Void
    ) async -> TmuxAttachSelection {
        let serverName = ServerManager.shared.servers.first(where: { $0.id == serverId })?.name ?? String(localized: "Server")
        let prompt = TmuxAttachPrompt(
            id: entityId,
            serverId: serverId,
            serverName: serverName,
            existingSessions: availableSessions
        )

        return await withCheckedContinuation { continuation in
            enqueuePrompt(prompt, continuation: continuation, setPrompt: setPrompt)
        }
    }

    private func enqueuePrompt(
        _ prompt: TmuxAttachPrompt,
        continuation: CheckedContinuation<TmuxAttachSelection, Never>,
        setPrompt: (TmuxAttachPrompt?) -> Void
    ) {
        promptContinuations[prompt.id] = continuation
        if currentPrompt == nil {
            currentPrompt = prompt
            setPrompt(prompt)
        } else {
            promptQueue.append(prompt)
        }
    }

    private func advancePromptQueue(setPrompt: (TmuxAttachPrompt?) -> Void) {
        guard currentPrompt == nil, !promptQueue.isEmpty else {
            setPrompt(currentPrompt)
            return
        }
        currentPrompt = promptQueue.removeFirst()
        setPrompt(currentPrompt)
    }

    private func ownership(for sessionName: String) -> TmuxSessionOwnership {
        isCurrentDeviceManagedSessionName(sessionName) ? .managed : .external
    }
}
