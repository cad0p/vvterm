import Foundation
import Combine

@MainActor
final class VoiceRecordingOperationCoordinator: ObservableObject {
    private var task: Task<Void, Never>?
    private var activeOperationID: UUID?

    @discardableResult
    func start<Value>(
        operation: @escaping @MainActor (UUID) async throws -> Value,
        onSuccess: @escaping @MainActor (Value) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) -> Task<Void, Never> {
        cancel()

        let operationID = UUID()
        activeOperationID = operationID
        let task = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                guard self?.activeOperationID == operationID else { return }
                let value = try await operation(operationID)
                try Task.checkCancellation()
                guard self?.finish(operationID) == true else { return }
                onSuccess(value)
            } catch is CancellationError {
                _ = self?.finish(operationID)
            } catch {
                guard self?.finish(operationID) == true else { return }
                onFailure(error)
            }
        }
        self.task = task
        return task
    }

    func cancel() {
        activeOperationID = nil
        task?.cancel()
        task = nil
    }

    private func finish(_ operationID: UUID) -> Bool {
        guard activeOperationID == operationID else { return false }
        activeOperationID = nil
        task = nil
        return true
    }

    deinit {
        task?.cancel()
    }
}
