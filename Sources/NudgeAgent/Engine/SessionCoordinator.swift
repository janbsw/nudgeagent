import Foundation

/// The brain: wires sensors, classifier, trip tracker, drift engine and the nudge UI together.
/// Main thread only. Talks to other modules through protocols only.
final class SessionCoordinator: SessionControlling {
    let state: SessionState
    private let sensors: SensorHubProtocol
    private let classifier: Classifying
    private let profileGenerator: ProfileGenerating
    var presenter: NudgePresenting?

    private(set) var settings: AppSettings
    /// Injectable clock (tests use a fake one).
    var now: () -> Date
    /// Tests turn this off so nothing is written to Application Support.
    var persistenceEnabled = true

    let tracker: TripTracker
    let drift: DriftEngine

    private var timer: Timer?

    // MARK: Session bookkeeping
    private var sessionActive = false
    private var sessionID = UUID()
    /// Identity the current classification belongs to.
    private var classifiedIdentity: String?
    private var identitySince: Date?
    private var screenCheckedThisVisit = false
    private var lastScreenCheckAt: Date?
    private var inFlight: Set<String> = []
    private var pendingTasks: [Task<Void, Never>] = []
    /// Bumped by user corrections so slower classifier results cannot overwrite them.
    private var correctionEpoch = 0
    private var questionContext: WindowContext?
    private var driftByPlace: [String: TimeInterval] = [:]
    private var totalDriftSeconds: TimeInterval = 0
    private var sessionParkingLot: [String] = []
    private var watchedPaths: [String] = []

    // MARK: Pauses
    private var sensorIdle = false
    private var screenLocked = false
    private var inMeeting = false
    private enum ManualPause: Equatable {
        case none
        case onBreak(until: Date)
        case offline(until: Date)
    }
    private var manualPause = ManualPause.none

