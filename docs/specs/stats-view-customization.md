# Stats View Customization (Spec)

## Summary
Add first-class appearance and layout preferences for the per-server Stats view, on-demand system hardware details for the connected remote host, and first-class GPU telemetry for AI/compute servers. The Stats view should support multiple built-in visual styles, starting with:
- `Classic`: the original dense Stats presentation.
- `Cards Compact`: the default Apple-native card/dashboard presentation with smaller cards and less information per block.
- `Cards Detailed`: the larger Apple-native card/dashboard presentation with richer per-block information.

The first implementation should make visual style selection, reordering, and hiding built-in Stats blocks available to all users. The architecture should keep iOS and macOS visually aligned while allowing responsive layout differences.

## Problem
The current Stats view is moving from the original presentation to a more Apple-native card style. That creates two product needs:
- Some users may prefer the original dense view.
- Power users may want to personalize which metrics are visible and in what order.

Hard-coding one Stats screen makes each redesign risky and makes customization expensive later. The Stats view needs a small preference and rendering architecture before more visual styles are added.

## Goals (V1)
- Support a built-in Stats style picker with `Cards Compact`, `Cards Detailed`, and `Classic`.
- Default to `Cards Compact` when no preference exists.
- Keep the same preference on iOS and macOS.
- Keep Stats collection/data parsing independent from visual style.
- Add system hardware details to Stats data so the UI can show CPU, GPU, host, OS, and machine information on demand.
- Add best-effort live GPU telemetry for AI/compute hosts:
  - GPU utilization
  - GPU memory/VRAM used and total
  - temperature
  - power draw and power limit when available
  - graphics/memory clocks when available
  - active GPU compute processes when vendor tooling exposes them
- Add a Settings entry for Stats appearance under the existing `Server Views` area.
- Define a block model that supports reorder/hide behavior and can support future add behavior.
- Let users reorder and hide built-in Stats blocks from Settings.
- Persist preferences locally.
- Sync preferences through CloudKit when iCloud sync is enabled.

## Non-Goals (V1)
- User-authored chart colors or arbitrary visual theme editing.
- Per-server or per-workspace Stats layouts.
- Different Stats layouts for iOS and macOS.
- New non-GPU live metric families beyond the existing collected `ServerStats` data.
- GPU management actions such as reset, power-limit changes, clock locking, ECC reset, MIG changes, or persistence-mode changes.
- Privileged telemetry that would require interactive `sudo` prompts.
- Kubernetes, Slurm, or container-level GPU allocation accounting in V1.
- Guaranteed per-process GPU attribution across all vendors and platforms.
- Changing server view visibility/order ownership in `ViewTabConfigurationManager`.
- Paywalling basic Stats visibility or the ability to use the Stats view.

## Product Decisions
- Built-in style switching is free.
- `Cards Compact` is the default for existing users and fresh installs.
- `Cards Detailed` preserves the richer, larger card direction currently being explored.
- `Classic` remains available as the original fallback style.
- Built-in block reorder/hide is available in V1.
- Future paid customization can add extra block types, saved presets, or additional visual styles without changing the V1 preference model.

## User Stories
- As a user, I can choose whether Stats uses the classic or card-based layout.
- As a user, I can choose a compact card layout when I want a smaller dashboard with less information on screen.
- As a user, I can choose a detailed card layout when I want larger cards with richer metric context.
- As a user, I can switch the style in Settings without reconnecting.
- As a user, I can hide Stats blocks I do not use.
- As a user, I can reorder Stats blocks.
- As a user, I can open the System card details and see what remote CPU/GPU/OS hardware I am connected to.
- As a user connected to an AI or GPU compute host, I can see whether GPUs are busy, how much VRAM is used, and whether power/temperature looks constrained.
- As a user connected to a multi-GPU machine, I can compare individual GPU load without typing vendor CLI commands.
- As a multi-device user, my Stats appearance follows me across iPhone, iPad, and Mac.
- As a user, I can still use all built-in Stats data, switch between built-in styles, and tune built-in block visibility.

## UX Design

### Settings Entry Point
Use the existing `GeneralSettingsView` server view area:
- `General` -> `Server Views`
- Add row: `Stats Appearance`
- Destination: `AppearanceSettings`

The current `Server Views` section continues to own:
- Stats/Terminal/Files visibility
- server view order
- default server view

Stats appearance settings only own the Stats screen presentation.

### Stats Appearance Screen
Use a grouped `Form` on both platforms.

Sections:
1. Untitled first section
   - Menu/dropdown picker labeled `Presentation`:
     - `Cards Compact`
     - `Cards Detailed`
     - `Classic`
   - Do not show explanatory text under the picker.
