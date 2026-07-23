# Native Platform Shells + Portable Core Bridge (Draft Idea Backlog)

## Summary
Explore a future non-Apple expansion of VVTerm that keeps each platform UI fully native while moving shared connection and session logic into a headless portable core exposed through a small C ABI / FFI bridge.

Path note: this draft predates the feature-first migration. Any legacy `Models/`, `Managers/`, `Services/`, or `Views/` file paths in this document should be mapped to the current `App/`, `Core/`, and `Features/` tree.

Draft date: 2026-03-08

Status: Backlog idea only. This is not an approved roadmap item.

## Problem
VVTerm is currently shaped around Apple platforms. The app lifecycle, UI shell, terminal embedding, secure storage, sync, purchases, biometrics, and several UX flows are tightly coupled to Apple frameworks and Apple runtime assumptions.

That makes a direct non-Apple port unattractive:
- Reusing the current SwiftUI/AppKit/UIKit surface would not feel native on HarmonyOS or Windows.
- Rewriting the entire app natively for each platform would duplicate a large amount of session and connection logic.
- A broad "Swift multiplatform" approach is unlikely to solve the toolchain and packaging constraints for every target platform.

## Idea
Build each non-Apple app as a native platform shell and treat the reusable systems layer as a headless engine.

The engine would:
- own server/workspace/session models
- own SSH/session orchestration
- own terminal byte-stream and connection state logic
- expose a small stable C ABI

Each platform shell would:
- render all UI with the native toolkit for that platform
- own platform-native UX and system integration
- call into the portable core through FFI
- provide platform-specific services back to the core when needed

## Goals
- Preserve a native platform UI and platform feel.
- Minimize duplication of SSH/session/domain logic.
- Keep the bridge small enough to stay maintainable.
- Keep latency low by using in-process FFI instead of a separate helper process.
- Refactor the current Apple codebase toward a headless reusable core over time.
- Make HarmonyOS a valid first non-Apple target without closing off a future Windows build.

## Non-Goals
- A near-term commitment to ship any specific non-Apple platform.
- Reusing the current Apple UI on non-Apple platforms.
- Full feature parity in V1 of any future non-Apple app.
- A single shared multiplatform UI layer.
- Exposing raw Swift types directly to Windows code.

## Product Direction
The product name should remain `VVTerm`.

This architecture assumes:
- `VVTerm` remains the umbrella product brand
- Apple remains one platform edition of VVTerm, not the entire product identity
- HarmonyOS can be the first non-Apple proving ground
- Windows can follow using the same core and bridge model

This keeps future platform expansion aligned under one product.

## Why FFI Instead Of IPC
This idea assumes FFI is the preferred bridge if work ever starts.

Reasons:
- in-process calls avoid helper-process lifecycle complexity
- lower latency for terminal/session interactions
- small intended API surface
- no extra transport/protocol layer unless future needs force one

Tradeoff:
- ABI and memory management discipline becomes critical

## Proposed Architecture

### High-level split
- `VVTermCore`
  - pure/headless portable systems module
  - preferred implementation candidate: Rust
  - no SwiftUI, AppKit, UIKit, CloudKit, StoreKit, Security, Metal, ActivityKit, or LocalAuthentication imports
- `VVTermApple`
  - current Apple app shell and platform adapters
- `VVTermHarmony`
  - future HarmonyOS app shell and Harmony adapters
- `VVTermWindows`
  - future Windows app shell and Windows adapters
- `VVTermBridge`
  - narrow C ABI wrapper around `VVTermCore`

### Expected rollout shape
- Phase 1: define the portable core boundary without breaking the Apple app
- Phase 2: validate the core and bridge with the first non-Apple shell, likely HarmonyOS
- Phase 3: reuse the same bridge and capability model for Windows if the first expansion is successful
- Phase 4: adopt the portable core inside Apple only where it safely reduces duplication

## Apple Stability Constraint
The existing Apple app must remain shippable while this architecture evolves.

That means:
- no big-bang replacement of Apple-side managers
- every extraction step should preserve current Apple behavior first
- new non-Apple work must not become a prerequisite for Apple releases
- the Apple app should continue to own platform features until a shared-core migration clearly reduces risk and duplication

