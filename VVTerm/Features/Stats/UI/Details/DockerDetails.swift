import SwiftUI

struct DockerDetailsSheet: View {
    let loadDockerStats: (() async throws -> DockerStats)?
    let performDockerAction: ((DockerContainerAction, DockerContainer) async throws -> DockerStats)?

    @State private var docker: DockerStats
    @State private var searchText = ""
    @State private var sortOption: DockerContainerSortOption = .cpu
    @State private var filterOption: DockerContainerFilterOption = .all
    @State private var isLoading = false
    @State private var selectedContainer: DockerContainer?
    @State private var errorMessage = ""
    @State private var showingError = false

    init(
        docker: DockerStats,
        loadDockerStats: (() async throws -> DockerStats)?,
        performDockerAction: ((DockerContainerAction, DockerContainer) async throws -> DockerStats)?
    ) {
        self.loadDockerStats = loadDockerStats
        self.performDockerAction = performDockerAction
        _docker = State(initialValue: docker)
    }

    var body: some View {
        sheetContent
            .alert(String(localized: "Could Not Load Containers"), isPresented: $showingError) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .statsDetailPresentation(item: $selectedContainer) { container in
                DockerContainerDetailsSheet(
                    container: container,
                    performAction: performDockerAction
                ) { updatedDocker in
                    docker = updatedDocker
                }
            }
            .task {
                await refresh()
            }
            .adaptiveSoftScrollEdges()
    }