2. `Layout`
   - Shows the active block list in order.
   - Users can hide or show blocks with toggles.
   - Users can reorder blocks with the platform-native edit/move control.
   - At least one block must remain visible.
   - Do not show a reset button in V1.
3. `Preview`
   - A live mock preview is shown after all controls so users can judge the appearance before connecting to a server.
   - The preview must render the same Stats block components as the server Stats screen, using representative fake `ServerStats` and history data.
   - The preview must not wrap the Stats cards in an additional card-like preview container or padded black preview background.
   - The preview should sit directly in the grouped form row under the section title `Preview`.
   - The preview should use native grouped Settings surfaces and adaptive label colors, while the real Stats dashboard may use its own full-screen dashboard surface.
   - The preview must follow the current style, block visibility, and block order.

### Runtime Stats View
`ServerStatsView` should select a layout from preferences:
- `ClassicLayout`
- `CompactLayout`
- `DetailedLayout`

All layouts receive the same data:
- current `ServerStats`
- CPU history
- memory history
- GPU history
- network RX history
- network TX history
- collection state
- connection error state

The block order and visibility applies to all styles and to the mock preview. A style may render the same block differently, but it must respect whether the block is visible and its relative order.

### Card Style Density
Cards Compact is the default because the first card exploration is visually useful but too large for repeated monitoring.

Cards Compact:
- Targets smaller cards and more content above the fold.
- Uses reduced vertical padding and shorter charts.
- Shows one headline metric and one supporting line per block by default.
- Moves secondary values into detail sheets.
- Avoids large per-block tables/lists inside the card.

Cards Detailed:
- Keeps the larger, richer dashboard treatment.
- Shows additional footer values and short per-item previews inside cards.
- Uses larger charts when the data benefits from it.
- Is intended for users who prefer presentation depth over density.
- Must expose additional information compared with Compact, not only larger padding or spacing.
- Examples: CPU user/system/iowait/idle breakdown, memory used/free/cached/buffer values, more volume/process rows, and per-GPU preview rows.

Implementation rule:
- Do not fork data collection for compact versus detailed cards.
- Use shared block view models and style-specific presentation/layout constants.
- Compact and detailed must stay visually related; they are density variants, not unrelated designs.
- Compact and detailed must be semantically distinct: Compact is a scan surface, Detailed is a richer monitoring surface.

Initial sizing guidance:
- Compact card corner radius: match detailed cards.
- Compact card padding: about 14-16 pt.
- Detailed card padding: about 20-24 pt.
- Compact metric chart height: about 72-96 pt.
- Detailed metric chart height: about 118-150 pt.
- On iPhone, Compact should aim to show at least two metric cards plus part of the next card after the system area when real data is present.

### CPU Block
The `cpu` block should support drill-down when aggregate or per-core data is available.

Cards Compact style:
- Header: `CPU` with trailing logical core count when known.
- Primary value: aggregate CPU usage.
- Secondary value: one compact breakdown line, for example `User 31% - System 11% - Idle 58%`.
- Preview chart: aggregate CPU usage history.

Cards Detailed style:
- Includes everything from Compact.
- Adds visible breakdown values for user, system, I/O wait, and idle.
- Should show a chevron affordance because more CPU detail is available in a sheet.

Interaction:
- Tapping the CPU block opens `CPUDetailsView`.
- `CPUDetailsView` shows aggregate CPU usage, user/system/iowait/steal/idle, load average, processor identity, physical/logical core counts, and per-core samples when a collector provides them.

Collector rules:
- Linux collectors should parse all `/proc/stat` `cpu*` rows in the existing stats batch and calculate per-core percentages from previous samples.
- Unsupported platforms can leave per-core samples empty and still show aggregate CPU details.
- Missing per-core samples must not be a connection error.

### GPU Block
The `gpu` block should be a default visible block when GPU telemetry or GPU identity is available.

Cards Compact style:
- Prioritize scanability and height reduction.
- Use smaller card padding, smaller preview charts, and fewer footer values.
- Show at most the headline value plus one secondary context line per block.
- Prefer drill-down sheets for details rather than showing every detail in the card.

Cards Detailed style:
- Header: `GPU` with trailing count, for example `4 GPUs`.
- Primary value: busiest GPU utilization, for example `83%`.
- Secondary value: aggregate VRAM used/total, for example `67.2 GB of 192 GB`.
- Preview chart: compact utilization line for the busiest GPU, with optional memory line when space allows.
- Per-GPU rows:
  - GPU name or short identifier
  - utilization percent
  - VRAM used/total
  - temperature
  - power draw
  - small progress bar for utilization or memory pressure

Classic style:
- Same data, denser presentation, no large card-only affordances.

