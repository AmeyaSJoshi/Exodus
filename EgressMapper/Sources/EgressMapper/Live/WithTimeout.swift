import Foundation

/// A request that never came back. An unreachable host does not fail fast —
/// the socket just sits open — so without a deadline a call against a stale
/// address spins forever with nothing on screen to explain it.
struct BackendTimeout: Error {}

/// Runs `operation`, or throws `BackendTimeout` if it outlasts `seconds`.
///
/// Whichever of the two finishes first decides the result; the loser is
/// cancelled on the way out.
@discardableResult
@MainActor
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @MainActor () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { @MainActor in try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw BackendTimeout()
        }
        guard let first = try await group.next() else { throw BackendTimeout() }
        group.cancelAll()
        return first
    }
}
