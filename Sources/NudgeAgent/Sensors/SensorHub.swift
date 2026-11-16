import Foundation
import AppKit
import CoreGraphics

/// Collects all cheap, continuous signals and turns them into `SensorEvent`s.
///
/// Threading: create, start, stop and read from the main thread. Accessibility reads run on a
/// serial window queue, AppleScript and the Firefox tree walk on a serial browser queue; all
/// results come back to main. `onEvent` is always called on the main thread.
final class SensorHub: SensorHubProtocol {

    var onEvent: ((SensorEvent) -> Void)?
    private(set) var currentContext: WindowContext?

    // MARK: Tunables

    private let pollInterval: TimeInterval = 2
    private let dwellSeconds: TimeInterval = 3
    /// Extra time the dwell waits for a browser URL read before emitting without it.
    private let maxBrowserWait: TimeInterval = 5
    private let browserRefreshInterval: TimeInterval = 5
    private let clipboardInterval: TimeInterval = 1
    private let idleInterval: TimeInterval = 2
    private let meetingInterval: TimeInterval = 3
    private let fileInterval: TimeInterval = 3
    /// A meeting tab counts as "recent" for this long.
    private let browserMeetingMemory: TimeInterval = 15 * 60

    // MARK: Dependencies

    private let settingsProvider: () -> AppSettings
    private let browserReader = BrowserURLReader() // only touched on browserQueue
    private let windowQueue = DispatchQueue(label: "app.nudgeagent.sensors.window", qos: .utility)
    private let browserQueue = DispatchQueue(label: "app.nudgeagent.sensors.browser", qos: .utility)

    // MARK: State (main thread only)

    private var running = false
    /// Bumped on stop so late background results are dropped.
    private var generation = 0
    private var timers: [Timer] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    private var windowReadInFlight = false
    private var windowReadAgain = false
    private var loggedNoAccessibility = false

    private var browserInFlightKey: String?
    private var browserReadAgain = false
    /// Key ("pid|raw title") of the last completed browser read.
    private var browserSettledKey: String?
    private var lastBrowserRequestAt = Date.distantPast

    private var candidateSince = Date()
    private var lastEmittedIdentity: String?

    private var lastChangeCount = 0
    private var isIdle = false
    private var lockedFlag = false
    private var systemAsleep = false
    private var screensAsleep = false
    private var reportedLocked = false
    private var inMeeting = false
    private var browserMeetingSeenAt: Date?
    private var watchedFiles: [String: Date?] = [:]

    init(settingsProvider: @escaping () -> AppSettings) {
        self.settingsProvider = settingsProvider
    }

    deinit {
        // Observers and timers hold weak references; just make sure they are gone.
        timers.forEach { $0.invalidate() }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    // MARK: - SensorHubProtocol

    func start() {
        guard !running else { return }
        running = true

        lastChangeCount = NSPasteboard.general.changeCount
        isIdle = false
        lockedFlag = false; systemAsleep = false; screensAsleep = false; reportedLocked = false
        inMeeting = false
        lastEmittedIdentity = nil
        candidateSince = Date()
        browserSettledKey = nil
        lastBrowserRequestAt = .distantPast

        if !Permissions.accessibilityGranted() {
            NSLog("SensorHub: Accessibility not granted, window titles unavailable (app names only).")
            loggedNoAccessibility = true
        }

        observeWorkspace()
        observeLock()

        addTimer(pollInterval) { $0.pollWindow() }
        addTimer(0.5) { $0.checkDwell() }
        addTimer(clipboardInterval) { $0.checkClipboard() }
        addTimer(idleInterval) { $0.checkIdle() }
        addTimer(meetingInterval) { $0.checkMeeting() }
        addTimer(fileInterval) { $0.checkFiles() }

        pollWindow()
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedObservers.removeAll()
        windowReadInFlight = false
        windowReadAgain = false
        browserInFlightKey = nil
        browserReadAgain = false
    }

    func watchFiles(_ paths: [String]) {
        var next: [String: Date?] = [:]
        for raw in paths where !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            next[path] = watchedFiles[path] ?? Self.modificationDate(path)
        }
        watchedFiles = next
    }

    // MARK: - Setup helpers

