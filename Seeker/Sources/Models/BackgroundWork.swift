import Foundation

enum BackgroundWork {
    /// Cancellation must also be checked inside long-running synchronous work.
    nonisolated static func run<Value: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
