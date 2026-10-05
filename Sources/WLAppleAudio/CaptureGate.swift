import Foundation

/// Serializes admission with stopping. Accepted writes must drain before closing the file.
public final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var accepting = false
    public init() {}
    public func open() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1; accepting = true; return generation
    }
    @discardableResult public func offer(generation: Int, enqueue: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting, self.generation == generation else { return false }
        enqueue(); return true
    }
    public func close() { lock.lock(); accepting = false; lock.unlock() }
}