    private func addTimer(_ interval: TimeInterval, _ action: @escaping (SensorHub) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            action(self)
        }
        timer.tolerance = min(0.25, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        let add: (Notification.Name, @escaping (SensorHub) -> Void) -> Void = { [weak self] name, action in
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.running else { return }
                action(self)
            }
            self?.workspaceObservers.append(token)
        }
        add(NSWorkspace.didActivateApplicationNotification) { $0.pollWindow() }
        add(NSWorkspace.willSleepNotification) { $0.systemAsleep = true; $0.updateLock() }
        add(NSWorkspace.didWakeNotification) { $0.systemAsleep = false; $0.updateLock() }
        add(NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true; $0.updateLock() }
        add(NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false; $0.updateLock() }
    }

    private func observeLock() {
        let dnc = DistributedNotificationCenter.default()
        let pairs: [(String, Bool)] = [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)]
        for (name, locked) in pairs {
            let token = dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self, self.running else { return }
                self.lockedFlag = locked
                self.updateLock()
            }
            distributedObservers.append(token)
        }
    }

    private func emit(_ event: SensorEvent) {
        onEvent?(event)
    }

    // MARK: - Window and context

    private func pollWindow() {
        guard running, let app = NSWorkspace.shared.frontmostApplication else { return }
        if windowReadInFlight { windowReadAgain = true; return }
        windowReadInFlight = true

        let gen = generation
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? bundleID
        windowQueue.async { [weak self] in
            let snap = AXWindowReader.read(pid: pid)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.windowReadInFlight = false
                self.handleWindow(pid: pid, bundleID: bundleID, appName: appName, snap: snap)
                if self.windowReadAgain {
                    self.windowReadAgain = false
                    self.pollWindow()
                }
            }
        }
    }

    private static func browserKey(pid: pid_t, title: String) -> String { "\(pid)|\(title)" }

    private func handleWindow(pid: pid_t, bundleID: String, appName: String, snap: AXWindowReader.Snapshot) {
        if !snap.trusted, !loggedNoAccessibility {
            NSLog("SensorHub: Accessibility not granted, window titles unavailable (app names only).")
            loggedNoAccessibility = true
        } else if snap.trusted {
            loggedNoAccessibility = false
        }

        // Keep the URL only while we are in the same window with the same title; a new title
        // usually means a new tab or page, and a stale URL would mislead.
        var url: String?
        var browserPrivate = false
        if let prev = currentContext, prev.pid == pid, prev.bundleID == bundleID, prev.windowTitle == snap.title {
            url = prev.url
            browserPrivate = prev.isPrivateWindow && !SensorContextBuilder.titleLooksPrivate(prev.windowTitle)
        }

        let ctx = SensorContextBuilder.makeContext(
            timestamp: Date(), bundleID: bundleID, appName: appName, pid: pid,
            windowTitle: snap.title, url: url, documentPath: snap.documentPath,
            browserSaysPrivate: browserPrivate)
        setCurrent(ctx)

        if ctx.isBrowser {
            let key = Self.browserKey(pid: pid, title: snap.title)
            requestBrowserRead(key: key, bundleID: bundleID, pid: pid,
                               force: key != browserSettledKey)
        }
    }

    /// Updates `currentContext`, keeping the original timestamp while the identity holds and
    /// resetting the dwell clock only on a real change.
    private func setCurrent(_ newContext: WindowContext) {
        var ctx = newContext
        let now = Date()
        if let prev = currentContext {
            let sameWindow = prev.pid == ctx.pid && prev.bundleID == ctx.bundleID && prev.windowTitle == ctx.windowTitle
            if prev.identity == ctx.identity {
                ctx.timestamp = prev.timestamp
                if ctx == prev { return }
            } else if sameWindow && prev.url == nil && ctx.url != nil {
                // URL arrived after the title: same moment, enrich without restarting the dwell.
                ctx.timestamp = prev.timestamp
            } else {
                ctx.timestamp = now
                candidateSince = now
            }
        } else {
            ctx.timestamp = now
            candidateSince = now
        }
        currentContext = ctx
        if SensorMeetingDetector.isMeetingDomain(ctx.domain) { browserMeetingSeenAt = now }
    }

    // MARK: - Browser URL

    private func requestBrowserRead(key: String, bundleID: String, pid: pid_t, force: Bool) {
        if let inFlight = browserInFlightKey {
            if inFlight != key { browserReadAgain = true }
            return
        }
        guard force || Date().timeIntervalSince(lastBrowserRequestAt) >= browserRefreshInterval else { return }

        browserInFlightKey = key
        lastBrowserRequestAt = Date()
        let gen = generation
        let reader = browserReader
        browserQueue.async { [weak self] in
            let result = reader.read(bundleID: bundleID, pid: pid)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.browserInFlightKey = nil
                self.handleBrowser(key: key, result: result)
                if self.browserReadAgain {
                    self.browserReadAgain = false
                    if let ctx = self.currentContext, ctx.isBrowser {
                        let current = Self.browserKey(pid: ctx.pid, title: ctx.windowTitle)
                        self.requestBrowserRead(key: current, bundleID: ctx.bundleID, pid: ctx.pid,
                                                force: current != self.browserSettledKey)
                    }
                }
            }
        }
    }

    private func handleBrowser(key: String, result: BrowserURLReader.Result) {
        browserSettledKey = key
        guard let prev = currentContext, Self.browserKey(pid: prev.pid, title: prev.windowTitle) == key else { return }
        // On a failed read keep what we had (if anything) rather than dropping a known URL.
        let url = result.succeeded ? result.url : prev.url
        let browserPrivate = result.succeeded
            ? result.isPrivate
            : (prev.isPrivateWindow && !SensorContextBuilder.titleLooksPrivate(prev.windowTitle))
        let ctx = SensorContextBuilder.makeContext(
            timestamp: prev.timestamp, bundleID: prev.bundleID, appName: prev.appName, pid: prev.pid,
            windowTitle: prev.windowTitle, url: url, documentPath: prev.documentPath,
            browserSaysPrivate: browserPrivate)
        setCurrent(ctx)
    }

    // MARK: - Dwell

    private func checkDwell() {
        guard let ctx = currentContext, ctx.identity != lastEmittedIdentity else { return }
        let elapsed = Date().timeIntervalSince(candidateSince)
        guard elapsed >= dwellSeconds else { return }
        if ctx.isBrowser {
            let key = Self.browserKey(pid: ctx.pid, title: ctx.windowTitle)
            let settled = browserSettledKey == key && browserInFlightKey != key
            if !settled && elapsed < dwellSeconds + maxBrowserWait { return }
        }
        lastEmittedIdentity = ctx.identity
        emit(.contextChanged(ctx))
    }

    // MARK: - Clipboard

    private func checkClipboard() {
        let count = NSPasteboard.general.changeCount // never read contents
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? currentContext?.bundleID ?? ""
        emit(.copyDetected(bundleID: bundleID, at: Date()))
    }

    // MARK: - Idle

    private func checkIdle() {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
        let threshold = max(5, settingsProvider().idleSeconds)
        let idleNow = seconds >= threshold
        guard idleNow != isIdle else { return }
        isIdle = idleNow
        emit(.idle(idleNow))
    }

    // MARK: - Lock and sleep

    private func updateLock() {
        let locked = lockedFlag || systemAsleep || screensAsleep
        guard locked != reportedLocked else { return }
        reportedLocked = locked
        emit(.screenLocked(locked))
        if !locked { pollWindow() }
    }

    // MARK: - Meetings

    private func checkMeeting() {
        let now = Date()
        if let ctx = currentContext, SensorMeetingDetector.isMeetingDomain(ctx.domain) {
            browserMeetingSeenAt = now
        }
        var meeting = false
        if SensorMeetingDetector.microphoneInUse() {
            let browserRecent = browserMeetingSeenAt.map { now.timeIntervalSince($0) < browserMeetingMemory } ?? false
            meeting = browserRecent || SensorMeetingDetector.meetingAppRunning()
        }
        guard meeting != inMeeting else { return }
        inMeeting = meeting
        emit(.meeting(meeting))
    }

    // MARK: - Files

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func checkFiles() {
        guard !watchedFiles.isEmpty else { return }
        for (path, previous) in watchedFiles {
            let current = Self.modificationDate(path)
            guard current != previous else { continue }
            watchedFiles[path] = current
            if let current {
                emit(.fileChanged(path: path, at: current))
            }
        }
    }
}