The architecture only makes sense if it improves optionality without slowing down the product that already exists.

## Core Implementation Options
The portable core should be treated as an implementation choice behind a stable bridge, not as a Swift-only assumption.

### Swift core
Pros:
- easier to integrate incrementally with the current Apple codebase
- lower migration cost for Apple-first refactors

Cons:
- unclear HarmonyOS viability
- uncertain cross-platform packaging and toolchain story
- higher risk that Apple runtime assumptions leak into the shared layer

### Rust core
Pros:
- stronger cross-platform story for HarmonyOS and Windows
- better fit for a portable systems layer around SSH/session orchestration
- easier to keep the core narrow, headless, and platform-agnostic

Cons:
- initial rewrite cost
- requires a clean FFI boundary and disciplined DTO design
- Apple adoption becomes a deliberate migration instead of a direct extraction

Current bias:
- use Rust as the leading candidate for the first non-Apple shared core
- keep Apple on the current implementation initially
- only adopt the Rust core into Apple step by step after the boundary proves itself in non-Apple clients

### Responsibilities

#### Core owns
- server/workspace/session data models
- connection lifecycle
- SSH orchestration
- terminal I/O model
- connection state/events
- config and business rules
- DTOs used by the bridge

#### Platform app owns
- native UI
- windowing/navigation
- terminal rendering widget
- secure storage implementation
- sync backend implementation
- purchase/store implementation
- biometrics implementation
- notifications and OS integrations

## Portable Core Scope
The portable core should be optimized for portability and a small, easy-to-implement host surface.

That means:
- prefer stateless operations where possible
- prefer explicit DTO inputs and outputs over hidden internal storage
- keep the core usable from a headless test harness
- avoid embedding platform assumptions into persistence, sync, or purchase flows

### In scope
- server/workspace/session domain types
- validation and platform-neutral business rules
- SSH/session orchestration
- connection state machine
- terminal byte-stream input/output model
- session events and DTOs exposed through the bridge
- import/export formats that do not depend on platform SDKs

### Out of scope
- UI and native navigation
- terminal renderer implementation
- local persistence implementation
- cloud sync implementation
- secure secret storage implementation
- purchases and billing SDK integration
- biometrics and local authentication
- notifications and OS-level integrations

Rule of thumb:
- if it can run cleanly in a headless harness with fake host callbacks, it is a good portable-core candidate
- if it depends on OS services, vendor SDKs, or account/system integration, it should stay in the platform shell

## Persistence And Sync Boundary
Persistence and sync should remain platform-owned concerns.

The shared core may understand:
- domain models
- validation rules
- import/export formats
- neutral capability state such as entitlement level

The shared core should not own:
- database choices
- file storage strategy
- cloud sync orchestration
- platform account integration
- purchase receipt validation flows tied to a specific store backend

Preferred v1 model:
- host-driven persistence
- host remains the source of truth for stored data
- host loads and saves DTOs
- core validates and consumes DTOs but does not manage storage lifecycle

Possible exception:
- secrets required during connect may still use a narrow callback path so the host can resolve credentials just in time without exposing platform storage details

This keeps the first bridge surface smaller and avoids locking the core around Apple persistence assumptions.

## Dependency Inversion Strategy
Platform-dependent services should be represented as capabilities, not Apple framework calls.

Examples:
- `SecretStore`
- `SyncBackend`
- `PurchaseBackend`
- `BiometricBackend`
- `HostEnvironment`
- `ClipboardBridge`
- `TerminalRendererHost`

The core should say:
- "load secret for server X"
- "report entitlement state"

The core should never say:
- "read from Keychain"
- "save to CloudKit"
- "call StoreKit"

For v1, prefer host-driven data flow for servers and workspaces:
- host loads DTOs and passes them into the core
- host persists DTO changes after validation or mutation
- core should request host capabilities only where runtime interaction is necessary

## FFI Boundary Design
The FFI boundary should be intentionally small and C-shaped.

Allowed across the boundary:
- opaque handles
- integers/bools
- UTF-8 strings
- byte buffers
- JSON DTO payloads
- callback function pointers

Avoid across the boundary:
- Swift structs/enums directly
- reference graphs
- Swift async functions directly
- platform framework objects

