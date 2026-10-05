import Foundation

private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func track(_ task: Task<Void, Never>) {
        lock.lock()
        if result != nil { lock.unlock(); task.cancel() }
        else { tasks.append(task); lock.unlock() }
    }
    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        let tasks = self.tasks; self.tasks.removeAll(); lock.unlock()
        tasks.forEach { $0.cancel() }; continuation?.resume(with: result)
    }
}

/// A deadline that returns even when the underlying framework operation ignores cancellation.
/// Late work is cancelled and its result is discarded, never awaited by stop/start controls.
public enum AsyncDeadline {
    public static func run<Value: Sendable>(seconds: Double,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let race = DeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                race.track(Task {
                    do { try Task.checkCancellation(); race.resolve(.success(try await operation())) }
                    catch { race.resolve(.failure(error)) }
                })
                race.track(Task {
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    race.resolve(.failure(WLFailure.message("Operation exceeded \(seconds) second deadline")))
                })
            }
        } onCancel: { race.resolve(.failure(CancellationError())) }
    }
}
