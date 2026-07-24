import SwiftUI

struct ProcessesSheet: View {
    let processes: [ProcessInfo]
    let processCount: Int
    let terminateProcess: ((ProcessInfo) async throws -> Void)?
    let loadProcesses: (() async throws -> [ProcessInfo])?

    @State private var loadedProcesses: [ProcessInfo] = []
    @State private var searchText = ""
    @State private var sortOption: ProcessSortOption = .cpu
    @State private var filterOption: ProcessFilterOption = .all
    @State private var isLoadingProcesses = false
    @State private var selectedProcess: ProcessInfo?
    @State private var pendingKill: ProcessInfo?
    @State private var killingPID: Int?
    @State private var errorMessage = ""
    @State private var showingError = false

    var body: some View {
        sheetContent
            .confirmationDialog(
                String(localized: "Kill Process?"),
                isPresented: Binding(
                    get: { pendingKill != nil },
                    set: { if !$0 { pendingKill = nil } }
                ),
                presenting: pendingKill
            ) { process in
                Button(String(localized: "Kill"), role: .destructive) {
                    Task {
                        await kill(process)
                    }
                }
            } message: { process in
                Text(String(format: String(localized: "Send SIGTERM to %@ (PID %lld)."), process.name, Int64(process.pid)))
            }
            .alert(String(localized: "Could Not Kill Process"), isPresented: $showingError) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .statsDetailPresentation(item: $selectedProcess) { process in
                ProcessDetailsSheet(process: process)
            }
            .onAppear {
                if loadedProcesses.isEmpty {
                    loadedProcesses = processes
                }
                Task {
                    await loadFullProcessesIfNeeded()
                }
            }
            .onChange(of: processes.map(\.pid)) { _ in
                guard !isLoadingProcesses else { return }
                loadedProcesses = processes
            }
            .adaptiveSoftScrollEdges()
    }

