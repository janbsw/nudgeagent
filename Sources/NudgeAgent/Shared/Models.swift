import Foundation

// Shared data types. Every module depends on this file; keep it stable.

// MARK: - What is on screen

/// One moment of "what is in front of the user". Produced by the sensor layer.
struct WindowContext: Codable, Equatable, Hashable {
    var timestamp: Date
    var bundleID: String
    var appName: String
    var pid: Int32
    /// Raw focused window title.
    var windowTitle: String
    /// Title with noise removed (unread counts like "(3) ", trailing app names, bullets).
    var cleanTitle: String
    var url: String?
    /// Host without "www.", e.g. "linkedin.com".
    var domain: String?
    /// URL path without query, e.g. "/in/jane-doe".
    var urlPath: String?
    /// Search query parsed from the URL (q=, query=, search_query=, p=), if any.
    var searchQuery: String?
    /// File path of the focused document window (AXDocument), if any.
    var documentPath: String?
    var isBrowser: Bool
    var isPrivateWindow: Bool

    /// Stable identity used for caching and "same context" checks.
    var identity: String {
        if let domain {
            return "\(bundleID)|\(domain)\(urlPath ?? "")|\(cleanTitle)"
        }
        return "\(bundleID)|\(cleanTitle)"
    }

    /// Short human readable description, used in logs, trip summaries and nudges.
    var shortDescription: String {
        var parts = [appName]
        if let domain { parts.append(domain + (urlPath ?? "")) }
        if !cleanTitle.isEmpty { parts.append("\"\(cleanTitle)\"") }
        if let q = searchQuery, !q.isEmpty { parts.append("query: \"\(q)\"") }
        return parts.joined(separator: " ")
    }
}

/// Events emitted by the sensor layer. Always delivered on the main thread.
enum SensorEvent {
    /// The focused context changed and stayed for the dwell time (a few seconds).
    case contextChanged(WindowContext)
    /// Something was copied to the clipboard while `bundleID` was frontmost. Content is never read.
    case copyDetected(bundleID: String, at: Date)
    /// A watched file was modified.
    case fileChanged(path: String, at: Date)
    /// User became idle (true) or active again (false).
    case idle(Bool)
    /// Screen locked (true) or unlocked (false), includes sleep.
    case screenLocked(Bool)
    /// A meeting (Zoom, Teams, Meet, Webex, FaceTime) started (true) or ended (false).
    case meeting(Bool)
}

// MARK: - Goal and task profile

enum TaskType: String, Codable, CaseIterable {
    case create, research, process, communicate, learn
}

/// What the goal turns into. Patterns are interpreted by the classifier. Supported forms:
/// - app name, e.g. "PowerPoint"
/// - bundle id, e.g. "com.microsoft.Powerpoint"
/// - domain with optional path glob, e.g. "linkedin.com/in/*", "apollo.io"
/// - "title:<keyword>", matched case-insensitively against the window title
struct TaskProfile: Codable, Equatable {
    var goal: String
    var type: TaskType
    /// Where results land (the deck, the CRM, a spreadsheet).
    var outputs: [String]
    /// Where input comes from.
    var sources: [String]
    /// Supporting tools.
    var tools: [String]
    /// What counts as drift for this goal.
    var drift: [String]
    /// Topics and keywords that make something relevant (used for search queries and titles).
    var keywords: [String]
    /// One or two sentences describing what working on this goal looks like.
    var summary: String
    var targetCount: Int?
    var targetUnit: String?
    var deadline: Date?
}

// MARK: - Classification

enum ActivityLabel: String, Codable {
    case onTask = "on_task"
    case supporting
    case neutral
    case offTask = "off_task"
    case unsure

    var isWork: Bool { self == .onTask || self == .supporting }
}

enum ActivityRole: String, Codable {
    case output, source, tool, other
}

enum ClassificationSource: String, Codable {
    case correction, rule, builtin, cache, textLLM, screenText, vision, fallback
}

struct Classification: Codable, Equatable {
    var label: ActivityLabel
    var role: ActivityRole
    /// 0...1
    var confidence: Double
    var reason: String
    var source: ClassificationSource
    var at: Date = Date()
}

/// Context about the current trip away from the output, given to the classifier.
struct TripSummary: Codable {
    /// Description of the output context the trip started from, if any.
    var startedFrom: String?
    var minutesAway: Double
    /// Hops on this trip, oldest first, as short descriptions with their label.
    var hops: [String]
    var copiesDuringTrip: Int
    /// The output changed within the last few minutes.
    var outputChangedRecently: Bool

    static let empty = TripSummary(startedFrom: nil, minutesAway: 0, hops: [], copiesDuringTrip: 0, outputChangedRecently: false)
}

// MARK: - Screen inspection

struct WindowObservation {
    /// Text recognized on device from the window screenshot.
    var text: String
    /// Downscaled JPEG of the window (in memory only, never written to disk).
    var imageJPEG: Data?
    /// True if the window looks nearly identical to the last observation of the same context.
    var unchanged: Bool
}

// MARK: - Session state and nudges

enum FocusStatus: String, Codable {
    case idle       // no session running
    case anchored   // in the output or a confirmed source or tool
    case excursion  // away, plausibly working
    case drifting   // away and the trip lost its connection to the goal
    case paused     // meeting, idle, locked, working offline
    case onBreak
}

struct LogEntry: Codable, Identifiable {
    var id = UUID()
    var at: Date
    var appName: String
    var title: String
    var url: String?
    var label: ActivityLabel?
    var source: ClassificationSource?
    var reason: String
    var status: FocusStatus
}

enum NudgeLevel: Int, Codable, Comparable {
    case ambient = 1      // menu bar icon only
    case notification = 2 // system notification
    case card = 3         // floating card with "Back to X"
    case strong = 4       // bigger card plus sound (opt-in)

    static func < (a: NudgeLevel, b: NudgeLevel) -> Bool { a.rawValue < b.rawValue }
}

struct Nudge {
    var level: NudgeLevel
    var title: String
    var message: String
    /// Name of where "Back to X" goes, e.g. "PowerPoint". nil hides the button.
    var backTargetName: String?
}

struct RecapItem: Codable, Identifiable {
    var id = UUID()
    var name: String
    var seconds: TimeInterval
}

struct SessionRecap: Codable {
    var goal: String
    var duration: TimeInterval
    var focusedSeconds: TimeInterval
    var driftSeconds: TimeInterval
    var driftCount: Int
    var topDrift: [RecapItem]
    var progressCount: Int
    var targetCount: Int?
    var parkingLot: [String]
}

struct ParkingItem: Codable, Identifiable {
    var id = UUID()
    var at: Date
    var text: String
}
