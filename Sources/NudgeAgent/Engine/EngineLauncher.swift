import AppKit

/// Brings the work back to the front: a URL, a document, or an app.
enum EngineLauncher {
    /// Return to an anchor context.
    static func open(anchor: WindowContext) {
        if let s = anchor.url, let url = URL(string: s), url.scheme != nil {
            NSWorkspace.shared.open(url)
            return
        }
        if let path = anchor.documentPath {
            let fileURL = URL(fileURLWithPath: path)
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: anchor.bundleID) {
                NSWorkspace.shared.open([fileURL], withApplicationAt: appURL,
                                        configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            } else {
                NSWorkspace.shared.open(fileURL)
            }
            return
        }
        activate(bundleID: anchor.bundleID)
    }

    /// Return to the first profile output when no anchor exists yet.
    /// Pattern forms: domain ("app.attio.com", "linkedin.com/in/*"), bundle id, or app name.
    static func open(outputPattern raw: String) {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, !pattern.lowercased().hasPrefix("title:") else { return }

        if isBundleID(pattern) {
            activate(bundleID: pattern)
            return
        }
        if isDomainLike(pattern) {
            var s = pattern.replacingOccurrences(of: "*", with: "")
            while s.hasSuffix("/") { s.removeLast() }
            if !s.hasPrefix("http") { s = "https://" + s }
            if let url = URL(string: s) { NSWorkspace.shared.open(url) }
            return
        }
        if let appURL = findApp(named: pattern) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    /// Activate a running app, or launch it.
    static func activate(bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
            return
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    /// "com.microsoft.Powerpoint": reverse DNS with at least three parts and no slash or space.
    static func isBundleID(_ s: String) -> Bool {
        guard !s.contains("/"), !s.contains(" ") else { return false }
        let parts = s.split(separator: ".")
        guard parts.count >= 3 else { return false }
        let first = parts[0].lowercased()
        return ["com", "org", "net", "io", "app", "de", "co", "dev"].contains(first)
            && !["com", "io", "app", "de", "org", "net", "co", "dev", "ai"].contains(parts.last!.lowercased())
    }

    /// "apollo.io", "app.attio.com", "linkedin.com/in/*".
    static func isDomainLike(_ s: String) -> Bool {
        guard !s.contains(" ") else { return false }
        let host = s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
        return true
    }

    /// Look for "<name>.app" (case-insensitive) in the usual folders.
    static func findApp(named name: String) -> URL? {
        let target = name.lowercased().hasSuffix(".app") ? name.lowercased() : name.lowercased() + ".app"
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        let fm = FileManager.default
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            if let hit = items.first(where: { $0.lowercased() == target }) {
                return URL(fileURLWithPath: dir).appendingPathComponent(hit)
            }
        }
        // Loose match, e.g. "PowerPoint" -> "Microsoft PowerPoint.app".
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            if let hit = items.first(where: { $0.lowercased().hasSuffix(".app") && $0.lowercased().contains(name.lowercased()) }) {
                return URL(fileURLWithPath: dir).appendingPathComponent(hit)
            }
        }
        return nil
    }
}
