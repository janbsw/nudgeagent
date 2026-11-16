import Foundation
import CoreGraphics
import ScreenCaptureKit

enum ScreenInspectorError: Error, LocalizedError {
    case permissionDenied
    case windowNotFound
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "NudgeAgent needs Screen Recording permission to look at the current window. You can turn it on in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .windowNotFound:
            return "Could not find the window to look at. It may be minimized, on another space, or hidden from screen capture."
        case .captureFailed(let detail):
            return "Taking a snapshot of the window did not work (\(detail))."
        }
    }
}

/// Captures the focused window of an app, runs on-device OCR and returns text plus a small JPEG.
/// Screenshots and text live in memory only. Safe to call from the main actor with `await`:
/// all heavy work runs on a background task, shared state is guarded by a lock.
final class ScreenInspector: ScreenInspecting, @unchecked Sendable {
    private let settingsProvider: () -> AppSettings
    private let lock = NSLock()
    /// Last fingerprint per context identity, with insertion order for eviction.
    private var fingerprints: [String: [UInt8]] = [:]
    private var fingerprintOrder: [String] = []
    private let maxFingerprints = 200
    /// Longest side of the captured image in pixels.
    private let maxCaptureSide = 2000.0

    init(settingsProvider: @escaping () -> AppSettings) {
        self.settingsProvider = settingsProvider
    }

    // MARK: ScreenInspecting

    func isExcluded(_ ctx: WindowContext) -> Bool {
        ScreenExclusions.isExcluded(ctx, userBundleIDs: settingsProvider().excludedBundleIDs)
    }

    func observe(_ ctx: WindowContext) async throws -> WindowObservation {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenInspectorError.permissionDenied }

        let image = try await captureWindow(pid: ctx.pid, title: ctx.windowTitle)

        // CPU heavy part off the caller's actor.
        let processed = try await Task.detached(priority: .userInitiated) { () throws -> (String, Data?, [UInt8]?) in
            let text = try ScreenImageProcessing.recognizeText(in: image)
            let jpeg = ScreenImageProcessing.jpegData(image)
            let fp = ScreenImageProcessing.fingerprint(image)
            return (text, jpeg, fp)
        }.value

        let unchanged = updateFingerprint(processed.2, for: ctx.identity)
        return WindowObservation(text: processed.0, imageJPEG: processed.1, unchanged: unchanged)
    }

    /// Drop all remembered fingerprints (for example on a new session).
    func resetFingerprints() {
        lock.lock(); defer { lock.unlock() }
        fingerprints.removeAll()
        fingerprintOrder.removeAll()
    }

    // MARK: Capture

    private func captureWindow(pid: Int32, title: String) async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw ScreenInspectorError.permissionDenied }
            throw ScreenInspectorError.captureFailed(error.localizedDescription)
        }

        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
                && $0.frame.width >= 1 && $0.frame.height >= 1
        }
        let window = candidates.first(where: { !title.isEmpty && $0.title == title })
            ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        guard let window else { throw ScreenInspectorError.windowNotFound }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        var scale = Double(filter.pointPixelScale)
        if scale <= 0 { scale = Self.displayScale(for: window.frame, displays: content.displays) }

        let pxW = Double(window.frame.width) * scale
        let pxH = Double(window.frame.height) * scale
        let cap = min(1.0, maxCaptureSide / max(pxW, pxH))

        let config = SCStreamConfiguration()
        config.width = max(1, Int((pxW * cap).rounded()))
        config.height = max(1, Int((pxH * cap).rounded()))
        config.showsCursor = false
        config.scalesToFit = true
        config.capturesAudio = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenInspectorError.captureFailed(error.localizedDescription)
        }
    }

    /// Backing scale of the display that holds most of `frame` (CG global coordinates).
    private static func displayScale(for frame: CGRect, displays: [SCDisplay]) -> Double {
        let best = displays.max { a, b in
            let ia = a.frame.intersection(frame), ib = b.frame.intersection(frame)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
        guard let display = best, let mode = CGDisplayCopyDisplayMode(display.displayID), mode.width > 0 else {
            return 2.0
        }
        return max(1.0, Double(mode.pixelWidth) / Double(mode.width))
    }

    // MARK: Fingerprints

    /// Stores the new fingerprint and returns true if it is nearly identical to the previous one.
    private func updateFingerprint(_ fp: [UInt8]?, for identity: String) -> Bool {
        guard let fp else { return false }
        lock.lock(); defer { lock.unlock() }
        var unchanged = false
        if let previous = fingerprints[identity] {
            unchanged = ScreenImageProcessing.meanAbsoluteDifference(previous, fp) < ScreenImageProcessing.unchangedThreshold
            fingerprintOrder.removeAll { $0 == identity }
        }
        fingerprints[identity] = fp
        fingerprintOrder.append(identity)
        while fingerprintOrder.count > maxFingerprints {
            fingerprints.removeValue(forKey: fingerprintOrder.removeFirst())
        }
        return unchanged
    }
}