Interaction:
- Tapping the GPU block opens `GPUDetailsView`.
- `GPUDetailsView` shows one section per GPU with:
  - utilization
  - memory/VRAM used, total, and percent
  - temperature
  - power draw and power limit
  - clocks
  - PCI bus/device identifier when available
  - driver/runtime
  - active compute processes when available

Rules:
- If no GPU identity or telemetry exists, omit the GPU block from the runtime Stats screen even if it exists in the stored block order.
- If GPU identity exists but live telemetry is unavailable, show the GPU block as informational with `Metrics unavailable`.
- If telemetry has partial values, show only fields that are present.
- Never show a connection error solely because GPU telemetry collection failed.
- Mark stale GPU telemetry if the last successful GPU sample is older than 3 polling intervals.

### System Details
The required `system` block should include an info affordance:
- Cards styles: an `info.circle` button in the System/Summary card header.
- Classic style: an equivalent detail button in the system area.

Tapping the affordance opens `SystemDetailsView`:
- iOS: sheet with `NavigationStack` and grouped form sections.
- macOS: sheet or popover, depending on surrounding presentation.

Sections:
1. `Host`
   - hostname
   - operating system
   - kernel/version string
   - architecture
   - uptime
2. `Processor`
   - CPU brand/model
   - CPU vendor when available
   - logical cores
   - physical cores when available
3. `Graphics`
   - one row per detected GPU
   - GPU name/model
   - vendor when available
   - memory/VRAM when available
   - driver/runtime info when available
4. `Memory`
   - total memory
   - used/free/cached values from the latest sample

Rules:
- Do not show unknown or empty fields.
- If no GPU is reported, show `No GPU reported` instead of failing the sheet.
- Hardware details are informational and are not part of paid customization.
- Hardware details must not be synced to CloudKit and must not be included in analytics.

### Process Details and Control
The `processes` block is a summary card, not a full table.

Interaction:
- Tapping the process block opens a sheet.
- The sheet shows all collected processes in a platform-native list.
- Rows show process name, PID, user when available, command when available, CPU percent, and memory percent.
- Rows include a destructive kill affordance with a confirmation dialog.
- Unix-like hosts use `kill -TERM <pid>` for V1.
- Windows hosts use `taskkill /PID <pid> /T /F` for V1.

Rules:
- Do not allow termination for PID `0` or `1`.
- Process termination requires an active SSH client and should refresh stats after the command completes.
- Termination errors must be shown in the sheet without dismissing it.
- The process summary card should use a chevron to make the sheet affordance visible.

### Storage Collection Rules
Storage collection must work on ordinary Linux hosts, Ubuntu servers, and containerized/root-on-overlay environments.

Rules:
- Do not drop the first real `df` data row after already removing the header.
- Do not exclude `overlay` globally; otherwise containerized Ubuntu roots can produce an empty storage card.
- Exclude volatile pseudo-filesystems such as `tmpfs`, `devtmpfs`, and `squashfs`.
- Parse `df` output with explicit units when possible and keep the parser tolerant of header/no-header variants.

### Default Block Layout
Default ordered blocks:
1. `system`
2. `cpu`
3. `memory`
4. `gpu`
5. `network`
6. `storage`
7. `processes`

Required block:
- `system`

Optional blocks:
- `cpu`
- `memory`
- `gpu`
- `network`
- `storage`
- `processes`

If all optional blocks are hidden, the screen still shows `system`.

The system details sheet is attached to `system`; it is not a separate top-level block in V1.

## Technical Design

### Ownership
All Stats-specific models, stores, collectors, and views belong under `Features/Stats`.

Settings should only provide the navigation entry point and host the screen:
- no Stats preference rules in `Features/Settings`
- no Stats rendering logic in `Features/Settings`

CloudKit sync plumbing belongs in `Core/Sync`, matching existing preference sync patterns.

### Naming Rules
Inside `Features/Stats`, names should be concise and feature-local:
- Do not repeat `Stats` in every type and file name.
- Keep explicit names only at public boundaries, for example `ServerStatsView`, `ServerStats`, and `StatsCollector`.
- Prefer capability names over implementation names: `GPUBlock`, `CompactLayout`, `NvidiaSMI`.
- Avoid density/style prefixes on every block. Use shared blocks with a density/style value instead.
- Put implementation-specific names in folders rather than type prefixes.

Recommended feature tree:

