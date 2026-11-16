import Foundation

/// Pure functions that turn raw sensor readings into a `WindowContext`.
/// No AppKit, no side effects: safe to call from any thread and easy to test.
enum SensorContextBuilder {

    // MARK: - Browsers

    enum BrowserKind {
        /// Chromium family, read via AppleScript. `hasMode` = supports `mode of front window` (incognito).
        case chromium(hasMode: Bool)
        /// Safari, read via AppleScript.
        case safari
        /// Firefox family, read via the Accessibility address bar.
        case firefox
    }

    static let browsers: [String: BrowserKind] = [
        "com.google.Chrome": .chromium(hasMode: true),
        "com.google.Chrome.canary": .chromium(hasMode: true),
        "com.google.Chrome.beta": .chromium(hasMode: true),
        "com.google.Chrome.dev": .chromium(hasMode: true),
        "com.brave.Browser": .chromium(hasMode: true),
        "com.brave.Browser.beta": .chromium(hasMode: true),
        "com.brave.Browser.nightly": .chromium(hasMode: true),
        "com.microsoft.edgemac": .chromium(hasMode: true),
        "com.microsoft.edgemac.Beta": .chromium(hasMode: true),
        "com.microsoft.edgemac.Dev": .chromium(hasMode: true),
        "com.microsoft.edgemac.Canary": .chromium(hasMode: true),
        "company.thebrowser.Browser": .chromium(hasMode: false),
        "com.vivaldi.Vivaldi": .chromium(hasMode: false),
        "com.operasoftware.Opera": .chromium(hasMode: false),
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "org.mozilla.firefox": .firefox,
        "org.mozilla.firefoxdeveloperedition": .firefox,
        "org.mozilla.nightly": .firefox,
        "app.zen-browser.zen": .firefox,
    ]

    static func browserKind(_ bundleID: String) -> BrowserKind? { browsers[bundleID] }
    static func isBrowser(_ bundleID: String) -> Bool { browsers[bundleID] != nil }

    // MARK: - Build

    static func makeContext(
        timestamp: Date,
        bundleID: String,
        appName: String,
        pid: Int32,
        windowTitle: String,
        url: String?,
        documentPath: String?,
        browserSaysPrivate: Bool
    ) -> WindowContext {
        let parsed = url.flatMap(parseURL)
        return WindowContext(
            timestamp: timestamp,
            bundleID: bundleID,
            appName: appName,
            pid: pid,
            windowTitle: windowTitle,
            cleanTitle: cleanTitle(windowTitle, appName: appName, bundleID: bundleID),
            url: url,
            domain: parsed?.domain,
            urlPath: parsed?.path,
            searchQuery: parsed?.query,
            documentPath: documentPath,
            isBrowser: isBrowser(bundleID),
            isPrivateWindow: browserSaysPrivate || titleLooksPrivate(windowTitle)
        )
    }

    // MARK: - Private windows

    static func titleLooksPrivate(_ title: String) -> Bool {
        if title.hasSuffix("Private Browsing") { return true }
        return title.contains("Incognito") || title.contains("InPrivate")
    }

    // MARK: - Title cleaning

    private static let dashes = "[-\u{2013}\u{2014}|]"

    private static let leadingPatterns: [NSRegularExpression] = [
        #"^\(\d+\+?\)\s*"#,                       // "(3) "
        #"^\[\d+\+?\]\s*"#,                       // "[3] "
        "^[\u{2022}\u{25CF}\u{25CB}\u{2B24}*]\\s*", // bullets, unsaved markers
        #"^Audio playing\s*-\s*"#,
        #"^Camera (and microphone )?recording\s*-\s*"#,
        #"^Microphone recording\s*-\s*"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let browserSuffix: NSRegularExpression? = {
        let names = [
            "Google Chrome( Canary| Beta| Dev)?",
            "Microsoft\u{200B}?\\s?Edge( Beta| Dev| Canary)?",
            "Brave( Browser)?",
            "Vivaldi",
            "Opera",
            "Safari( Technology Preview)?",
            "Mozilla Firefox( Private Browsing)?",
            "Firefox( Developer Edition| Nightly)?( Private Browsing)?",
            "Zen Browser( Private Browsing)?",
            "Zen( Private Browsing)?",
            "Chromium",
            "Arc",
        ].joined(separator: "|")
        // Optional trailing profile name after Chrome-style suffixes: "Page - Google Chrome - Jan".
        let pattern = "\\s+\(dashes)\\s+(\(names))(\\s+\(dashes)\\s+[^-\u{2013}\u{2014}|]{1,40})?$"
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let firefoxPrivateSuffix = try? NSRegularExpression(pattern: #"\s*Private Browsing$"#)
    private static let edgeMorePages = try? NSRegularExpression(pattern: #"\s+and \d+ more pages?(\s+-\s+[^-]{1,40})?$"#)

    /// Strips unread counts, bullets, "Audio playing - " and trailing browser or app names.
    static func cleanTitle(_ raw: String, appName: String = "", bundleID: String = "") -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Leading noise, repeated because prefixes stack ("(2) \u{2022} Inbox").
        var changed = true
        while changed {
            changed = false
            for re in leadingPatterns {
                let next = replace(re, in: s)
                if next != s { s = next; changed = true }
            }
        }

        if let re = browserSuffix { s = replace(re, in: s) }
        if let re = firefoxPrivateSuffix { s = replace(re, in: s) }
        if bundleID.hasPrefix("com.microsoft.edgemac"), let re = edgeMorePages { s = replace(re, in: s) }

        // Generic "<title> - <App Name>".
        if !appName.isEmpty {
            for sep in [" - ", " \u{2013} ", " \u{2014} ", " | "] {
                let suffix = sep + appName
                if s.count > suffix.count, s.hasSuffix(suffix) {
                    s = String(s.dropLast(suffix.count))
                    break
                }
            }
        }

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ re: NSRegularExpression, in s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    // MARK: - URL parsing

    struct ParsedURL: Equatable {
        var domain: String?
        var path: String?
        var query: String?
    }

    static let searchParams = ["q", "query", "search_query", "p", "k", "keywords", "text"]

    static func parseURL(_ string: String) -> ParsedURL? {
        guard let comps = URLComponents(string: string)
            ?? string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URLComponents.init(string:))
        else { return nil }

        var domain = comps.host?.lowercased()
        if let d = domain, d.hasPrefix("www.") { domain = String(d.dropFirst(4)) }
        if domain?.isEmpty == true { domain = nil }

        var path: String? = comps.path
        if path?.isEmpty == true { path = nil }
        if domain == nil { path = nil }

        var query: String?
        if let items = comps.queryItems {
            for name in searchParams {
                if let v = items.first(where: { $0.name == name })?.value?
                    .replacingOccurrences(of: "+", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                    query = v
                    break
                }
            }
        }
        return ParsedURL(domain: domain, path: path, query: query)
    }

    /// Normalizes an address bar value (Firefox may hide the scheme). Returns nil for search text
    /// or anything that does not look like a URL.
    static func normalizeAddressBarValue(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, !v.contains(" ") else { return nil }
        if v.contains("://") { return v }
        for prefix in ["about:", "view-source:", "data:", "file:", "moz-extension:", "chrome:"] where v.hasPrefix(prefix) {
            return v
        }
        let hostPart = v.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let host = hostPart.split(separator: ":").first.map(String.init) ?? ""
        guard !host.isEmpty else { return nil }
        let looksLikeHost = host == "localhost"
            || (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
                && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        return looksLikeHost ? "https://" + v : nil
    }
}
