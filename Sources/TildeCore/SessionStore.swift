import Foundation

/// Annotation sessions requested by agents or started by the user. One session is on screen at a time;
/// later sessions queue until the active one is sent or cancelled.
@MainActor
public final class SessionStore: ObservableObject {
    public struct Session: Identifiable, Sendable {
        public let id: String
        /// Display name of the agent harness that asked, such as "Codex".
        public let client: String
        /// The machine the agent runs on, reached over ssh; nil on this Mac.
        public let node: String?
        public let url: URL?
        /// Started by the user from Tilde itself; no agent waits for the result.
        public let isLocal: Bool
        /// Whether each annotation also gets a screenshot of the window around it.
        public let capturesContext: Bool
        public fileprivate(set) var state: State
        /// Annotations the user has made so far, for progress messages.
        public fileprivate(set) var noteCount = 0
    }

    public enum State: Sendable {
        case queued
        case annotating
        /// `folder`: where the report is saved, with its pictures.
        case sent(Feedback, folder: URL?)
        case cancelled

        /// The state that the store keeps for an agent that asks again. The pictures of a
        /// report saved in a folder stay there only: else the pictures of every finished
        /// session that the store remembers would stay in memory.
        fileprivate var kept: State {
            guard case .sent(var feedback, let folder?) = self else {
                return self
            }
            feedback.annotations = feedback.annotations.map { annotation in
                Annotation(id: annotation.id, comment: annotation.comment, target: annotation.target, frame: annotation.frame, image: nil, contextImage: nil)
            }
            return .sent(feedback, folder: folder)
        }

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

    /// Asked for a session id this store does not know, such as an agent waiting again for a
    /// session from before Tilde restarted, with the waiting agent's machine. Returns whether
    /// it started that session again.
    public var reattach: ((_ id: String, _ node: String?) -> Bool)?

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

    /// `id`: a session's own id when it starts again after Tilde restarted.
    public func start(id: String? = nil, client: String, node: String? = nil, url: URL?, isLocal: Bool = false, capturesContext: Bool = true) -> Session {
        let state: State = active == nil ? .annotating : .queued
        let session = Session(
            id: id ?? Self.newID(), client: client, node: node, url: url,
            isLocal: isLocal, capturesContext: capturesContext, state: state
        )
        sessions.append(session)
        return session
    }

    /// Returns the session state once it finishes, or its current state after `seconds`.
    /// Returns nil for an unknown session. `node` is the waiting agent's machine, nil for this
    /// Mac: a session of another machine is unknown to it.
    public func wait(for id: String, node: String?, seconds: Double) async -> State? {
        guard Self.isSessionID(id) else {
            return nil
        }
        if session(id) == nil, reattach?(id, node) != true {
            return nil
        }
        guard let session = session(id), session.node == node else {
            return nil
        }
        if session.state.isFinished || seconds <= 0 {
            return session.state
        }

        // The wait ends at the session's end, after `seconds`, or when the caller is cancelled,
        // such as when its connection ends; each returns the state then.
        let token = UUID()
        let endWait = { @MainActor [weak self] in
            guard let self, let waiter = self.waiters[id]?.removeValue(forKey: token) else {
                return
            }
            waiter.resume(returning: self.session(id)?.state ?? .cancelled)
        }
        let timer = Task { @MainActor in
            if (try? await Task.sleep(for: .seconds(seconds))) != nil {
                endWait()
            }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id, default: [:]][token] = continuation
            }
        } onCancel: {
            Task { @MainActor in endWait() }
        }
    }

    public func updateNoteCount(_ count: Int, for id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }
        sessions[index].noteCount = count
    }

    /// Finishes a session with `.sent` or `.cancelled` and starts the next queued one.
    public func finish(_ id: String, with state: State) {
        precondition(state.isFinished, "finish requires a finished state")
        guard let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].state.isFinished else {
            return
        }

        sessions[index].state = state.kept
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

    /// Whether text has the form of a session id that Tilde makes, such as `14d2dc23`.
    public static func isSessionID(_ text: String) -> Bool {
        text.wholeMatch(of: #/[0-9a-f]{8}/#) != nil
    }

    private static func newID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