```text
VVTerm/Features/Stats/
  Domain/
    ServerStats.swift
    HardwareProfile.swift
    GPU.swift
    Preferences.swift

  Application/
    StatsCollector.swift
    PreferencesStore.swift
    HistoryStore.swift

  Infrastructure/
    PlatformCollector.swift
    Platforms/
      DarwinCollector.swift
      LinuxCollector.swift
      WindowsCollector.swift
      FreeBSDCollector.swift
      OpenBSDCollector.swift
      NetBSDCollector.swift
    Probes/
      NvidiaSMI.swift
      AmdSMI.swift
      AmdGpuSysfs.swift
      IntelGpuTop.swift
      PowerMetrics.swift
      WindowsCounters.swift

  UI/
    ServerStatsView.swift
    AppearanceSettings.swift
    Layouts/
      CompactLayout.swift
      DetailedLayout.swift
      ClassicLayout.swift
    Blocks/
      SummaryBlock.swift
      MetricBlocks.swift
      GPUBlock.swift
      StorageBlock.swift
      ProcessBlock.swift
    Components/
      Cards.swift
      Charts.swift
      Meters.swift
      Rows.swift
      DetailSheets.swift
```

### Domain Model
Create:
- `VVTerm/Features/Stats/Domain/Preferences.swift`

Types:

```swift
struct StatsPreferences: Codable, Equatable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case cardsCompact
        case cardsDetailed
        case classic
    }

    enum BlockID: String, Codable, CaseIterable, Identifiable {
        case system
        case cpu
        case memory
        case gpu
        case network
        case storage
        case processes
    }

    struct Block: Identifiable, Codable, Equatable {
        var id: BlockID
        var isVisible: Bool
        var updatedAt: Date
    }

    var schemaVersion: Int
    var style: Style
    var blocks: [Block]
    var updatedAt: Date
    var lastWriterDeviceId: String
}
```

Avoid these longer names in implementation:
- `StatsViewPreferences`
- `StatsViewStyle`
- `StatsBlockID`
- `StatsBlockConfiguration`

Use nested names instead:
- `StatsPreferences`
- `StatsPreferences.Style`
- `StatsPreferences.BlockID`
- `StatsPreferences.Block`

Static constants:
- `schemaVersion = 1`
- `recordType = "UserPreference"`
- `recordName = "statsPreferences.v1"`
- `defaultsKey = CloudKitSyncConstants.statsPreferencesStorageKey`
- `defaultStyle = .cardsCompact`
- `defaultBlocks = [.system, .cpu, .memory, .gpu, .network, .storage, .processes]`
- `requiredBlocks = [.system]`

### Stats Data Model
Extend:
- `VVTerm/Features/Stats/Domain/ServerStats.swift`
- `VVTerm/Features/Stats/Domain/HardwareProfile.swift`
- `VVTerm/Features/Stats/Domain/GPU.swift`

Add stable system identity and hardware details:

```swift
struct HardwareProfile: Equatable {
    var hostname: String
    var osName: String
    var osVersion: String
    var kernelVersion: String
    var architecture: String
    var machineModel: String
    var cpuBrand: String
    var cpuVendor: String
    var physicalCpuCores: Int
    var logicalCpuCores: Int
    var virtualization: String
    var gpus: [GPUDevice]
}

struct CPUCoreSample: Identifiable, Equatable {
    var id: String
    var displayName: String
    var usagePercent: Double
    var userPercent: Double
    var systemPercent: Double
    var iowaitPercent: Double
    var stealPercent: Double
    var idlePercent: Double
}

struct GPUDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var vendor: String
    var pciBusID: String
    var modelIdentifier: String
    var memoryBytes: UInt64?
    var driverVersion: String
    var runtimeVersion: String
    var kind: GPUKind
}

enum GPUKind: String, Equatable {
    case integrated
    case discrete
    case virtual
    case unknown
}

struct GPUSample: Identifiable, Equatable {
    var id: String
    var gpuID: String
    var name: String
    var utilizationPercent: Double?
    var memoryUtilizationPercent: Double?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64?
    var temperatureCelsius: Double?
    var powerDrawWatts: Double?
    var powerLimitWatts: Double?
    var graphicsClockMHz: Double?
    var memoryClockMHz: Double?
    var encoderUtilizationPercent: Double?
    var decoderUtilizationPercent: Double?
    var performanceState: String
    var throttleReason: String
    var activeProcesses: [GPUProcess]
    var source: GPUSource
    var timestamp: Date
}

struct GPUProcess: Identifiable, Equatable {
    var id: String
    var pid: Int
    var name: String
    var gpuID: String
    var usedMemoryBytes: UInt64?
    var utilizationPercent: Double?
}

enum GPUSource: String, Equatable {
    case nvidiaSMI
    case amdSMI
    case rocmSMI
    case amdgpuSysfs
    case intelGpuTop
    case windowsPerformanceCounters
    case powermetrics
    case unavailable
}
```

`ServerStats` should keep current lightweight fields for existing callers, but also expose:

```swift
var hardware: HardwareProfile = .empty
var gpuSamples: [GPUSample] = []
```