    static let sensorLogCap = 500
    static let logCap = 1000
    /// Re-check long stays in changing apps with a screenshot this often.
    static let changingAppRecheckSeconds: TimeInterval = 7 * 60
    static let changingAppBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.mail", "com.microsoft.Outlook",
    ]

    init(state: SessionState, sensors: SensorHubProtocol, classifier: Classifying,
         profileGenerator: ProfileGenerating, settings: AppSettings = AppSettings.load(),
         now: @escaping () -> Date = Date.init) {
        self.state = state
        self.sensors = sensors
        self.classifier = classifier
        self.profileGenerator = profileGenerator
        self.settings = settings
        self.now = now
        self.tracker = TripTracker(now: now)
        self.drift = DriftEngine(settings: settings)
    }

    // MARK: - Lifecycle

    /// Start sensors and the 1 s tick timer.
    func start() {
        sensors.onEvent = { [weak self] event in self?.handle(event) }
        sensors.start()
        if state.current == nil, let ctx = sensors.currentContext { state.current = ctx }
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick(now: self.now())
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sensors.stop()
    }

    func reloadSettings(_ s: AppSettings) {
        settings = s
        drift.settings = s
    }

    var isSessionActive: Bool { sessionActive }

    // MARK: - Sensor events

    func handle(_ event: SensorEvent) {
        switch event {
        case .contextChanged(let ctx):
            state.sensorLog.append(ctx)
            if state.sensorLog.count > Self.sensorLogCap {
                state.sensorLog.removeFirst(state.sensorLog.count - Self.sensorLogCap)
            }
            let changed = state.current?.identity != ctx.identity
            state.current = ctx
            if changed {
                identitySince = now()
                screenCheckedThisVisit = false
                lastScreenCheckAt = nil
            }
            guard sessionActive, !isPaused else { return }
            if changed || classifiedIdentity != ctx.identity {
                classify(ctx, allowScreen: false)
            } else if state.currentClassification?.label == .onTask {
                // Same context re-reported (for example a title tick): keep the anchor fresh.
                _ = tracker.observe(ctx, label: .onTask)
            }
            refreshStatus()

        case .copyDetected(_, let at):
            tracker.recordCopy(at: at)

        case .fileChanged(_, let at):
            tracker.recordOutputChange(at: at)

        case .idle(let v):
            sensorIdle = v
            refreshStatus()
        case .screenLocked(let v):
            screenLocked = v
            refreshStatus()
        case .meeting(let v):
            inMeeting = v
            refreshStatus()
        }
    }

    // MARK: - Classification

    private func classify(_ ctx: WindowContext, allowScreen: Bool) {
        guard let profile = state.profile else { return }
        if !allowScreen {
            if let fast = fastPath(ctx, profile: profile) {
                apply(fast, to: ctx)
                return
            }
            // Provisional: nothing is decided yet. The trip tracker sees the real result.
            state.currentClassification = Classification(
                label: .unsure, role: .other, confidence: 0, reason: "Checking...", source: .fallback, at: now())
            classifiedIdentity = ctx.identity
        }
        let key = ctx.identity + (allowScreen ? "#screen" : "#text")
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let sid = sessionID
        let epoch = correctionEpoch
        let trip = tracker.summary()
        let classifier = self.classifier
        let task = Task { @MainActor [weak self] in
            let result = await classifier.classify(ctx, profile: profile, trip: trip, allowScreen: allowScreen)
            guard let self else { return }
            self.inFlight.remove(key)
            self.mirrorCounters()
            guard sid == self.sessionID, self.sessionActive else { return }
            if epoch == self.correctionEpoch, self.state.current?.identity == ctx.identity {
                self.apply(result, to: ctx)
            } else {
                self.log(result, ctx: ctx)
            }
        }
        pendingTasks.append(task)
        if pendingTasks.count > 32 { pendingTasks.removeFirst(pendingTasks.count - 32) }
    }

    /// Corrections first, then learned research trips, then the classifier's quick path.
    private func fastPath(_ ctx: WindowContext, profile: TaskProfile) -> Classification? {
        let quick = classifier.quickClassify(ctx, profile: profile)
        if let q = quick, q.source == .correction { return q }
        let learned = Classification(label: .supporting, role: .source, confidence: 0.8,
                                     reason: "Part of an earlier research trip", source: .cache, at: now())
        if tracker.isConfirmedIdentity(ctx), quick?.label != .onTask { return learned }
        if let q = quick, q.label != .unsure, q.label != .neutral { return q }
        if tracker.isConfirmedDomain(ctx) { return learned }
        if let q = quick, q.label != .unsure { return q }
        return nil
    }

    private func apply(_ c: Classification, to ctx: WindowContext) {
        state.currentClassification = c
        classifiedIdentity = ctx.identity
        let change = tracker.observe(ctx, label: c.label)
        switch change {
        case .anchored, .tripEnded:
            if let anchor = tracker.lastAnchor { state.anchorName = TripTracker.describe(anchor) }
            let paths = tracker.anchorDocumentPaths
            if paths != watchedPaths {
                watchedPaths = paths
                sensors.watchFiles(paths)
            }
        default: break
        }
        if c.label.isWork { tracker.noteWork(at: now()) }
        if c.label != .unsure, questionContext?.identity == ctx.identity, c.source == .correction {
            drift.questionAnswered(identity: ctx.identity)
        }
        mirrorCounters()
        refreshStatus()
        log(c, ctx: ctx)
    }

    private func log(_ c: Classification, ctx: WindowContext) {
        // Private windows are never written with their title or URL, and stored URLs keep
        // only scheme, host and path (no query string or fragment, which can hold tokens).
        let entry = LogEntry(at: c.at, appName: ctx.appName,
                             title: ctx.isPrivateWindow ? "(private window)" : ctx.cleanTitle,
                             url: ctx.isPrivateWindow ? nil : ctx.url.flatMap(Self.redactedURL),
                             label: c.label, source: c.source, reason: c.reason, status: state.status)
        state.log.append(entry)
        if state.log.count > Self.logCap { state.log.removeFirst(state.log.count - Self.logCap) }
        if persistenceEnabled { LocalStore.appendLine(entry, to: "session-log.jsonl", maxBytes: 5_000_000) }
    }

    /// scheme://host/path, dropping user info, query and fragment.
    static func redactedURL(_ raw: String) -> String? {
        guard var comps = URLComponents(string: raw), comps.host != nil else { return nil }
        comps.user = nil
        comps.password = nil
        comps.query = nil
        comps.fragment = nil
        return comps.string
    }

    private func mirrorCounters() {
        if state.textCalls != classifier.textCalls { state.textCalls = classifier.textCalls }
        if state.visionCalls != classifier.visionCalls { state.visionCalls = classifier.visionCalls }
    }

    /// Wait for in-flight classifications (tests).
    func settle() async {
        while !pendingTasks.isEmpty {
            let tasks = pendingTasks
            pendingTasks = []
            for t in tasks { await t.value }
        }
    }

    // MARK: - Status and pauses

    private var isPaused: Bool {
        manualPause != .none || effectiveIdle || screenLocked || inMeeting
    }

    /// No input does not mean away: watching a video produces no input either.
    /// Idle only pauses tracking when the current context is not off task.
    private var effectiveIdle: Bool {
        sensorIdle && currentLabel != .offTask
    }

    private var currentLabel: ActivityLabel? {
        guard let cur = state.current, cur.identity == classifiedIdentity else { return nil }
        return state.currentClassification?.label
    }

    private func computeStatus(at t: Date) -> (FocusStatus, String?) {
        guard sessionActive else { return (.idle, nil) }
        switch manualPause {
        case .onBreak: return (.onBreak, "Break")
        case .offline: return (.paused, "Working offline")
        case .none: break
        }
        if screenLocked { return (.paused, "Screen locked") }
        if inMeeting { return (.paused, "In a meeting") }
        if effectiveIdle { return (.paused, "Idle") }
        switch tracker.state(for: currentLabel, graceSeconds: settings.graceMinutes * 60, at: t) {
        case .anchored: return (.anchored, nil)
        case .excursion: return (.excursion, nil)
        case .drifting: return (.drifting, nil)
        }
    }

    private func refreshStatus() {
        let t = now()
        let (status, reason) = computeStatus(at: t)
        let old = state.status
        let wasPaused = old == .paused || old == .onBreak
        let nowPaused = status == .paused || status == .onBreak
        if nowPaused && !wasPaused {
            // Pauses never count as drift.
            drift.endEpisode(clearWindow: false)
            presenter?.dismissAll()
        }
        if old != status { state.status = status }
        if state.pauseReason != reason { state.pauseReason = reason }
        if wasPaused && !nowPaused && sessionActive {
            // Restart the grace clock and the dwell clock; catch up on what changed meanwhile.
            tracker.noteWork(at: t)
            identitySince = t
            if let cur = state.current, cur.identity != classifiedIdentity {
                classify(cur, allowScreen: false)
            }
        }
    }

    // MARK: - Tick

    /// Called every second by the timer. Tests call it directly with a fake clock.
    func tick(now t: Date) {
        guard sessionActive, let profile = state.profile else { return }

        switch manualPause {
        case .onBreak(let until) where t >= until:
            manualPause = .none
            state.pausedUntil = nil
            refreshStatus()
            presenter?.present(DriftCopy.breakOver(profile: profile, returnTo: returnTargetName()))
        case .offline(let until) where t >= until:
            manualPause = .none
            state.pausedUntil = nil
            refreshStatus()
        default:
            refreshStatus()
        }

        let status = state.status
        if status == .paused || status == .onBreak {
            if case .offline = manualPause { state.focusedSeconds += 1 }
            let rolling = drift.rollingDriftSeconds(at: t)
            if state.driftSeconds != rolling { state.driftSeconds = rolling }
            return
        }

        let label = currentLabel
        if label?.isWork == true {
            state.focusedSeconds += 1
            tracker.noteWork(at: t)
        }
        if status == .drifting {
            drift.recordDriftSecond(at: t)
            totalDriftSeconds += 1
            driftByPlace[DriftCopy.place(state.current), default: 0] += 1
        }
        let rolling = drift.rollingDriftSeconds(at: t)
        if state.driftSeconds != rolling { state.driftSeconds = rolling }

        screenshotChecks(at: t)

        let dwell = identitySince.map { t.timeIntervalSince($0) } ?? 0
        let actions = drift.evaluate(now: t, status: status, label: label,
                                     identity: state.current?.identity, identityDwell: dwell)
        for action in actions { perform(action, profile: profile, at: t) }
    }

    private func screenshotChecks(at t: Date) {
        guard settings.screenshotsEnabled, let ctx = state.current, ctx.identity == classifiedIdentity,
              let c = state.currentClassification, let since = identitySince else { return }
        let dwell = t.timeIntervalSince(since)
        if c.label == .unsure, !screenCheckedThisVisit, dwell >= settings.screenshotDwellSeconds,
           !inFlight.contains(ctx.identity + "#text") {
            screenCheckedThisVisit = true
            lastScreenCheckAt = t
            classify(ctx, allowScreen: true)
            return
        }
        let changing = ctx.isBrowser || Self.changingAppBundleIDs.contains(ctx.bundleID)
        if changing, c.label != .onTask, dwell >= Self.changingAppRecheckSeconds,
           t.timeIntervalSince(lastScreenCheckAt ?? since) >= Self.changingAppRecheckSeconds {
            lastScreenCheckAt = t
            classify(ctx, allowScreen: true)
        }
    }

    private func perform(_ action: DriftAction, profile: TaskProfile, at t: Date) {
        switch action {
        case .nudge(let level, let startsEpisode):
            if startsEpisode { state.driftCount += 1 }
            let nudge = DriftCopy.nudge(level: level, profile: profile, place: DriftCopy.place(state.current),
                                        returnTo: returnTargetName(), progressCount: state.progressCount, now: t)
            presenter?.present(nudge)
        case .ask:
            questionContext = state.current
            presenter?.ask(DriftCopy.question(place: DriftCopy.place(state.current), profile: profile))
        case .dismissAll:
            questionContext = nil
            presenter?.dismissAll()
        }
    }

    /// Name of where "Back to X" goes: the anchor's app (or web app), else the first profile output.
    private func returnTargetName() -> String? {
        if let anchor = tracker.lastAnchor {
            return anchor.domain.map(TripTracker.prettyDomain) ?? anchor.appName
        }
        guard let first = state.profile?.outputs.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty,
              !first.lowercased().hasPrefix("title:") else { return nil }
        if EngineLauncher.isBundleID(first) {
            return first.split(separator: ".").last.map(String.init)
        }
        if EngineLauncher.isDomainLike(first) {
            let host = first.replacingOccurrences(of: "https://", with: "")
                .split(separator: "/").first.map(String.init) ?? first
            return TripTracker.prettyDomain(host)
        }
        return first
    }

    // MARK: - SessionControlling

    func generateProfile(goal: String, deadline: Date?) async throws -> TaskProfile {
        try await profileGenerator.generateProfile(goal: goal, deadline: deadline)
    }

    func startSession(_ profile: TaskProfile) {
        classifier.resetSession()
        let t = now()
        sessionID = UUID()
        sessionActive = true
        tracker.reset()
        drift.reset()
        classifiedIdentity = nil
        screenCheckedThisVisit = false
        lastScreenCheckAt = nil
        inFlight = []
        correctionEpoch = 0
        questionContext = nil
        driftByPlace = [:]
        totalDriftSeconds = 0
        sessionParkingLot = []
        manualPause = .none
        watchedPaths = []
        sensors.watchFiles([])

        state.profile = profile
        state.sessionStart = t
        state.currentClassification = nil
        state.log = []
        state.focusedSeconds = 0
        state.driftSeconds = 0
        state.driftCount = 0
        state.progressCount = 0
        state.pausedUntil = nil
        state.pauseReason = nil
        state.anchorName = nil
        state.lastRecap = nil
        state.lastError = nil
        mirrorCounters()
        if persistenceEnabled { LocalStore.save(profile, to: "last-profile.json") }

        identitySince = t
        if let ctx = sensors.currentContext ?? state.current {
            state.current = ctx
            if !isPaused { classify(ctx, allowScreen: false) }
        }
        refreshStatus()
    }

    @discardableResult
    func endSession() -> SessionRecap? {
        guard sessionActive, let profile = state.profile else { return nil }
        let t = now()
        let top = driftByPlace.sorted { $0.value > $1.value }.prefix(5)
            .map { RecapItem(name: $0.key, seconds: $0.value) }
        let recap = SessionRecap(
            goal: profile.goal,
            duration: state.sessionStart.map { t.timeIntervalSince($0) } ?? 0,
            focusedSeconds: state.focusedSeconds,
            driftSeconds: totalDriftSeconds,
            driftCount: state.driftCount,
            topDrift: Array(top),
            progressCount: state.progressCount,
            targetCount: profile.targetCount,
            parkingLot: sessionParkingLot)
        sessionActive = false
        sessionID = UUID()
        manualPause = .none
        questionContext = nil
        drift.reset()
        sensors.watchFiles([])
        watchedPaths = []
        state.lastRecap = recap
        state.profile = nil
        state.sessionStart = nil
        state.pausedUntil = nil
        state.pauseReason = nil
        state.status = .idle
        presenter?.dismissAll()
        if persistenceEnabled { LocalStore.appendLine(recap, to: "recaps.jsonl") }
        return recap
    }

    func takeBreak(minutes: Int) {
        guard sessionActive else { return }
        let until = now().addingTimeInterval(TimeInterval(max(1, minutes)) * 60)
        manualPause = .onBreak(until: until)
        state.pausedUntil = until
        refreshStatus()
    }

    func workOffline(minutes: Int) {
        guard sessionActive else { return }
        let until = now().addingTimeInterval(TimeInterval(max(1, minutes)) * 60)
        manualPause = .offline(until: until)
        state.pausedUntil = until
        refreshStatus()
    }

    func resume() {
        guard manualPause != .none else { return }
        manualPause = .none
        state.pausedUntil = nil
        refreshStatus()
    }

    func markCurrentRelevant() {
        guard let ctx = state.current else { return }
        correct(ctx, isRelevant: true)
    }

    func markCurrentOffTask() {
        guard let ctx = state.current else { return }
        correct(ctx, isRelevant: false)
    }

    func answerQuestion(isRelevant: Bool) {
        guard let ctx = questionContext ?? state.current else { return }
        questionContext = nil
        correct(ctx, isRelevant: isRelevant)
    }

    private func correct(_ ctx: WindowContext, isRelevant: Bool) {
        guard sessionActive, let profile = state.profile else { return }
        let label: ActivityLabel = isRelevant ? .supporting : .offTask
        classifier.recordCorrection(ctx, label: label, profile: profile)
        correctionEpoch += 1
        drift.questionAnswered(identity: ctx.identity)
        if questionContext?.identity == ctx.identity { questionContext = nil }
        if isRelevant {
            drift.endEpisode(clearWindow: true)
            presenter?.dismissAll()
        }
        guard state.current?.identity == ctx.identity else { return }
        let c = Classification(label: label, role: isRelevant ? .source : .other, confidence: 1,
                               reason: isRelevant ? "You said this is part of the task" : "You said this is off task",
                               source: .correction, at: now())
        apply(c, to: ctx)
        if isRelevant { state.driftSeconds = drift.rollingDriftSeconds(at: now()) }
    }

    func snooze(minutes: Int) {
        drift.snooze(until: now().addingTimeInterval(TimeInterval(max(1, minutes)) * 60))
        presenter?.dismissAll()
    }

    func backToWork() {
        if let anchor = tracker.lastAnchor {
            EngineLauncher.open(anchor: anchor)
        } else if let first = state.profile?.outputs.first {
            EngineLauncher.open(outputPattern: first)
        }
        presenter?.dismissAll()
    }

    func incrementProgress(by delta: Int) {
        state.progressCount = max(0, state.progressCount + delta)
    }

    func addParkingLot(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if sessionActive { sessionParkingLot.append(trimmed) }
        guard persistenceEnabled else { return }
        var items = LocalStore.load([ParkingItem].self, from: "parking-lot.json") ?? []
        items.append(ParkingItem(at: now(), text: trimmed))
        LocalStore.save(items, to: "parking-lot.json")
    }
}
