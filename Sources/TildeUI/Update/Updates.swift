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
    /// `mayRelaunch`: asked just before Tilde quits to install; false makes the install wait
    /// for the next `restart`.
    func start(reporting: @escaping (UpdateStatus) -> Void, mayRelaunch: @escaping () -> Bool)
    func check()
    /// Downloads the available update.
    func install()
    /// Installs the ready update now and opens the new version.
    func restart()
}

/// The update state that Settings and the toast read, and the rules for what the user may do.
/// An update never installs in the middle of a session: Restart waits until no session is on
/// screen, and so does the toast that offers it.
///
/// With "Update automatically" on, a ready update installs by itself when Tilde is not in use:
/// no session, no Tilde window open, and no input to Tilde for `idleTime`. Tilde then opens
/// again as the new version, with no toast.
@MainActor
final class Updates: ObservableObject {
    @Published private(set) var status: UpdateStatus = .idle
    @Published var isAutomatic: Bool {
        didSet {
            engine.isAutomatic = isAutomatic
            waitForIdle()
        }
    }
    /// A session is on screen.
    @Published var isSessionActive = false {
        didSet {
            if !isSessionActive {
                lastUse = now()
            }
            announceIfDue()
        }
    }
    /// Shows the toast for a ready version; it is called once for each version.
    var onReady: (String) -> Void = { _ in }
    /// Whether Tilde shows a window, such as Settings or its browser.
    var showsWindow: () -> Bool = { false }
    /// This launch is the new version that a silent install opened: nothing asks the user.
    let isSilentRelaunch: Bool

    private let engine: UpdateEngine
    private let idleTime: TimeInterval
    private let defaults: UserDefaults
    private let now: () -> Date
    private let after: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var announced: String?
    private var lastUse: Date
    /// A check for idleness is due.
    private var isWaiting = false
    /// The install in progress is the silent one, not the user's Restart.
    private var installsSilently = false

    /// `idleTime`: how long Tilde gets no input before a silent install. `after`: runs its
    /// closure once, after the delay.
    init(
        engine: UpdateEngine, idleTime: TimeInterval = 300, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
        after: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, run in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                run()
            }
        }
    ) {
        self.engine = engine
        self.idleTime = idleTime
        self.defaults = defaults
        self.now = now
        self.after = after
        isAutomatic = engine.isAutomatic
        lastUse = now()
        if let installedAt = defaults.object(forKey: "silentUpdateAt") as? Date {
            isSilentRelaunch = now().timeIntervalSince(installedAt) < 120
            defaults.removeObject(forKey: "silentUpdateAt")
        } else {
            isSilentRelaunch = false
        }
    }

    func start() {
        engine.start { [weak self] status in
            self?.report(status)
        } mayRelaunch: { [weak self] in
            self?.mayRelaunch() ?? true
        }
    }

    /// The user gave Tilde input.
    func noteUse() {
        lastUse = now()
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
        installsSilently = false
        engine.restart()
    }

    private func report(_ status: UpdateStatus) {
        self.status = status
        announceIfDue()
        waitForIdle()
    }

    private func announceIfDue() {
        guard case .ready(let version) = status, !isAutomatic, !isSessionActive, announced != version else {
            return
        }
        announced = version
        onReady(version)
    }

    private var isIdle: Bool {
        !isSessionActive && !showsWindow() && now().timeIntervalSince(lastUse) >= idleTime
    }

    /// Checks for idleness once, when the last input is `idleTime` old. While a session or a
    /// window keeps Tilde in use, it checks again `idleTime` later.
    private func waitForIdle() {
        guard isAutomatic, case .ready = status, !isWaiting else {
            return
        }
        isWaiting = true
        var delay = idleTime - now().timeIntervalSince(lastUse)
        if delay <= 0 {
            delay = isSessionActive || showsWindow() ? idleTime : 0
        }
        after(delay) { [weak self] in
            self?.installIfIdle()
        }
    }

    private func installIfIdle() {
        isWaiting = false
        guard isAutomatic, case .ready = status else {
            return
        }
        guard isIdle else {
            waitForIdle()
            return
        }
        installsSilently = true
        defaults.set(now(), forKey: "silentUpdateAt")
        engine.restart()
    }

    /// Sparkle is about to quit Tilde: the install waits if a session started meanwhile, or,
    /// for a silent install, if the user came back.
    private func mayRelaunch() -> Bool {
        guard isSessionActive || (installsSilently && !isIdle) else {
            return true
        }
        defaults.removeObject(forKey: "silentUpdateAt")
        waitForIdle()
        return false
    }
}
