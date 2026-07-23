import Foundation

/// Preserves the order in which terminal input reaches an asynchronous
/// transport, even when an individual write suspends.
@MainActor
final class TerminalTransportWriteQueue {
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
