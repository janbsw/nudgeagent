import Foundation

/// What the drift engine wants the coordinator to do after a tick.
enum DriftAction: Equatable {
    /// Show a nudge at this level. `startsEpisode` is true for the first nudge of a drift episode.
    case nudge(NudgeLevel, startsEpisode: Bool)
    /// Ask the one-tap question about this context identity.
    case ask(identity: String)
    /// Close all nudges (the user returned to the work).
    case dismissAll
}

/// Nudge timing (DESIGN.md sections 6 and 7). Pure logic: the caller passes `now` on every call.
final class DriftEngine {
    var settings: AppSettings

    /// One timestamp per drifting second inside the rolling window.
    private var driftTicks: [Date] = []
    private(set) var episodeActive = false
    private(set) var lastNudgeAt: Date?
    private(set) var lastLevel: NudgeLevel?
    private(set) var snoozedUntil: Date?
    private var lastDriftTickAt: Date?

    /// Identities already asked about this session.
    private(set) var askedIdentities: Set<String> = []
    /// The open question, if any: escalation past a notification waits for it.
    private(set) var openQuestion: (identity: String, at: Date)?

    /// Seconds from a notification to the first card.
    static let notificationToCard: TimeInterval = 60
    /// Seconds from a card to the next step (strong or another card).
    static let cardToNext: TimeInterval = 90
    /// Seconds between repeated nudges at the top of the ladder.
    static let repeatInterval: TimeInterval = 3 * 60
    /// Minimum seconds between any two nudges.
    static let minimumGap: TimeInterval = 60
    /// How long an unanswered question holds back escalation.
    static let questionHold: TimeInterval = 90
    /// An episode ends by itself after this long without drifting.
    static let episodeQuietEnd: TimeInterval = 3 * 60

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    func reset() {
        driftTicks = []
        episodeActive = false
        lastNudgeAt = nil
        lastLevel = nil
        snoozedUntil = nil
        lastDriftTickAt = nil
        askedIdentities = []
        openQuestion = nil
    }

    // MARK: - Inputs

    /// Count one drifting second.
    func recordDriftSecond(at now: Date) {
        driftTicks.append(now)
        lastDriftTickAt = now
        prune(now)
    }

    /// Rolling drift seconds within `settings.rollingWindowMinutes`.
    func rollingDriftSeconds(at now: Date) -> TimeInterval {
        prune(now)
        return TimeInterval(driftTicks.count)
    }

    func snooze(until date: Date) {
        snoozedUntil = date
    }

    func isSnoozed(at now: Date) -> Bool {
        if let s = snoozedUntil, now < s { return true }
        return false
    }

    /// End the current drift episode. On a real return to work the rolling window is cleared too,
    /// so the next drift starts fresh.
    func endEpisode(clearWindow: Bool) {
        episodeActive = false
        lastLevel = nil
        if clearWindow { driftTicks = [] }
    }

    /// The question about `identity` was answered (or became moot).
    func questionAnswered(identity: String?) {
        if identity == nil || openQuestion?.identity == identity { openQuestion = nil }
    }

    // MARK: - Evaluation

    /// Decide what to do this tick. Call after `recordDriftSecond` for drifting ticks.
    /// - Parameters:
    ///   - status: focus status for this tick (never paused or on break; the caller skips those).
    ///   - label: label of the current context.
    ///   - identity: identity of the current context.
    ///   - identityDwell: seconds the user has stayed in this identity.
    func evaluate(now: Date, status: FocusStatus, label: ActivityLabel?, identity: String?,
                  identityDwell: TimeInterval) -> [DriftAction] {
        var actions: [DriftAction] = []

        if let q = openQuestion, now.timeIntervalSince(q.at) >= Self.questionHold, q.identity != identity {
            openQuestion = nil
        }

        if status == .anchored {
            if episodeActive || openQuestion != nil {
                endEpisode(clearWindow: true)
                openQuestion = nil
                actions.append(.dismissAll)
            }
            return actions
        }

        if episodeActive, let last = lastDriftTickAt, now.timeIntervalSince(last) >= Self.episodeQuietEnd {
            endEpisode(clearWindow: false)
        }

        let snoozed = isSnoozed(at: now)

        // One-tap question: unsure, or neutral past grace, for a while in one place.
        if !snoozed, let identity, !askedIdentities.contains(identity),
           label == .unsure || (label == .neutral && status == .drifting),
           identityDwell >= settings.askAfterMinutes * 60 {
            askedIdentities.insert(identity)
            openQuestion = (identity, now)
            actions.append(.ask(identity: identity))
        }

        guard status == .drifting, !snoozed else { return actions }

        // Escalation cap while a question about this context is open.
        var cap = NudgeLevel.strong
        if let q = openQuestion, q.identity == identity, now.timeIntervalSince(q.at) < Self.questionHold {
            cap = .notification
        }

        if !episodeActive {
            guard rollingDriftSeconds(at: now) >= settings.driftThresholdMinutes * 60 else { return actions }
            if let l = lastNudgeAt, now.timeIntervalSince(l) < Self.minimumGap { return actions }
            episodeActive = true
            fire(.notification, at: now)
            actions.append(.nudge(.notification, startsEpisode: true))
            return actions
        }

        guard let last = lastNudgeAt, let level = lastLevel else { return actions }
        let since = now.timeIntervalSince(last)
        let next: NudgeLevel
        let wait: TimeInterval
        switch level {
        case .ambient, .notification:
            next = .card; wait = Self.notificationToCard
        case .card:
            next = settings.strongNudges ? .strong : .card
            wait = (lastLevelRepeats > 0) ? Self.repeatInterval : Self.cardToNext
        case .strong:
            next = .strong; wait = Self.repeatInterval
        }
        guard since >= max(wait, Self.minimumGap), next <= cap else { return actions }
        if next == level { lastLevelRepeats += 1 } else { lastLevelRepeats = 0 }
        fire(next, at: now)
        actions.append(.nudge(next, startsEpisode: false))
        return actions
    }

