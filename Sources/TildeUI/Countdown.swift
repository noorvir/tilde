import Foundation

/// One piece of work that runs after a wait. Starting it again starts the wait again, so
/// only the last one runs.
@MainActor
final class Countdown {
    private var task: Task<Void, Never>?

    func start(_ seconds: TimeInterval, then work: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled {
                work()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
