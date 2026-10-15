import Foundation

/// A value guarded by a lock, for state shared between the main actor and the
/// capture/render queues. Keep critical sections short and never call out to
/// other locked code while holding it.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value {
        withLock { $0 }
    }
}
