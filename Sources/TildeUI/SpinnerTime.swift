import Foundation

/// When a spinner started: it shows for at least a second, also when its work ends sooner.
struct SpinnerTime {
    private let start = ContinuousClock.now

    /// Waits out what is left of the second.
    func waitForMinimum() async {
        try? await Task.sleep(until: start + .seconds(1), clock: .continuous)
    }
}