Compatibility rule:
- `hostname`, `osInfo`, and `cpuCores` remain available during the migration.
- `cpuCores` should map to `hardware.logicalCpuCores` once collectors are updated.
- UI should prefer `hardware` when available and fall back to legacy fields.
- `gpuSamples` is live sample data and must be treated as transient, not synced preferences.
- `GPUDevice.id` and `GPUSample.gpuID` should be stable across samples within one connection.

### Collector Requirements
Hardware identity and GPU identity are required Stats data, but stable identity should not be collected on every polling interval. Live GPU telemetry is sampled with normal Stats polling, but collectors may throttle expensive GPU probes.

Change the collection architecture so each platform collector can provide stable identity separately from live metrics:

```swift
protocol PlatformCollector: Sendable {
    func collectProfile(client: SSHClient) async throws -> HardwareProfile
    func collectStats(client: SSHClient, context: CollectionContext) async throws -> ServerStats
}
```

`StatsCollector` responsibilities:
- Collect `HardwareProfile` once after platform detection or connection start.
- Cache the result for the lifetime of the stats collection session.
- Merge cached hardware into every published `ServerStats`.
- Refresh hardware only on explicit reconnect or manual refresh.
- If hardware collection partially fails, keep available fields and continue live stats collection.
- Never block live stat refresh because GPU probing failed.
- Sample GPU telemetry during `collectStats`, but allow per-platform throttling through `CollectionContext`.
- Preserve the last good GPU sample briefly so the UI does not flicker when one vendor command fails.
- Publish a telemetry source and timestamp per GPU so the UI can show stale/unavailable states.

GPU telemetry sampling cadence:
- Default: same cadence as Stats collection when the command is cheap.
- Expensive commands: throttle to every 5-10 seconds.
- Commands that can block or prompt for privileges must have a short timeout and be disabled for the current session after repeated failures.

Platform collection guidance:
- Linux:
  - CPU: `/proc/cpuinfo`, `lscpu` when available, `uname -m`.
  - OS: `/etc/os-release`, `uname -srmo`.
  - GPU: `lspci -mm` or `lspci` filtering `VGA compatible controller`, `3D controller`, and `Display controller`; fallback to `/sys/class/drm/card*/device`.
  - NVIDIA identity: `nvidia-smi --query-gpu=index,uuid,name,pci.bus_id,driver_version,memory.total --format=csv,noheader,nounits`.
  - NVIDIA live metrics: `nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.mem,pstate --format=csv,noheader,nounits`.
  - NVIDIA processes: `nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits`.
  - AMD identity: prefer `amd-smi static --json` or `amd-smi static --csv`; fallback to `rocm-smi --showhw`.
  - AMD live metrics: prefer `amd-smi metric --json` or `amd-smi monitor -putm` for utilization, memory, temperature, and power.
  - AMD processes: prefer `amd-smi process --json` or `amd-smi process --csv` when available.
  - AMD sysfs fallback: `/sys/class/drm/card*/device/gpu_busy_percent`, `mem_busy_percent`, `mem_info_vram_total`, `mem_info_vram_used`, and hwmon temperature/power files.
  - Intel live metrics: `intel_gpu_top -J -s <milliseconds> -o -` when available and permitted; parse engine utilization and memory where reported.
  - Generic fallback: report GPU identity only when no vendor telemetry path works.
- Darwin/macOS:
  - CPU: `sysctl -n machdep.cpu.brand_string`, `hw.physicalcpu`, `hw.logicalcpu`, `hw.optional.arm64`.
  - Machine: `sysctl -n hw.model`, `uname -m`, `sw_vers`, `uname -sr`.
  - GPU: `system_profiler SPDisplaysDataType -json` with a short timeout; fallback to `system_profiler SPDisplaysDataType` text parsing.
  - Live GPU telemetry: best effort only through `powermetrics --samplers gpu_power -n 1 -i <milliseconds> --show-usage-summary` or `powermetrics --samplers tasks --show-process-gpu -n 1`.
  - Do not run `sudo` or trigger password prompts. If `powermetrics` needs privileges, mark GPU live metrics unavailable and keep identity details.
  - Treat power values as estimates and do not compare them across machines.
- Windows:
  - CPU: `Get-CimInstance Win32_Processor`.
  - OS/machine: `Get-CimInstance Win32_OperatingSystem`, `Win32_ComputerSystem`.
  - GPU: `Get-CimInstance Win32_VideoController`.
  - NVIDIA live metrics: prefer `nvidia-smi.exe` if present.
  - Generic live metrics: use `Get-Counter`/PDH for `GPU Engine` counters when available; aggregate engine utilization per adapter best effort.
  - GPU process attribution is best effort because Windows GPU engine instance naming is driver and locale dependent.
- FreeBSD:
  - CPU/machine: `sysctl -n hw.model hw.machine hw.ncpu`.
  - GPU: `pciconf -lv` when available, filtering display/VGA devices.