    private var lastLevelRepeats = 0

    private func fire(_ level: NudgeLevel, at now: Date) {
        if lastLevel == nil { lastLevelRepeats = 0 }
        lastLevel = level
        lastNudgeAt = now
    }

    private func prune(_ now: Date) {
        let cutoff = now.addingTimeInterval(-settings.rollingWindowMinutes * 60)
        if let i = driftTicks.firstIndex(where: { $0 > cutoff }) {
            if i > 0 { driftTicks.removeFirst(i) }
        } else {
            driftTicks.removeAll()
        }
    }
}

// MARK: - Copy

/// Friendly, specific nudge text. Never shaming.
enum DriftCopy {
    /// Shorten a goal to a readable phrase: first clause, at most ~48 characters, cut at a word.
    static func shortGoal(_ goal: String, limit: Int = 48) -> String {
        var g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        for sep in [". ", "; ", " - "] {
            if let r = g.range(of: sep) { g = String(g[..<r.lowerBound]) }
        }
        if g.hasSuffix(".") { g.removeLast() }
        guard g.count > limit else { return g }
        let cut = g.prefix(limit)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "..." }
        return String(cut) + "..."
    }

    /// "2h 10m left", "25m left", nil if no deadline or already passed.
    static func timeLeft(until deadline: Date?, now: Date) -> String? {
        guard let deadline else { return nil }
        let secs = deadline.timeIntervalSince(now)
        guard secs >= 60 else { return nil }
        let mins = Int(secs / 60)
        let h = mins / 60, m = mins % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m left" : "\(h)h left" }
        return "\(m)m left"
    }

    /// "6/20 leads", nil without a target.
    static func progress(_ count: Int, profile: TaskProfile) -> String? {
        guard let target = profile.targetCount, target > 0 else { return nil }
        let unit = profile.targetUnit.map { " \($0)" } ?? ""
        return "\(count)/\(target)\(unit)"
    }

    /// Where the user is, in plain words: "YouTube", "Slack".
    static func place(_ ctx: WindowContext?) -> String {
        guard let ctx else { return "something else" }
        if let d = ctx.domain { return TripTracker.prettyDomain(d) }
        return ctx.appName
    }

    static func nudge(level: NudgeLevel, profile: TaskProfile, place: String, returnTo: String?,
                      progressCount: Int, now: Date) -> Nudge {
        let goal = shortGoal(profile.goal)
        let target = returnTo ?? "\"\(goal)\""
        var tail: [String] = []
        if let left = timeLeft(until: profile.deadline, now: now) { tail.append(left) }
        if let p = progress(progressCount, profile: profile) { tail.append(p + " so far") }
        let tailText = tail.isEmpty ? "" : " " + tail.joined(separator: ", ") + "."

        let title: String
        let message: String
        switch level {
        case .ambient, .notification:
            title = "Quick check-in"
            message = "Looks like you drifted to \(place). Back to \(target)?\(tailText)"
        case .card:
            title = "Still with \"\(goal)\"?"
            message = "You've spent a while on \(place). One click takes you back to \(target).\(tailText)"
        case .strong:
            title = "Time to head back?"
            message = "\(place) has had your attention for a bit. \"\(goal)\" is waiting.\(tailText)"
        }
        return Nudge(level: level, title: title, message: message, backTargetName: returnTo)
    }

    static func question(place: String, profile: TaskProfile) -> String {
        "Is \(place) part of \"\(shortGoal(profile.goal))\"?"
    }

    static func breakOver(profile: TaskProfile, returnTo: String?) -> Nudge {
        Nudge(level: .notification, title: "Break's over",
              message: "Break's over. Ready to get back to \(shortGoal(profile.goal))?",
              backTargetName: returnTo)
    }
}
