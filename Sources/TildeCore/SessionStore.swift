import Foundation

/// Annotation sessions requested by agents. One session is on screen at a time;
/// later sessions queue until the active one is sent or cancelled.
@MainActor
public final class SessionStore: ObservableObject {
    public struct Session: Identifiable, Sendable {
        public let id: String
        /// Display name of the agent harness that asked, such as "Codex".
        public let client: String
        public let message: String?
        public let url: URL?
        public fileprivate(set) var state: State
    }

    public enum State: Sendable {
        case queued
        case annotating
        case sent(Feedback, folder: URL?)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .queued, .annotating:
                return false
            case .sent, .cancelled:
                return true
            }
        }
    }

    @Published public private(set) var sessions: [Session] = []

    private var waiters: [String: [UUID: CheckedContinuation<State, Never>]] = [:]
    private let finishedLimit = 50

    public init() {}

    public var active: Session? {
        sessions.first { session in
            if case .annotating = session.state {
                return true
            }
            return false
        }
    }

    public func session(_ id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    public func start(client: String, message: String?, url: URL?) -> Session {
        let state: State = active == nil ? .annotating : .queued
        let session = Session(id: Self.newID(), client: client, message: message, url: url, state: state)
        sessions.append(session)
        return session
    }

    /// Returns the session state once it finishes, or its current state after `seconds`.
    /// Returns nil for an unknown session.
    public func wait(for id: String, seconds: Double) async -> State? {
        guard let session = session(id) else {
            return nil
        }
        if session.state.isFinished || seconds <= 0 {
            return session.state
        }

        let token = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id, default: [:]][token] = continuation

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard let waiter = self.waiters[id]?.removeValue(forKey: token) else {
                    return
                }
                waiter.resume(returning: self.session(id)?.state ?? .cancelled)
            }
        }
    }

    /// Finishes a session with `.sent` or `.cancelled` and starts the next queued one.
    public func finish(_ id: String, with state: State) {
        precondition(state.isFinished, "finish requires a finished state")
        guard let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].state.isFinished else {
            return
        }

        sessions[index].state = state
        for waiter in (waiters.removeValue(forKey: id) ?? [:]).values {
            waiter.resume(returning: state)
        }

        if active == nil, let next = sessions.firstIndex(where: { if case .queued = $0.state { return true }; return false }) {
            sessions[next].state = .annotating
        }
        pruneFinished()
    }

    private func pruneFinished() {
        let finished = sessions.filter { $0.state.isFinished }
        guard finished.count > finishedLimit else {
            return
        }

        let dropped = Set(finished.prefix(finished.count - finishedLimit).map(\.id))
        sessions.removeAll { dropped.contains($0.id) }
    }

    private static func newID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
