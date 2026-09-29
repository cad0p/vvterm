import Foundation

/// Preserves the order in which terminal input reaches an asynchronous
/// transport, even when an individual write suspends.
@MainActor
final class TerminalTransportWriteQueue {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    private var pendingWrite: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previousWrite = pendingWrite
        pendingWrite = Task(priority: .userInitiated) {
            await previousWrite?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func waitForPendingWrites() async {
        await pendingWrite?.value
    }
}
