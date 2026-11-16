import Foundation

// Interfaces between modules. Implementations live in their own folders:
//   Sensors/       SensorHub: SensorHubProtocol
//   Intelligence/  LLMClient, Classifier: Classifying, ProfileGenerator: ProfileGenerating
//   Vision/        ScreenInspector: ScreenInspecting
//   UI/            NudgeUI: NudgePresenting, menu bar, windows
//   Engine/        SessionCoordinator: SessionControlling, TripTracker, DriftEngine
// Everything is used from the main thread unless marked async.

protocol SensorHubProtocol: AnyObject {
    /// Called on the main thread.
    var onEvent: ((SensorEvent) -> Void)? { get set }
    /// Latest context, updated even before the dwell time has passed.
    var currentContext: WindowContext? { get }
    func start()
    func stop()
    /// Replace the set of files watched for modifications (polled every few seconds).
    func watchFiles(_ paths: [String])
}

protocol ScreenInspecting: AnyObject {
    /// True if this context must never be captured (password managers, banking, messengers,
    /// private windows, user exclusions).
    func isExcluded(_ ctx: WindowContext) -> Bool
    /// Screenshot the focused window of `ctx.pid`, run on-device OCR, return text plus a
    /// downscaled JPEG. Throws if permission is missing or capture fails.
    func observe(_ ctx: WindowContext) async throws -> WindowObservation
}

protocol Classifying: AnyObject {
    /// Fast path: corrections, profile rules, built-in rules, cache. Never touches the network.
    /// Returns nil when undecided.
    func quickClassify(_ ctx: WindowContext, profile: TaskProfile) -> Classification?
    /// Full cascade: quick path, then text LLM, then (if `allowScreen`) screenshot + OCR + LLM,
    /// then vision LLM if OCR text is too thin. Never throws; returns label `.unsure` on failure.
    func classify(_ ctx: WindowContext, profile: TaskProfile, trip: TripSummary, allowScreen: Bool) async -> Classification
    /// The user said this context is (or is not) part of the task. Persisted per goal.
    func recordCorrection(_ ctx: WindowContext, label: ActivityLabel, profile: TaskProfile)
    /// Clear the session cache (new goal).
    func resetSession()
    /// Counters for the debug window.
    var textCalls: Int { get }
    var visionCalls: Int { get }
}

protocol ProfileGenerating: AnyObject {
    /// Turn a goal sentence into a task profile with one LLM call.
    func generateProfile(goal: String, deadline: Date?) async throws -> TaskProfile
}

protocol NudgePresenting: AnyObject {
    func present(_ nudge: Nudge)
    /// One-tap yes/no question ("Is this for the lead search?").
    /// The answer goes to SessionControlling.answerQuestion(isRelevant:).
    func ask(_ question: String)
    func dismissAll()
}

/// What the UI can ask the engine to do. Implemented by SessionCoordinator.
protocol SessionControlling: AnyObject {
    func generateProfile(goal: String, deadline: Date?) async throws -> TaskProfile
    func startSession(_ profile: TaskProfile)
    @discardableResult func endSession() -> SessionRecap?
    func takeBreak(minutes: Int)
    func workOffline(minutes: Int)
    /// End a break or offline pause early.
    func resume()
    /// "This is relevant" on a nudge or the menu.
    func markCurrentRelevant()
    func markCurrentOffTask()
    func snooze(minutes: Int)
    /// Bring the output app, document or URL to the front.
    func backToWork()
    func incrementProgress(by delta: Int)
    func addParkingLot(_ text: String)
    func answerQuestion(isRelevant: Bool)
}