- OpenBSD/NetBSD:
  - CPU/machine: `sysctl hw.model hw.machine hw.ncpu`.
  - GPU: best-effort `pcictl`/`dmesg` parsing only when available and fast.

Performance rules:
- Use command batching where possible.
- Use short command timeouts for hardware probes that can be slow.
- Avoid `sudo` and privileged commands.
- Missing `lspci`, `system_profiler`, `nvidia-smi`, `amd-smi`, `intel_gpu_top`, `powermetrics`, or PowerShell CIM/counter classes is not an error state.
- Hardware parsing should be best effort and deterministic.

Parsing rules:
- Deduplicate GPUs by stable name/vendor/model tuple.
- Classify GPU kind as `virtual` for known virtual adapters such as VMware, Parallels, VirtualBox, Hyper-V, QXL, Virtio, or llvmpipe.
- Keep display names user-readable; do not expose raw PCI IDs unless no better name exists.
- Prefer CSV/JSON output over human-formatted text whenever vendor tools provide it.
- Parse `N/A`, dashed values, blank values, and permission errors as missing fields, not zero.
- Normalize memory to bytes, power to watts, temperature to Celsius, clocks to MHz, and utilization to `0...100`.
- If a tool reports per-engine metrics, aggregate conservatively and keep engine-specific values for detail views only if the data model is extended later.
- Preserve raw unknown fields only in debug logs, not UI.

### GPU Research Notes
The implementation should be based on these source surfaces:
- NVIDIA `nvidia-smi` supports selective CSV queries and exposes utilization, memory, temperature, power, clocks, and compute-process queries.
  Source: https://docs.nvidia.com/deploy/nvidia-smi/index.html and https://nvidia.custhelp.com/app/answers/detail/a_id/3751/~/useful-nvidia-smi-queries
- AMD `amd-smi` is the preferred ROCm-era CLI and supports static, metric, monitor, process, JSON, and CSV output.
  Source: https://rocm.docs.amd.com/projects/amdsmi/en/latest/how-to/amdsmi-cli-tool.html and https://rocm.blogs.amd.com/software-tools-optimization/amd-smi-overview/README.html
- Linux AMDGPU sysfs exposes `gpu_busy_percent`, `mem_busy_percent`, and VRAM memory files.
  Source: https://docs.kernel.org/gpu/amdgpu/thermal.html and https://dri.freedesktop.org/docs/drm/gpu/amdgpu.html
- Intel `intel_gpu_top` exposes Intel GPU usage from PMU counters and supports JSON output, but not all metrics are supported on all platforms and non-root access depends on `perf_event_paranoid`.
  Source: https://manpages.debian.org/testing/intel-gpu-tools/intel_gpu_top.1.en.html
- Windows generic GPU metrics should use Performance Counters/PDH or `Get-Counter`; names are localized and some counter sets require administrator access.
  Source: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-counter
- macOS `powermetrics` can expose GPU power and per-process GPU time on supported hardware, but values are estimated and may require privileges.
  Source: local macOS `powermetrics(1)` manual.

### Normalization Rules
`StatsPreferences.normalized()` must:
- drop duplicate block IDs
- drop unknown legacy/future block IDs when they cannot be decoded
- append missing known blocks at the end
- force required blocks visible
- preserve user ordering for known blocks
- keep at least `system` visible
- clamp to known V1 blocks
- ensure `schemaVersion >= current schemaVersion`
- ensure `lastWriterDeviceId` is populated

### Merge Rules
Add:

```swift
static func merged(
    local: StatsPreferences,
    remote: StatsPreferences
) -> StatsPreferences
```

Conflict strategy:
- Style: newer `updatedAt` wins.
- Blocks: newer per-block `updatedAt` wins for visibility.
- Block order: newer profile-level `updatedAt` wins.
- Final result is normalized.

This mirrors the existing local-first preference approach and keeps conflict handling predictable.

### Application Store
Create:
- `VVTerm/Features/Stats/Application/PreferencesStore.swift`

Responsibilities:
- `@MainActor`, `ObservableObject`, shared instance.
- Load and save `StatsPreferences`.
- Publish current preferences.
- Update selected style.
- Move blocks.
- Set block visibility.
- Prevent the last visible block from being hidden.
- Schedule CloudKit sync through `CloudKitSyncCoordinator`.
- Merge CloudKit-resolved preferences into current local preferences.

Suggested public API:

```swift
@MainActor
final class PreferencesStore: ObservableObject {
    static let shared: PreferencesStore

    @Published private(set) var preferences: StatsPreferences

    var visibleBlocks: [StatsPreferences.Block] { get }

    func setStyle(_ style: StatsPreferences.Style)
    func moveBlocks(fromOffsets source: IndexSet, toOffset destination: Int)
    func setBlockVisibility(_ id: StatsPreferences.BlockID, isVisible: Bool)
    func refreshFromCloud() async
}
```

