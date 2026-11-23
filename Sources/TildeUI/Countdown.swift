import Foundation

/// One piece of work that runs after a wait. Starting it again starts the wait again, so
/// only the last one runs.
@MainActor
final class Countdown {
    private var task: Task<Void, Never>?
    private var work: (@MainActor () -> Void)?

    /// Work waits to run.
    var isPending: Bool {
        work != nil
    }

    func start(_ seconds: TimeInterval, then work: @escaping @MainActor () -> Void) {
        task?.cancel()
        self.work = work
        task = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled {
                runNow()
            }
        }
    }

    /// Runs the waiting work at once, if any.
    func runNow() {
        task?.cancel()
        task = nil
        let work = self.work
        self.work = nil
        work?()
    }

    func cancel() {
        task?.cancel()
        task = nil
        work = nil
    }
}
