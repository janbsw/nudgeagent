import Foundation

/// Where the user is relative to the work (DESIGN.md section 3).
enum TripState: String {
    case anchored   // in the output (label on_task)
    case excursion  // away, plausibly working
    case drifting   // the trip lost its connection to the goal
}

/// One stop on a trip away from the anchor.
struct TripHop {
    var identity: String
    var domain: String?
    var description: String
    var label: ActivityLabel?
    var at: Date
}

/// Tracks trips away from the output: where they started, the hops, copies, and whether the
/// output changed. Confirms trips that turned into work and remembers their places for the session.
/// Pure logic, no side effects; `now` is injectable for tests.
final class TripTracker {
    var now: () -> Date

    /// The last context classified as on_task.
    private(set) var lastAnchor: WindowContext?
    /// Start of the current trip, nil while anchored (or before anything was observed).
    private(set) var tripStart: Date?
    private(set) var hops: [TripHop] = []
    private(set) var copies: Int = 0
    /// Last time the output changed (watched file modified or anchor title changed).
    private(set) var lastOutputChange: Date?
    /// Last moment on this trip that was work (supporting label), or a pause ended.
    private(set) var graceAnchor: Date?

    /// Session-level places learned from confirmed research trips.
    private(set) var confirmedIdentities: Set<String> = []
    private(set) var confirmedDomains: Set<String> = []
    /// Number of trips confirmed as work this session.
    private(set) var confirmedTripCount = 0

    /// A trip that ended and may still be confirmed by an output change shortly after return.
    private struct EndedTrip {
        var start: Date
        var end: Date
        var hops: [TripHop]
        var copies: Int
    }
    private var pendingTrips: [EndedTrip] = []

    /// Seconds after return during which an output change confirms the trip.
    static let confirmWindowAfterReturn: TimeInterval = 10 * 60
    /// Trips shorter than this need only an output change, no copy.
    static let shortTripSeconds: TimeInterval = 5 * 60
    /// "Output changed recently" horizon.
    static let recentOutputSeconds: TimeInterval = 5 * 60

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func reset() {
        lastAnchor = nil
        tripStart = nil
        hops = []
        copies = 0
        lastOutputChange = nil
        graceAnchor = nil
        confirmedIdentities = []
        confirmedDomains = []
        confirmedTripCount = 0
        pendingTrips = []
    }

    var isOnTrip: Bool { tripStart != nil }

    /// Paths of documents that have been anchors this session (for file watching).
    private(set) var anchorDocumentPaths: [String] = []

    // MARK: - Input

    /// Result of feeding a classified context into the tracker.
    enum Change: Equatable {
        case none
        case anchored(newAnchor: Bool)
        case tripStarted
        /// A trip ended on return to the anchor. `confirmed` is true if it was confirmed right away.
        case tripEnded(confirmed: Bool)
    }

    /// Feed the current context with its (possibly provisional) classification.
    @discardableResult
    func observe(_ ctx: WindowContext, label: ActivityLabel?) -> Change {
        let t = now()
        if label == .onTask {
            var newAnchor = false
            if let anchor = lastAnchor, Self.sameDocument(anchor, ctx), anchor.cleanTitle != ctx.cleanTitle {
                // The anchor's title changed (saved, renamed, new slide): output activity.
                recordOutputChange(at: t)
            }
            if lastAnchor?.identity != ctx.identity { newAnchor = true }
            lastAnchor = ctx
            if let path = ctx.documentPath, !anchorDocumentPaths.contains(path) {
                anchorDocumentPaths.append(path)
            }
            if let start = tripStart {
                let ended = EndedTrip(start: start, end: t, hops: hops, copies: copies)
                tripStart = nil
                hops = []
                copies = 0
                graceAnchor = nil
                let confirmed = evaluate(ended, outputChangeAt: lastOutputChange)
                if !confirmed && !ended.hops.isEmpty { pendingTrips.append(ended) }
                return .tripEnded(confirmed: confirmed)
            }
            return .anchored(newAnchor: newAnchor)
        }

        var started = false
        if tripStart == nil {
            tripStart = t
            graceAnchor = t
            started = true
        }
        if let last = hops.last, last.identity == ctx.identity {
            hops[hops.count - 1].label = label ?? last.label
        } else {
            hops.append(TripHop(identity: ctx.identity, domain: ctx.domain, description: ctx.shortDescription, label: label, at: t))
            if hops.count > 40 { hops.removeFirst(hops.count - 40) }
        }
        return started ? .tripStarted : .none
    }

    /// A copy happened. Counts only during a trip.
    func recordCopy(at date: Date) {
        if tripStart != nil { copies += 1 }
    }

    /// A watched output file changed (or the anchor's title changed).
    func recordOutputChange(at date: Date) {
        lastOutputChange = date
        // Pending trips can be confirmed by this change.
        var remaining: [EndedTrip] = []
        for trip in pendingTrips {
            if date.timeIntervalSince(trip.end) > Self.confirmWindowAfterReturn { continue }
            if !evaluate(trip, outputChangeAt: date) { remaining.append(trip) }
        }
        pendingTrips = remaining
    }

