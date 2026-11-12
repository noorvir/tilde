import Foundation

/// Where an update is, as the Configuration page and the toast show it.
enum UpdateStatus: Equatable {
    /// No check yet since launch.
    case idle
    case checking
    case upToDate
    case available(version: String)
    /// `progress` is 0 to 1, or nil while the size is not known.
    case downloading(version: String, progress: Double?)
    /// Downloaded and checked: it installs when Tilde quits, or now with Restart.
    case ready(version: String)
    case failed(reason: String)
}

/// What finds, downloads and installs updates. It reports each new status through the closure
/// that `start` gets, on the main thread.
@MainActor
protocol UpdateEngine: AnyObject {
    /// Whether a scheduled check downloads what it finds, to install when Tilde quits.
    var isAutomatic: Bool { get set }
    func start(reporting: @escaping (UpdateStatus) -> Void)
    func check()
    /// Downloads the available update.
    func install()
    /// Installs the ready update now and opens the new version.
    func restart()
}

/// The update state that Settings and the toast read, and the rules for what the user may do.
/// An update never installs in the middle of a session: Restart waits until no session is on
/// screen, and so does the toast that offers it.
@MainActor
final class Updates: ObservableObject {
    @Published private(set) var status: UpdateStatus = .idle
    @Published var isAutomatic: Bool {
        didSet { engine.isAutomatic = isAutomatic }
    }
    /// A session is on screen.
    @Published var isSessionActive = false {
        didSet { announceIfDue() }
    }
    /// Shows the toast for a ready version; it is called once for each version.
    var onReady: (String) -> Void = { _ in }

    private let engine: UpdateEngine
    private var announced: String?

    init(engine: UpdateEngine) {
        self.engine = engine
        isAutomatic = engine.isAutomatic
    }

    func start() {
        engine.start { [weak self] status in
            self?.report(status)
        }
    }

    var canCheck: Bool {
        switch status {
        case .idle, .upToDate, .failed: true
        case .checking, .available, .downloading, .ready: false
        }
    }

    var canRestart: Bool {
        guard case .ready = status else {
            return false
        }
        return !isSessionActive
    }

    func check() {
        guard canCheck else {
            return
        }
        status = .checking
        engine.check()
    }

    func install() {
        guard case .available = status else {
            return
        }
        engine.install()
    }

    func restart() {
        guard canRestart else {
            return
        }
        engine.restart()
    }

    private func report(_ status: UpdateStatus) {
        self.status = status
        announceIfDue()
    }

    private func announceIfDue() {
        guard case .ready(let version) = status, !isSessionActive, announced != version else {
            return
        }
        announced = version
        onReady(version)
    }
}
