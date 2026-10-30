import Foundation
import os

/// Logs when the main thread does not answer for a noticeable time, with how long, from a
/// background queue: `log show --predicate "category == \"stall\""` gives the numbers.
enum MainThreadWatch {
    private static let log = Logger(subsystem: "dev.tilde.app", category: "stall")
    private static let queue = DispatchQueue(label: "tilde.main-thread-watch", qos: .utility)
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var askedAt: Date?

    static func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 0.1, leeway: .milliseconds(20))
        source.setEventHandler {
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
        source.resume()
        timer = source
    }
}
