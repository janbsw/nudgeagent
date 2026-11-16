import Foundation
import Combine

/// Observable state the UI binds to. Only the Engine writes to it, always on the main thread.
final class SessionState: ObservableObject {
    @Published var profile: TaskProfile?
    @Published var status: FocusStatus = .idle
    @Published var current: WindowContext?
    @Published var currentClassification: Classification?
    /// Newest last. Capped by the engine.
    @Published var log: [LogEntry] = []
    @Published var sessionStart: Date?
    @Published var focusedSeconds: TimeInterval = 0
    @Published var driftSeconds: TimeInterval = 0
    @Published var driftCount: Int = 0
    @Published var progressCount: Int = 0
    @Published var pausedUntil: Date?
    @Published var pauseReason: String?
    /// Name of the output the user returns to, e.g. "PowerPoint: Q3 Pitch.pptx".
    @Published var anchorName: String?
    @Published var textCalls: Int = 0
    @Published var visionCalls: Int = 0
    @Published var lastError: String?
    @Published var lastRecap: SessionRecap?
    /// Every context change seen by sensors, including before a session starts (debug window).
    @Published var sensorLog: [WindowContext] = []
}

/// User settings, stored in UserDefaults.
struct AppSettings: Codable, Equatable {
    /// Bump `currentDefaultsVersion` when timing defaults change; older saved settings are then reset.
    static let currentDefaultsVersion = 2
    var defaultsVersion: Int = AppSettings.currentDefaultsVersion
    /// Minutes of off-task time within the rolling window before nudging.
    var driftThresholdMinutes: Double = 1.5
    /// Grace period for every excursion.
    var graceMinutes: Double = 1.5
    var rollingWindowMinutes: Double = 10
    /// Minutes in one unclear context before the one-tap question.
    var askAfterMinutes: Double = 1.5
    /// Minimum seconds in a context before a screenshot is taken.
    var screenshotDwellSeconds: Double = 30
    var screenshotsEnabled: Bool = true
    /// Allow the strongest nudge level (bigger card plus sound).
    var strongNudges: Bool = false
    /// Seconds without input before counting as idle.
    var idleSeconds: Double = 120
    var textModel: String = "claude-haiku-5-5"
    var visionModel: String = "claude-haiku-5-5"
    /// Bundle ids never captured, in addition to built-in exclusions.
    var excludedBundleIDs: [String] = []

    private static let key = "NudgeAgent.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data),
              s.defaultsVersion >= currentDefaultsVersion else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.key)
        }
    }
}