Errors:
- `cannotHideLastVisibleBlock`
- `unknownBlock`

### CloudKit Sync
Add:
- `CloudKitSyncConstants.statsPreferencesStorageKey = "statsPreferencesV1"`
- `PendingCloudKitEntity.statsPreferences`
- pending mutation helpers for upsert/delete if needed
- `CloudKitSyncCoordinator.enqueueStatsPreferencesUpsert(...)`
- `CloudKitManager.fetchStatsPreferences()`
- `CloudKitManager.saveStatsPreferences(...)`
- `CloudKitManager.syncStatsPreferences(...)`

CloudKit record:
- `recordType`: `UserPreference`
- `recordName`: `statsPreferences.v1`
- fields:
  - `schemaVersion: Int`
  - `payload: Data`
  - `updatedAt: Date`
  - `lastWriterDeviceId: String`

Sync behavior:
- Honor `SyncSettings.isEnabled`.
- Pull on app launch/foreground through `PreferencesStore`.
- Push on local preference edits with debounce/pending queue.
- On conflict, merge local and remote, save merged record, and publish resolved preferences.

Privacy:
- The payload contains only UI preferences.
- Do not log full payload contents.

### Rendering Architecture
Refactor `ServerStatsView` into a small container:

```swift
struct ServerStatsView: View {
    @StateObject private var collector: StatsCollector
    @StateObject private var preferences = PreferencesStore.shared

    var body: some View {
        LayoutHost(
            preferences: preferences.preferences,
            collector: collector,
            ...
        )
    }
}
```

Create UI files:
- `VVTerm/Features/Stats/UI/ServerStatsView.swift` - lifecycle/container
- `VVTerm/Features/Stats/UI/AppearanceSettings.swift`
- `VVTerm/Features/Stats/UI/Layouts/CompactLayout.swift`
- `VVTerm/Features/Stats/UI/Layouts/DetailedLayout.swift`
- `VVTerm/Features/Stats/UI/Layouts/ClassicLayout.swift`
- `VVTerm/Features/Stats/UI/Blocks/SummaryBlock.swift`
- `VVTerm/Features/Stats/UI/Blocks/MetricBlocks.swift`
- `VVTerm/Features/Stats/UI/Blocks/GPUBlock.swift`
- `VVTerm/Features/Stats/UI/Blocks/StorageBlock.swift`
- `VVTerm/Features/Stats/UI/Blocks/ProcessBlock.swift`
- `VVTerm/Features/Stats/UI/Components/Cards.swift`
- `VVTerm/Features/Stats/UI/Components/Charts.swift`
- `VVTerm/Features/Stats/UI/Components/Meters.swift`
- `VVTerm/Features/Stats/UI/Components/Rows.swift`
- `VVTerm/Features/Stats/UI/Components/DetailSheets.swift`

`LayoutHost` responsibilities:
- choose style
- pass ordered visible blocks to selected style
- keep error overlay and collection lifecycle in the container

Block components:
- `SummaryBlock`
- `CPUBlock`
- `MemoryBlock`
- `GPUBlock`
- `NetworkBlock`
- `StorageBlock`
- `ProcessBlock`

Do not create density-specific block types such as `CompactGPUBlock` or `DetailedGPUBlock`. Layout density should be passed through a small style value so block ownership remains shared.

Each block should be data-driven and style-aware, not collector-aware. Blocks receive formatted view data or raw `ServerStats` plus histories, but they do not start/stop collection.

### Chart Data
Keep history generation in `StatsCollector`:
- `cpuHistory`
- `memoryHistory`
- `gpuUtilizationHistoryByDeviceID`
- `gpuMemoryHistoryByDeviceID`
- `gpuPowerHistoryByDeviceID`
- `networkRxHistory`
- `networkTxHistory`

Do not duplicate chart sampling logic per style. Move shared chart helpers into `Components/Charts.swift`:
- percent sparkline
- GPU utilization/memory/power mini charts
- network line chart
- placeholder states

Charts must handle:
- zero samples
- one sample
- flat values
- spikes
- sorted samples
- capped history length
- devices appearing/disappearing between samples
- stale GPU samples

### Future Paid Customization
Do not gate V1 built-in style switching, block reordering, or block hide/show.

Potential paid extensions:
- add custom block presets
- save named layouts
- add extra built-in visual styles
- add advanced threshold/alert blocks

### Settings Integration
Update:
- `VVTerm/Features/Settings/UI/GeneralSettingsView.swift`

In the existing `Server Views` section, add:
- `NavigationLink("Stats Appearance") { AppearanceSettings() }`

