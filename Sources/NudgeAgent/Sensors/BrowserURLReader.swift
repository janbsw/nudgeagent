import Foundation
import ApplicationServices

/// Reads the active tab URL of the frontmost browser window without a browser extension.
/// Chromium and Safari via AppleScript, Firefox and Zen via the Accessibility address bar.
///
/// NOT thread-safe: SensorHub owns one instance and only calls it from its serial browser queue.
final class BrowserURLReader {

    struct Result {
        /// Active tab URL, nil if unknown or no window.
        var url: String?
        /// True if the browser itself reports a private/incognito window.
        var isPrivate: Bool
        /// False if the read failed (permission, timeout). Callers may keep a previous URL.
        var succeeded: Bool

        static let failed = Result(url: nil, isPrivate: false, succeeded: false)
    }

    /// Bundle ids where Automation was denied (-1743), with the time of the denial.
    private var deniedAt: [String: Date] = [:]
    /// Errors already logged, as "bundleID|code", so each is logged once.
    private var loggedErrors: Set<String> = []
    private var compiled: [String: NSAppleScript] = [:]
    /// Bundle ids where the script with `mode` failed to compile; use the plain one.
    private var modeUnsupported: Set<String> = []
    /// Retry a denied browser after this long, in case the user granted Automation meanwhile.
    private let deniedRetryInterval: TimeInterval = 300

    /// Cached Firefox address bar per pid.
    private var firefoxCache: [pid_t: (window: AXUIElement, field: AXUIElement)] = [:]

    func read(bundleID: String, pid: pid_t) -> Result {
        guard let kind = SensorContextBuilder.browserKind(bundleID) else { return .failed }
        switch kind {
        case .chromium(let hasMode):
            return readAppleScript(bundleID: bundleID, safari: false, wantMode: hasMode)
        case .safari:
            return readAppleScript(bundleID: bundleID, safari: true, wantMode: false)
        case .firefox:
            return readFirefox(pid: pid)
        }
    }

    // MARK: - AppleScript

    private func source(bundleID: String, safari: Bool, withMode: Bool) -> String {
        let tab = safari ? "current tab" : "active tab"
        let modeLines = withMode ? """
                    try
                        set m to (mode of front window) as text
                    end try
        """ : ""
        return """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                if (count of windows) = 0 then return ""
                set u to ""
                set m to ""
                try
                    set u to (URL of \(tab) of front window) as text
                end try
        \(modeLines)
                return u & linefeed & m
            end tell
        end timeout
        """
    }

    private func script(bundleID: String, safari: Bool, wantMode: Bool) -> NSAppleScript? {
        let withMode = wantMode && !modeUnsupported.contains(bundleID)
        let key = bundleID + (withMode ? "|mode" : "")
        if let s = compiled[key] { return s }
        guard let s = NSAppleScript(source: source(bundleID: bundleID, safari: safari, withMode: withMode)) else { return nil }
        var err: NSDictionary?
        if !s.compileAndReturnError(&err) {
            if withMode {
                modeUnsupported.insert(bundleID)
                return script(bundleID: bundleID, safari: safari, wantMode: false)
            }
            logOnce(bundleID, code: (err?[NSAppleScript.errorNumber] as? Int) ?? 0,
                    "BrowserURLReader: could not compile script for \(bundleID): \(err ?? [:])")
            return nil
        }
        compiled[key] = s
        return s
    }

    private func readAppleScript(bundleID: String, safari: Bool, wantMode: Bool) -> Result {
        if let at = deniedAt[bundleID] {
            if Date().timeIntervalSince(at) < deniedRetryInterval { return .failed }
            deniedAt[bundleID] = nil
        }
        guard let s = script(bundleID: bundleID, safari: safari, wantMode: wantMode) else { return .failed }

        var err: NSDictionary?
        let out = s.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            switch code {
            case -1743:
                deniedAt[bundleID] = Date()
                logOnce(bundleID, code: code,
                        "BrowserURLReader: Automation not authorized for \(bundleID) (-1743). Falling back to window title. Grant it in System Settings > Privacy & Security > Automation.")
            default:
                // -600 not running, -1712 timeout, -1728 no such object, -1719 etc.
                logOnce(bundleID, code: code, "BrowserURLReader: AppleScript error \(code) for \(bundleID): \(err[NSAppleScript.errorMessage] ?? "")")
            }
            return .failed
        }

        let text = out.stringValue ?? ""
        let parts = text.components(separatedBy: "\n")
        let url = parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let mode = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
        return Result(url: url.isEmpty || url == "missing value" ? nil : url,
                      isPrivate: mode == "incognito",
                      succeeded: true)
    }

    private func logOnce(_ bundleID: String, code: Int, _ message: String) {
        let key = "\(bundleID)|\(code)"
        guard !loggedErrors.contains(key) else { return }
        loggedErrors.insert(key)
        NSLog("%@", message)
    }

    // MARK: - Firefox via Accessibility

    private let maxDepth = 20
    private let maxNodes = 3000

    private func readFirefox(pid: pid_t) -> Result {
        guard AXIsProcessTrusted() else { return .failed }
        guard let window = AXSensorUtil.focusedWindow(pid: pid) else {
            return Result(url: nil, isPrivate: false, succeeded: true)
        }

        // Re-validate the cached field: same window and the value is still readable.
        if let cached = firefoxCache[pid], CFEqual(cached.window, window),
           let value = AXSensorUtil.string(cached.field, kAXValueAttribute) {
            return Result(url: SensorContextBuilder.normalizeAddressBarValue(value), isPrivate: false, succeeded: true)
        }
        firefoxCache[pid] = nil

        guard let field = findAddressBar(in: window) else {
            return Result(url: nil, isPrivate: false, succeeded: false)
        }
        firefoxCache[pid] = (window, field)
        if firefoxCache.count > 8 {
            firefoxCache = firefoxCache.filter { $0.key == pid }
        }
        let value = AXSensorUtil.string(field, kAXValueAttribute) ?? ""
        return Result(url: SensorContextBuilder.normalizeAddressBarValue(value), isPrivate: false, succeeded: true)
    }

    /// Breadth-first walk of the window, bounded by depth and node count. Skips web content.
    private func findAddressBar(in window: AXUIElement) -> AXUIElement? {
        let attrs = [kAXRoleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        var visited = 0
        var valueCandidate: AXUIElement?

        while index < queue.count, visited < maxNodes {
            let (el, depth) = queue[index]
            index += 1
            visited += 1

            var valuesRef: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef) == .success,
                  let values = valuesRef as? [Any], values.count == 4 else { continue }

            let role = values[0] as? String ?? ""
            let identifier = (values[1] as? String ?? "").lowercased()
            let description = (values[2] as? String ?? "").lowercased()

            if role == "AXWebArea" { continue } // page content: huge, never the address bar

            if role == kAXTextFieldRole || role == kAXComboBoxRole {
                let hint = identifier + " " + description
                if hint.contains("urlbar") || hint.contains("address") || hint.contains("search or enter address") {
                    return el
                }
                if valueCandidate == nil,
                   let v = AXSensorUtil.string(el, kAXValueAttribute),
                   let normalized = SensorContextBuilder.normalizeAddressBarValue(v),
                   normalized.contains(".") || normalized.hasPrefix("about:") {
                    valueCandidate = el
                }
            }

            if depth < maxDepth, let kids = values[3] as? [AXUIElement] {
                for kid in kids { queue.append((kid, depth + 1)) }
            }
        }
        return valueCandidate
    }
}