    @ViewBuilder
    private var sheetContent: some View {
        #if os(macOS)
        StatsDetailShell(
            String(localized: "Processes"),
            systemImage: "list.bullet.rectangle",
            tint: .purple
        ) {
            processControlsMenu
        } content: {
            VStack(spacing: 0) {
                StatsSearchField(prompt: String(localized: "Search Processes"), text: $searchText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
                processList
            }
        }
        #else
        NavigationStack {
            processList
            .navigationTitle(Text("Processes"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text("Search Processes"))
            .toolbar {
                ToolbarItem(placement: controlsPlacement) {
                    processControlsMenu
                }
            }
            .statsSheetCloseToolbar()
        }
        #endif
    }

    private var processList: some View {
        List {
            Section(footer: ProcessListFooter(
                visibleCount: visibleProcesses.count,
                totalCount: loadedProcesses.count,
                processCount: processCount,
                isFiltered: isFiltered
            )) {
                if isLoadingProcesses {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Loading processes"))
                            .foregroundStyle(.secondary)
                    }
                }

                if visibleProcesses.isEmpty, !isLoadingProcesses {
                    EmptyProcessListRow(isFiltered: isFiltered)
                }

                ForEach(visibleProcesses) { process in
                    Button {
                        selectedProcess = process
                    } label: {
                        ProcessSheetRow(
                            process: process,
                            isKilling: killingPID == process.pid
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if terminateProcess != nil {
                            Button(role: .destructive) {
                                pendingKill = process
                            } label: {
                                Label(String(localized: "Kill"), systemImage: "xmark.octagon")
                            }
                            .disabled(killingPID == process.pid)
                        }
                    }
                }
            }
        }
    }

    private var processControlsMenu: some View {
        Menu {
            Picker(String(localized: "Sort By"), selection: $sortOption) {
                ForEach(ProcessSortOption.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option)
                }
            }

            Picker(String(localized: "Filter"), selection: $filterOption) {
                ForEach(ProcessFilterOption.allCases) { option in
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

    private var visibleProcesses: [ProcessInfo] {
        let query = normalizedSearchText
        var result = loadedProcesses.filter { process in
            filterOption.includes(process)
        }

        if !query.isEmpty {
            result = result.filter { process in
                process.matches(query)
            }
        }

        return result.sorted { lhs, rhs in
            sortOption.areInIncreasingOrder(lhs, rhs)
        }
    }

    private func loadFullProcessesIfNeeded() async {
        guard let loadProcesses else { return }

        isLoadingProcesses = true
        defer { isLoadingProcesses = false }

        do {
            let loadedProcesses = try await loadProcesses()
            if !loadedProcesses.isEmpty {
                self.loadedProcesses = loadedProcesses
            }
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func kill(_ process: ProcessInfo) async {
        guard let terminateProcess else { return }

        pendingKill = nil
        killingPID = process.pid
        defer { killingPID = nil }

        do {
            try await terminateProcess(process)
            loadedProcesses.removeAll { $0.pid == process.pid }
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

private enum ProcessSortOption: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case name
    case pid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:
            return String(localized: "CPU")
        case .memory:
            return String(localized: "Memory")
        case .name:
            return String(localized: "Name")
        case .pid:
            return String(localized: "PID")
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
        case .pid:
            return "number"
        }
    }

    func areInIncreasingOrder(_ lhs: ProcessInfo, _ rhs: ProcessInfo) -> Bool {
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
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison == .orderedSame {
                return lhs.pid < rhs.pid
            }
            return comparison == .orderedAscending
        case .pid:
            return lhs.pid < rhs.pid
        }
    }
}

private enum ProcessFilterOption: String, CaseIterable, Identifiable {
    case all
    case active
    case highCPU
    case highMemory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return String(localized: "All")
        case .active:
            return String(localized: "Active")
        case .highCPU:
            return String(localized: "High CPU")
        case .highMemory:
            return String(localized: "High Memory")
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "line.3.horizontal"
        case .active:
            return "waveform.path.ecg"
        case .highCPU:
            return "cpu"
        case .highMemory:
            return "memorychip"
        }
    }

    func includes(_ process: ProcessInfo) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return process.cpuPercent > 0 || process.memoryPercent > 0
        case .highCPU:
            return process.cpuPercent >= 10
        case .highMemory:
            return process.memoryPercent >= 5
        }
    }
}

private struct ProcessListFooter: View {
    let visibleCount: Int
    let totalCount: Int
    let processCount: Int
    let isFiltered: Bool

    var body: some View {
        if isFiltered {
            Text(String(
                format: String(localized: "%lld of %lld processes"),
                Int64(visibleCount),
                Int64(max(totalCount, processCount))
            ))
        } else if processCount > totalCount {
            Text(String(
                format: String(localized: "%lld shown, %lld total"),
                Int64(totalCount),
                Int64(processCount)
            ))
        }
    }
}

private struct ProcessSheetRow: View {
    let process: ProcessInfo
    let isKilling: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(process.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(String(format: String(localized: "PID %lld"), Int64(process.pid)))
                    if !process.user.isEmpty {
                        Text(process.user)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                if !process.command.isEmpty, process.command != process.name {
                    Text(process.command)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                ProcessSheetMetric(
                    title: String(localized: "CPU"),
                    value: process.cpuPercent,
                    color: .pink
                )
                ProcessSheetMetric(
                    title: String(localized: "MEM"),
                    value: process.memoryPercent,
                    color: .blue
                )
            }
            .overlay(alignment: .trailing) {
                if isKilling {
                    ProgressView()
                        .controlSize(.small)
                        .padding(6)
                        .background(.regularMaterial, in: Circle())
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct ProcessDetailsSheet: View {
    let process: ProcessInfo

    var body: some View {
        sheetContent
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
            .adaptiveSoftScrollEdges()
    }

    @ViewBuilder
    private var sheetContent: some View {
        #if os(macOS)
        StatsDetailShell(
            String(localized: "Process Details"),
            systemImage: "list.bullet.rectangle",
            tint: .purple
        ) {
            processDetailsList
        }
        #else
        NavigationStack {
            processDetailsList
            .navigationTitle(Text("Process Details"))
            .navigationBarTitleDisplayMode(.inline)
            .statsSheetCloseToolbar()
        }
        #endif
    }

    private var processDetailsList: some View {
        List {
            Section(String(localized: "Overview")) {
                InfoRow(title: String(localized: "Name"), value: process.name)
                InfoRow(title: String(localized: "PID"), value: "\(process.pid)")
                if !process.user.isEmpty {
                    InfoRow(title: String(localized: "User"), value: process.user)
                }
            }

            Section(String(localized: "Usage")) {
                InfoRow(title: String(localized: "CPU"), value: formatPercent(process.cpuPercent))
                InfoRow(title: String(localized: "Memory"), value: formatPercent(process.memoryPercent))
            }

            Section(String(localized: "Command")) {
                Text(process.command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
            }
        }
    }
}

private struct EmptyProcessListRow: View {
    let isFiltered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isFiltered ? String(localized: "No Matching Processes") : String(localized: "No Processes"))
                .font(.headline)
            Text(isFiltered ? String(localized: "Try a different search or filter.") : String(localized: "No processes were reported by the remote host."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private extension ProcessInfo {
    func matches(_ query: String) -> Bool {
        let fields = [
            name,
            command,
            user,
            "\(pid)"
        ]

        return fields.contains { field in
            field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