    @ViewBuilder
    private var sheetContent: some View {
        #if os(macOS)
        StatsDetailShell(
            String(localized: "Docker"),
            systemImage: "shippingbox",
            tint: .blue
        ) {
            dockerControlsMenu
        } content: {
            VStack(spacing: 0) {
                StatsSearchField(prompt: String(localized: "Search Containers"), text: $searchText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
                dockerList
            }
        }
        #else
        NavigationStack {
            dockerList
            .navigationTitle(Text("Docker"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text("Search Containers"))
            .toolbar {
                ToolbarItem(placement: controlsPlacement) {
                    dockerControlsMenu
                }
            }
            .statsSheetCloseToolbar()
        }
        #endif
    }

    private var dockerList: some View {
        List {
            Section {
                DockerSummaryRows(docker: docker)
            }

            if !docker.isAvailable {
                Section {
                    Text(docker.availability.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section(footer: DockerContainerListFooter(
                visibleCount: visibleContainers.count,
                totalCount: docker.containers.count,
                isFiltered: isFiltered
            )) {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Loading containers"))
                            .foregroundStyle(.secondary)
                    }
                }

                if visibleContainers.isEmpty, !isLoading {
                    EmptyDockerContainerRow(isFiltered: isFiltered, isAvailable: docker.isAvailable)
                }

                ForEach(visibleContainers) { container in
                    Button {
                        selectedContainer = container
                    } label: {
                        DockerContainerSheetRow(container: container)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var dockerControlsMenu: some View {
        Menu {
            Picker(String(localized: "Sort By"), selection: $sortOption) {
                ForEach(DockerContainerSortOption.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option)
                }
            }

            Picker(String(localized: "Filter"), selection: $filterOption) {
                ForEach(DockerContainerFilterOption.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 16, weight: .semibold))
        }
        .accessibilityLabel(Text("Sort and Filter"))
    }

    private var controlsPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .automatic
        #endif
    }

    private var isFiltered: Bool {
        !normalizedSearchText.isEmpty || filterOption != .all
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleContainers: [DockerContainer] {
        let query = normalizedSearchText
        var result = docker.containers.filter { filterOption.includes($0) }

        if !query.isEmpty {
            result = result.filter { container in
                container.matches(query)
            }
        }

        return result.sorted { lhs, rhs in
            sortOption.areInIncreasingOrder(lhs, rhs)
        }
    }

    private func refresh() async {
        guard let loadDockerStats else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            docker = try await loadDockerStats()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

private enum DockerContainerSortOption: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case name
    case state

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:
            return String(localized: "CPU")
        case .memory:
            return String(localized: "Memory")
        case .name:
            return String(localized: "Name")
        case .state:
            return String(localized: "State")
        }
    }

    var systemImage: String {
        switch self {
        case .cpu:
            return "cpu"
        case .memory:
            return "memorychip"
        case .name:
            return "textformat"
        case .state:
            return "circle.dotted"
        }
    }

    func areInIncreasingOrder(_ lhs: DockerContainer, _ rhs: DockerContainer) -> Bool {
        switch self {
        case .cpu:
            if lhs.cpuPercent == rhs.cpuPercent {
                return lhs.memoryPercent > rhs.memoryPercent
            }
            return lhs.cpuPercent > rhs.cpuPercent
        case .memory:
            if lhs.memoryPercent == rhs.memoryPercent {
                return lhs.cpuPercent > rhs.cpuPercent
            }
            return lhs.memoryPercent > rhs.memoryPercent
        case .name:
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        case .state:
            if lhs.state == rhs.state {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return dockerStateTitle(lhs.state).localizedCaseInsensitiveCompare(dockerStateTitle(rhs.state)) == .orderedAscending
        }
    }
}

private enum DockerContainerFilterOption: String, CaseIterable, Identifiable {
    case all
    case running
    case unhealthy
    case stopped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return String(localized: "All")
        case .running:
            return String(localized: "Running")
        case .unhealthy:
            return String(localized: "Unhealthy")
        case .stopped:
            return String(localized: "Stopped")
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "line.3.horizontal"
        case .running:
            return "play.circle"
        case .unhealthy:
            return "exclamationmark.triangle"
        case .stopped:
            return "stop.circle"
        }
    }

    func includes(_ container: DockerContainer) -> Bool {
        switch self {
        case .all:
            return true
        case .running:
            return container.isRunning
        case .unhealthy:
            return container.health == .unhealthy
        case .stopped:
            return !container.isRunning
        }
    }
}

private struct DockerSummaryRows: View {
    let docker: DockerStats

    var body: some View {
        InfoRow(title: String(localized: "Status"), value: dockerSummaryStatus)
        InfoRow(title: String(localized: "Running"), value: "\(docker.runningCount)")
        InfoRow(title: String(localized: "Stopped"), value: "\(docker.stoppedCount)")
        InfoRow(title: String(localized: "Unhealthy"), value: "\(docker.unhealthyCount)")
        InfoRow(title: String(localized: "CPU"), value: formatPercent(docker.aggregateCPUPercent))
        InfoRow(title: String(localized: "Memory"), value: formatUsedCapacity(docker.memoryUsed, total: docker.memoryLimit))
        InfoRow(title: String(localized: "Received"), value: formatBytes(docker.networkRx))
        InfoRow(title: String(localized: "Sent"), value: formatBytes(docker.networkTx))
    }

    private var dockerSummaryStatus: String {
        docker.isAvailable ? String(localized: "Available") : docker.availability.message
    }
}

private struct DockerContainerSheetRow: View {
    let container: DockerContainer

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(dockerStatusColor(container))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(container.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(dockerStateTitle(container.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                ProcessSheetMetric(title: String(localized: "CPU"), value: container.cpuPercent, color: .pink)
                ProcessSheetMetric(title: String(localized: "MEM"), value: container.memoryPercent, color: .blue)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct DockerContainerDetailsSheet: View {
    let performAction: ((DockerContainerAction, DockerContainer) async throws -> DockerStats)?
    let onDockerUpdated: (DockerStats) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var container: DockerContainer
    @State private var activeAction: DockerContainerAction?
    @State private var actionTask: Task<Void, Never>?
    @State private var errorMessage = ""
    @State private var showingError = false

    init(
        container: DockerContainer,
        performAction: ((DockerContainerAction, DockerContainer) async throws -> DockerStats)?,
        onDockerUpdated: @escaping (DockerStats) -> Void
    ) {
        self.performAction = performAction
        self.onDockerUpdated = onDockerUpdated
        _container = State(initialValue: container)
    }

    var body: some View {
        sheetContent
            .alert(String(localized: "Could Not Update Container"), isPresented: $showingError) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
            .onDisappear {
                actionTask?.cancel()
                actionTask = nil
                activeAction = nil
            }
            .adaptiveSoftScrollEdges()
    }

    @ViewBuilder
    private var sheetContent: some View {
        #if os(macOS)
        StatsDetailShell(
            String(localized: "Container Details"),
            systemImage: "shippingbox",
            tint: .blue
        ) {
            containerDetailsList
        }
        #else
        NavigationStack {
            containerDetailsList
            .navigationTitle(Text("Container Details"))
            .navigationBarTitleDisplayMode(.inline)
            .statsSheetCloseToolbar()
        }
        #endif
    }

    private var containerDetailsList: some View {
        List {
            Section(String(localized: "Overview")) {
                InfoRow(title: String(localized: "Name"), value: container.displayName)
                InfoRow(title: String(localized: "Container ID"), value: container.shortID)
                InfoRow(title: String(localized: "Image"), value: container.image)
                InfoRow(title: String(localized: "State"), value: dockerStateTitle(container.state))
                InfoRow(title: String(localized: "Health"), value: dockerHealthTitle(container.health))
                InfoRow(title: String(localized: "Status"), value: container.status)
                InfoRow(title: String(localized: "Running For"), value: container.runningFor)
            }

            if performAction != nil {
                Section(String(localized: "Actions")) {
                    ForEach(availableActions, id: \.self) { action in
                        Button(role: dockerActionRole(action)) {
                            run(action)
                        } label: {
                            HStack {
                                Label(dockerActionTitle(action), systemImage: dockerActionSystemImage(action))
                                Spacer()
                                if activeAction == action {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(activeAction != nil)
                    }
                }
            }

            Section(String(localized: "Usage")) {
                InfoRow(title: String(localized: "CPU"), value: formatPercent(container.cpuPercent))
                InfoRow(title: String(localized: "Memory"), value: formatDockerMemory(container))
                InfoRow(title: String(localized: "PIDs"), value: optionalInteger(container.pids))
            }

            Section(String(localized: "Network")) {
                InfoRow(title: String(localized: "Received"), value: optionalBytes(container.networkRx))
                InfoRow(title: String(localized: "Sent"), value: optionalBytes(container.networkTx))
            }

            Section(String(localized: "Storage")) {
                InfoRow(title: String(localized: "Read"), value: optionalBytes(container.blockRead))
                InfoRow(title: String(localized: "Write"), value: optionalBytes(container.blockWrite))
            }

            if !container.ports.isEmpty {
                Section(String(localized: "Ports")) {
                    Text(container.ports)
                        .textSelection(.enabled)
                }
            }

            if !container.command.isEmpty {
                Section(String(localized: "Command")) {
                    Text(container.command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                }
            }
        }
    }

    private var availableActions: [DockerContainerAction] {
        if container.isRunning {
            return [.restart, .stop]
        }
        return [.start]
    }

    private func run(_ action: DockerContainerAction) {
        guard let performAction else { return }
        guard activeAction == nil, actionTask == nil else { return }
        activeAction = action
        let currentContainer = container
        actionTask = Task { @MainActor in
            defer {
                actionTask = nil
                activeAction = nil
            }
            do {
                let updatedDocker = try await performAction(action, currentContainer)
                guard !Task.isCancelled else { return }
                onDockerUpdated(updatedDocker)
                if let updatedContainer = updatedDocker.container(matching: currentContainer) {
                    container = updatedContainer
                } else {
                    dismiss()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func optionalBytes(_ value: UInt64?) -> String {
        guard let value else { return String(localized: "No live data") }
        return formatBytes(value)
    }

    private func optionalInteger(_ value: Int?) -> String {
        guard let value else { return String(localized: "No live data") }
        return "\(value)"
    }

    private func formatDockerMemory(_ container: DockerContainer) -> String {
        guard let used = container.memoryUsed else { return String(localized: "No live data") }
        return formatUsedCapacity(used, total: container.memoryLimit ?? 0)
    }
}

private struct DockerContainerListFooter: View {
    let visibleCount: Int
    let totalCount: Int
    let isFiltered: Bool

    var body: some View {
        if isFiltered {
            Text(String(
                format: String(localized: "%lld of %lld containers"),
                Int64(visibleCount),
                Int64(totalCount)
            ))
        }
    }
}

private struct EmptyDockerContainerRow: View {
    let isFiltered: Bool
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var title: String {
        if isFiltered {
            return String(localized: "No Matching Containers")
        }
        return isAvailable ? String(localized: "No Containers") : String(localized: "Docker Unavailable")
    }

    private var message: String {
        if isFiltered {
            return String(localized: "Try a different search or filter.")
        }
        return isAvailable
            ? String(localized: "No containers were reported by Docker.")
            : String(localized: "Docker metrics are unavailable on this server.")
    }
}

private extension DockerContainer {
    func matches(_ query: String) -> Bool {
        let fields = [
            id,
            name,
            image,
            command,
            status,
            ports,
            dockerStateTitle(state),
            dockerHealthTitle(health)
        ]

        return fields.contains { field in
            field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func hasSameIdentity(as other: DockerContainer) -> Bool {
        let ownKeys = Set([id, shortID, name].map { $0.lowercased() }.filter { !$0.isEmpty })
        let otherKeys = Set([other.id, other.shortID, other.name].map { $0.lowercased() }.filter { !$0.isEmpty })
        return !ownKeys.isDisjoint(with: otherKeys)
    }
}

private extension DockerStats {
    func container(matching container: DockerContainer) -> DockerContainer? {
        containers.first { $0.hasSameIdentity(as: container) }
    }
}

func dockerStatusColor(_ container: DockerContainer) -> Color {
    if container.health == .unhealthy {
        return .red
    }
    switch container.state {
    case .running:
        return .green
    case .restarting:
        return .orange
    case .paused:
        return .yellow
    case .exited, .dead, .removing:
        return .secondary
    case .created, .unknown:
        return .blue
    }
}

func dockerStateTitle(_ state: DockerContainerState) -> String {
    switch state {
    case .running:
        return String(localized: "Running")
    case .exited:
        return String(localized: "Exited")
    case .paused:
        return String(localized: "Paused")
    case .restarting:
        return String(localized: "Restarting")
    case .created:
        return String(localized: "Created")
    case .dead:
        return String(localized: "Dead")
    case .removing:
        return String(localized: "Removing")
    case .unknown:
        return String(localized: "Unknown")
    }
}

func dockerHealthTitle(_ health: DockerHealthStatus) -> String {
    switch health {
    case .healthy:
        return String(localized: "Healthy")
    case .unhealthy:
        return String(localized: "Unhealthy")
    case .starting:
        return String(localized: "Starting")
    case .none:
        return ""
    }
}

func dockerActionTitle(_ action: DockerContainerAction) -> String {
    switch action {
    case .start:
        return String(localized: "Start Container")
    case .stop:
        return String(localized: "Stop Container")
    case .restart:
        return String(localized: "Restart Container")
    }
}

func dockerActionSystemImage(_ action: DockerContainerAction) -> String {
    switch action {
    case .start:
        return "play.fill"
    case .stop:
        return "stop.fill"
    case .restart:
        return "arrow.clockwise"
    }
}

func dockerActionRole(_ action: DockerContainerAction) -> ButtonRole? {
    action == .stop ? .destructive : nil
}