### Suggested boundary style
- top-level core handle
- per-session opaque handles
- event callback registration
- JSON for structured requests/responses
- explicit free functions for memory returned to host
- versioned capability registration so future platform shells can grow without ABI drift

## Draft API Shape

### Core lifecycle
- `vvterm_core_create`
- `vvterm_core_destroy`
- `vvterm_core_set_event_callback`
- `vvterm_core_set_host_callbacks`

### Server and workspace operations
- `vvterm_core_load_state_json`
- `vvterm_core_export_state_json`
- `vvterm_core_validate_server_json`
- `vvterm_core_validate_workspace_json`

### Session operations
- `vvterm_core_connect_json`
- `vvterm_core_disconnect`
- `vvterm_core_send_input`
- `vvterm_core_resize`
- `vvterm_core_send_signal`

### Utility
- `vvterm_string_free`
- `vvterm_buffer_free`
- `vvterm_last_error_message`

## Example C ABI Sketch
```c
typedef void* VVTermCoreHandle;
typedef void* VVTermSessionHandle;

typedef void (*vvterm_event_callback)(
    const char* event_name,
    const char* event_json,
    void* context
);

VVTermCoreHandle vvterm_core_create(void);
void vvterm_core_destroy(VVTermCoreHandle core);

void vvterm_core_set_event_callback(
    VVTermCoreHandle core,
    vvterm_event_callback callback,
    void* context
);

char* vvterm_core_list_servers_json(VVTermCoreHandle core);
VVTermSessionHandle vvterm_core_connect_json(VVTermCoreHandle core, const char* request_json);
void vvterm_core_send_input(VVTermSessionHandle session, const uint8_t* bytes, int length);
void vvterm_core_resize(VVTermSessionHandle session, int cols, int rows);
void vvterm_core_disconnect(VVTermSessionHandle session);
void vvterm_string_free(char* value);
```

## Example Host Callback Direction
One likely pattern is for the platform shell to provide only the runtime services the core cannot perform by itself.

Example callback needs:
- load secret for server ID
- report entitlement state
- request biometric unlock if platform supports it
- optionally persist local settings if the host does not want to keep that orchestration outside the core

This keeps platform-native API usage on the shell side while allowing the portable core to stay platform-neutral.

## Example DTOs
```swift
public struct ServerDTO: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
}

public struct ConnectRequestDTO: Codable, Sendable {
    public var serverID: UUID
    public var cols: Int
    public var rows: Int
}

public struct TerminalOutputEventDTO: Codable, Sendable {
    public var sessionID: UUID
    public var dataBase64: String
}
```

## Refactor Direction In Current Repo
If this idea is pursued later, the first refactor should be to identify portable boundaries in the current app instead of trying to bridge Apple-shaped managers directly.

Probable extraction candidates:
- `Models/`
- parts of `Services/SSH/`
- session lifecycle logic from `Managers/ConnectionSessionManager.swift`
- parsers and terminal state glue that do not depend on Apple views

Probable Apple-only layers to keep out of core:
- `Services/CloudKit/CloudKitManager.swift`
- `Services/Keychain/KeychainManager.swift`
- `Services/Store/StoreManager.swift`
- `Services/Security/BiometricAuthService.swift`
- `GhosttyTerminal/*View*`

## First Architecture Questions To Answer
- Can libghostty or an equivalent renderer strategy be hosted cleanly on HarmonyOS and Windows without polluting `VVTermCore`?
- Which current managers contain real domain logic versus Apple-bound orchestration that should stay in `VVTermApple`?
- Should sync remain entirely host-owned in v1, with entitlements as a narrow optional capability only?
- Which DTOs are stable enough to freeze early, and which should remain internal until the first bridge prototype works?
- Is Rust the right systems layer for the first non-Apple clients, or is there a strong reason to keep the first core in Swift?

## Bridge Feasibility Is Unproven
The bridge should be treated as a hypothesis until proven on the first non-Apple platform.

Questions that must be answered before committing:
- can the chosen core language compile and package cleanly for HarmonyOS?
- can it expose a stable ABI that the host platform can call reliably?
- can the integration and debugging story remain sane for a real product team?

If the answer is no for HarmonyOS, that does not invalidate the product direction. It only invalidates one implementation path.

