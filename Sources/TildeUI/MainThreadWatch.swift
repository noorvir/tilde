import Foundation
import os

/// Logs when the main thread does not answer for a noticeable time, with how long, from a
/// background queue: `log show --predicate "category == \"stall\""` gives the numbers.
/// It asks ten times a second, so it runs only while a session is on screen: an app with
/// nothing to do must not wake.
enum MainThreadWatch {
    private static let log = Logger(subsystem: "dev.tilde.app", category: "stall")
    private static let queue = DispatchQueue(label: "tilde.main-thread-watch", qos: .utility)
    // Read and written on `queue` only.
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var askedAt: Date?

    static func start() {
        queue.async {
            guard timer == nil else {
                return
            }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 0.1, leeway: .milliseconds(20))
            source.setEventHandler(handler: ask)
            source.resume()
            timer = source
        }
    }

    static func stop() {
        queue.async {
            timer?.cancel()
            timer = nil
        }
    }

    private static func ask() {
        guard askedAt == nil else {
            return
        }
        let asked = Date()
        askedAt = asked
        DispatchQueue.main.async {
            let waited = Date().timeIntervalSince(asked)
            queue.async { askedAt = nil }
            if waited > 0.1 {
                log.notice("main thread stalled \(Int(waited * 1000), privacy: .public) ms")
            }
        }
    }
}
