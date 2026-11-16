import Foundation
import ApplicationServices

/// Small typed wrappers around the C Accessibility API.
enum AXSensorUtil {
    static let messagingTimeout: Float = 0.5

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(element, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func appElement(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = appElement(pid: pid)
        let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
        if let window { AXUIElementSetMessagingTimeout(window, messagingTimeout) }
        return window
    }
}

/// Reads the focused window's title and document path. Thread-safe (stateless); SensorHub
/// calls it on a background queue so a hung app cannot block the main thread.
enum AXWindowReader {
    struct Snapshot {
        var title: String
        var documentPath: String?
        /// False when Accessibility is not granted (title will be empty).
        var trusted: Bool
    }

    static func read(pid: pid_t) -> Snapshot {
        guard AXIsProcessTrusted() else {
            return Snapshot(title: "", documentPath: nil, trusted: false)
        }
        guard let window = AXSensorUtil.focusedWindow(pid: pid) else {
            return Snapshot(title: "", documentPath: nil, trusted: true)
        }
        let title = AXSensorUtil.string(window, kAXTitleAttribute) ?? ""
        var documentPath: String?
        if let doc = AXSensorUtil.string(window, kAXDocumentAttribute), !doc.isEmpty {
            if let url = URL(string: doc), url.isFileURL {
                documentPath = url.path
            } else if doc.hasPrefix("/") {
                documentPath = doc
            }
        }
        return Snapshot(title: title, documentPath: documentPath, trusted: true)
    }
}