## Suggested Next Steps
- Rename this idea from a Windows-specific port concept into a platform-shell expansion concept
- Inventory Apple-only dependencies currently mixed into domain and session code
- Define a first-pass `VVTermCore` boundary in terms of modules, DTOs, and capabilities
- Decide the minimum host-driven state contract for servers, workspaces, and entitlement state
- Prototype one thin end-to-end bridge path: create core, list servers, connect session, stream terminal output, disconnect
- Validate Rust toolchain and FFI viability for HarmonyOS before committing to a shared-core implementation
- Use HarmonyOS as the first non-Apple validation target only if the work also improves a later Windows path

## Platform Shell Direction
If a non-Apple version ever starts, it should target native platform UI rather than trying to preserve the Apple visual structure.

Assumptions:
- HarmonyOS should use Harmony-native settings, navigation, and system flows
- Windows should use Windows-native settings, navigation, and system flows
- each platform should own its own secure storage and system prompts
- the terminal rendering layer should remain platform-owned, with the shared core owning session and byte-stream behavior

## Major Risks
- The current codebase may require substantial refactoring before a stable core can exist.
- Terminal integration may remain the hardest part even with a shared core.
- Async/event-heavy session logic can become brittle if callback and threading rules are not explicit.
- HarmonyOS and Windows toolchain constraints may shape feasibility differently.
- The Rust rewrite may front-load cost before the boundary is proven.
- A small bridge can gradually grow into an overly chatty interface if not enforced.
- Apple migration may create more churn than value if attempted too early.

## Guardrails If Work Ever Starts
- Keep the FFI API intentionally small.
- Prefer coarse-grained events and payloads over many tiny synchronous calls.
- Use opaque handles and DTOs only.
- Make ownership and free rules explicit in the ABI.
- Keep platform-specific services outside the core.
- Do not move Apple-only features into the first shared-core pass unless there is proven payoff.
- Treat Apple adoption as optional until the portable core proves itself in non-Apple clients.
- Do not rewrite Apple-first platform integrations just to make the architecture look cleaner on paper.

## Suggested Milestones

### Milestone 0: Investigation spike
- validate Rust core toolchain constraints for the first non-Apple target
- validate the shared bridge shape with a tiny native host prototype
- validate how terminal rendering stays outside the core

### Milestone 1: Portable boundary definition
- define the first portable DTOs, session APIs, and host capability interfaces
- choose which current logic is rewritten into the portable core versus left in Apple code
- keep persistence and sync outside the core unless a concrete portability payoff is proven

### Milestone 2: Minimal bridge
- create `VVTermBridge` with create/destroy/list/connect/send/resize/disconnect
- emit terminal output and connection-state events through callback

### Milestone 3: First non-Apple core client
- implement the first non-Apple shell against the portable core
- validate secrets, settings, and session lifecycle through host callbacks

### Milestone 4: First non-Apple prototype
- native platform shell
- native list/detail flows
- one working terminal/session path

### Milestone 5: Second non-Apple platform reuse
- reuse the bridge and DTO model on a second platform
- confirm the architecture scales without rewriting the core boundary

### Milestone 6: Apple adoption review
- identify whether any Apple-side duplication is now expensive enough to replace with the portable core
- migrate only narrow proven slices if the change improves safety and maintainability

## Open Questions
- Is Rust packaging and FFI integration mature enough on HarmonyOS for a production app?
- Should the first shared core exclude sync, purchases, and biometrics entirely?
- Should the first non-Apple shell own more business logic initially to reduce bridge complexity?
- Is the terminal host best treated as fully platform-owned with only byte-stream/session control in core?
- Is the future bridge best kept synchronous where possible, or should it be event-first from day one?
- Which parts of today's Apple SSH/session stack are stable enough to rewrite once without thrashing requirements?

## Recommendation
If this backlog item is ever revisited, start with a technical spike and treat the bridge as an engineering experiment, not a product commitment.

The path only makes sense if all of the following stay true:
- each platform UI remains fully native
- the shared API can remain small
- a headless portable core can be implemented without distorting platform UX
- the bridge actually reduces long-term duplication instead of spreading complexity across two runtimes
- Apple remains stable while non-Apple architecture is being proven