    /// The current trip had a work moment (supporting label), or a pause ended: restart the grace clock.
    func noteWork(at date: Date) {
        if tripStart != nil { graceAnchor = date }
    }

    // MARK: - Queries

    /// Grace seconds used so far on this trip (time since the trip started or the last work moment).
    func secondsSinceGraceAnchor(at date: Date) -> TimeInterval {
        guard let g = graceAnchor ?? tripStart else { return 0 }
        return max(0, date.timeIntervalSince(g))
    }

    /// Map a label to a trip state given the grace period.
    func state(for label: ActivityLabel?, graceSeconds: TimeInterval, at date: Date) -> TripState {
        switch label {
        case .onTask?: return .anchored
        case .supporting?: return .excursion
        case .offTask?: return .drifting
        case .neutral?, .unsure?, nil:
            return secondsSinceGraceAnchor(at: date) < graceSeconds ? .excursion : .drifting
        }
    }

    /// True if this exact context was part of a confirmed research trip.
    func isConfirmedIdentity(_ ctx: WindowContext) -> Bool {
        confirmedIdentities.contains(ctx.identity)
    }

    /// True if this context's domain was part of a confirmed research trip.
    func isConfirmedDomain(_ ctx: WindowContext) -> Bool {
        guard let d = ctx.domain else { return false }
        return confirmedDomains.contains(d)
    }

    func summary() -> TripSummary {
        let t = now()
        let changed = lastOutputChange.map { t.timeIntervalSince($0) <= Self.recentOutputSeconds } ?? false
        guard let start = tripStart else {
            return TripSummary(startedFrom: lastAnchor.map(Self.describe), minutesAway: 0, hops: [],
                               copiesDuringTrip: 0, outputChangedRecently: changed)
        }
        return TripSummary(
            startedFrom: lastAnchor.map(Self.describe),
            minutesAway: (t.timeIntervalSince(start) / 60 * 10).rounded() / 10,
            hops: hops.suffix(12).map { "\($0.description) [\($0.label?.rawValue ?? "pending")]" },
            copiesDuringTrip: copies,
            outputChangedRecently: changed)
    }

    // MARK: - Helpers

    /// "Copy in a source, then the output changes" (within 10 min of return),
    /// or "the output changed and the trip was short".
    private func evaluate(_ trip: EndedTrip, outputChangeAt change: Date?) -> Bool {
        guard let change, change >= trip.start,
              change.timeIntervalSince(trip.end) <= Self.confirmWindowAfterReturn else { return false }
        let duration = trip.end.timeIntervalSince(trip.start)
        let confirmed = trip.copies > 0 || duration < Self.shortTripSeconds
        if confirmed { confirm(trip) }
        return confirmed
    }

    private func confirm(_ trip: EndedTrip) {
        confirmedTripCount += 1
        for hop in trip.hops where hop.label != .offTask {
            confirmedIdentities.insert(hop.identity)
            if let d = hop.domain { confirmedDomains.insert(d) }
        }
    }

    static func sameDocument(_ a: WindowContext, _ b: WindowContext) -> Bool {
        guard a.bundleID == b.bundleID else { return false }
        if let pa = a.documentPath, let pb = b.documentPath { return pa == pb }
        return a.domain == b.domain
    }

    /// "PowerPoint: Q3 Pitch.pptx" for apps, "Attio" for web apps.
    static func describe(_ ctx: WindowContext) -> String {
        if let domain = ctx.domain { return prettyDomain(domain) }
        if let path = ctx.documentPath {
            return "\(ctx.appName): \((path as NSString).lastPathComponent)"
        }
        return ctx.cleanTitle.isEmpty ? ctx.appName : "\(ctx.appName): \(ctx.cleanTitle)"
    }

    /// "app.attio.com" -> "Attio", "youtube.com" -> "YouTube", "docs.google.com" -> "Google Docs".
    static func prettyDomain(_ domain: String) -> String {
        let known: [String: String] = [
            "youtube.com": "YouTube", "m.youtube.com": "YouTube", "linkedin.com": "LinkedIn",
            "docs.google.com": "Google Docs", "sheets.google.com": "Google Sheets",
            "mail.google.com": "Gmail", "x.com": "X", "twitter.com": "X", "reddit.com": "Reddit",
            "github.com": "GitHub", "news.ycombinator.com": "Hacker News", "google.com": "Google",
        ]
        let d = domain.lowercased()
        if let k = known[d] { return k }
        let parts = d.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return domain }
        var name = parts[parts.count - 2]
        // co.uk, com.au style suffixes
        if ["co", "com", "org", "net", "ac"].contains(name), parts.count >= 3 { name = parts[parts.count - 3] }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