Do not move `ViewTabConfigurationManager` ownership. It remains responsible for which top-level server views are visible.

### Migration Plan
- If no stored Stats preferences exist, create default preferences:
  - style: `.cardsCompact`
  - blocks: default V1 block order
- If corrupt payload exists, replace with normalized default preferences.
- If a future payload contains unknown blocks, ignore them and keep known blocks.
- Existing current card UI work should become `DetailedLayout`, then be tightened into `CompactLayout` for the default experience.
- The original Stats UI should be restored or reconstructed as `ClassicLayout` before shipping the style picker.

### Accessibility
- Style picker labels must be VoiceOver-readable.
- Reorder controls must support VoiceOver move actions.
- Hidden/visible block rows must use toggles, not custom tap-only controls.
- Chart-only blocks must expose current numeric values in accessibility labels.

### Analytics
Optional events:
- stats appearance style changed
- stats layout customized

Do not include server hostname, CPU/GPU model names, process names, volume paths, or metric values in analytics.

## Testing Plan

### Unit Tests
Add tests for:
- default preferences
- normalization
- required block visibility
- duplicate block removal
- missing block append
- style update persistence
- last visible block cannot be hidden
- merge behavior
- corrupt payload fallback
- `HardwareProfile.empty` fallback behavior
- GPU deduplication and virtual GPU classification
- GPU telemetry normalization to bytes/watts/Celsius/MHz/percent
- `N/A`/blank/dashed vendor fields become missing values, not zero
- NVIDIA CSV parser fixtures for GPU metrics and compute-process queries
- AMD JSON/CSV parser fixtures for `amd-smi static`, `metric`, `monitor`, and `process`
- AMDGPU sysfs parser fixtures for busy percent and VRAM files
- Intel `intel_gpu_top -J` parser fixtures
- Windows GPU performance counter aggregation fixtures
- macOS `powermetrics` parser fixtures for supported and permission-denied output
- platform parser fixtures for Linux, Darwin/macOS, Windows, and BSD hardware command output

### UI Tests
Add smoke coverage:
- Settings opens `Stats Appearance`.
- Style dropdown changes the active layout and updates the real-component mock preview immediately.
- Fresh install/default preferences show `Cards Compact`.
- `Cards Compact` and `Cards Detailed` render distinct density levels with the same ordered blocks.
- Users can reorder and hide optional blocks.
- Hiding or reordering a block updates the Stats view and mock preview.
- System card info opens `SystemDetailsView`.
- System details hide missing fields and show `No GPU reported` when no GPU is detected.
- GPU block appears when GPU identity or telemetry exists.
- GPU block hides or shows `Metrics unavailable` according to the runtime rules.
- GPU details show per-device metrics and active processes when available.

### Regression Checks
- Stats collection starts/stops only based on visibility, not style changes.
- Switching style does not reconnect SSH.
- iOS and macOS show the same configured block order.
- Hiding the Stats top-level server view still works independently from Stats block visibility.
- Network and memory charts render with empty, single-point, flat, and spiky histories.
- Hardware collection runs once per connection/session, not every polling interval.
- Missing GPU tooling does not show a connection error and does not stop live Stats refresh.
- `system_profiler`, `lspci`, and PowerShell CIM failures degrade to partial hardware details.
- `nvidia-smi`, `amd-smi`, `intel_gpu_top`, and `powermetrics` failures degrade independently from CPU/memory/network stats.
- GPU polling throttling does not slow the standard Stats refresh loop.
- Multi-GPU ordering remains stable across samples.

## Rollout
Phase 1:
- Add preferences domain model, `PreferencesStore`, local persistence, and Settings UI.
- Keep local only while validating.

Phase 2:
- Add `HardwareProfile`/`GPUDevice` domain models.
- Update platform collectors to collect hardware identity once per session.
- Add `SystemDetailsView` from the Summary/System card.

Phase 3:
- Add `GPUSample`, GPU histories, and vendor-specific live GPU telemetry collection.
- Add `GPUBlock` and `GPUDetailsView`.
- Prioritize NVIDIA and AMD Linux paths first because they cover most remote AI/compute servers.

Phase 4:
- Split current Stats view into `DetailedLayout`.
- Add `CompactLayout` as the default card layout.
- Restore `ClassicLayout`.
- Wire runtime style switching.

Phase 5:
- Add block reorder/hide.
- Add CloudKit sync.

Phase 6:
- Add additional built-in styles or saved presets if the model holds up.

## Open Questions
- Should paid customization unlock extra built-in styles later, saved presets, or extra block types?
- Do we want per-server Stats layout in V2, or should consistency across servers remain a product rule?
- Should V2 add container/Kubernetes/Slurm GPU allocation details for cluster users?
- Should V2 add alert thresholds for GPU temperature, memory pressure, and power throttling?
