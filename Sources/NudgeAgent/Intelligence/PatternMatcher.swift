import Foundation

/// Matches task profile patterns against a window context. Supported forms (see TaskProfile):
/// - app name, e.g. "PowerPoint" (case-insensitive equals or contained in the app name)
/// - bundle id, e.g. "com.microsoft.Powerpoint"
/// - domain with optional path glob, e.g. "linkedin.com/in/*", "apollo.io"
/// - "title:<keyword>", case-insensitive substring of the window title
/// Free-text descriptions (e.g. "company websites") simply never match.
enum PatternMatcher {
    /// Returns a specificity score if `pattern` matches `ctx`, nil otherwise. Higher is more specific.
    static func specificity(of pattern: String, in ctx: WindowContext) -> Int? {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }

        // title:<keyword>
        if p.lowercased().hasPrefix("title:") {
            let keyword = p.dropFirst("title:".count).trimmingCharacters(in: .whitespaces).lowercased()
            guard keyword.count >= 2 else { return nil }
            let title = (ctx.windowTitle + " " + ctx.cleanTitle).lowercased()
            return title.contains(keyword) ? 30 + keyword.count : nil
        }

        var best: Int?
        func consider(_ score: Int?) {
            if let score, score > (best ?? Int.min) { best = score }
        }

        let hasSpace = p.contains(" ")
        if !hasSpace && p.contains(".") {
            // Bundle id (exact, case-insensitive). Note "app.attio.com" may be either form.
            if !p.contains("/"), p.caseInsensitiveCompare(ctx.bundleID) == .orderedSame {
                consider(90 + p.count)
            }
            consider(domainSpecificity(p, ctx))
        }

        // App name.
        let name = ctx.appName.lowercased()
        let lp = p.lowercased()
        if !name.isEmpty {
            if name == lp {
                consider(60 + lp.count)
            } else if lp.count >= 3, !lp.contains("/"), containsWord(name, lp) {
                consider(50 + lp.count)
            }
        }
        return best
    }

    /// Best (most specific) matching pattern in a list, with its score.
    static func bestMatch(in patterns: [String], ctx: WindowContext) -> (pattern: String, score: Int)? {
        var result: (String, Int)?
        for p in patterns {
            if let s = specificity(of: p, in: ctx), s > (result?.1 ?? Int.min) { result = (p, s) }
        }
        return result
    }

    /// Host part of a domain pattern, lowercased, without scheme or "www.". nil if not domain-like.
    static func host(ofDomainPattern pattern: String) -> String? {
        let (host, _) = splitDomainPattern(pattern)
        guard let host, host.contains("."), !host.contains(" ") else { return nil }
        return host
    }

    // MARK: Domain matching

    static func splitDomainPattern(_ pattern: String) -> (host: String?, path: String?) {
        var p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where p.hasPrefix(scheme) { p.removeFirst(scheme.count) }
        if p.hasPrefix("*.") { p.removeFirst(2) }
        if p.hasPrefix("www.") { p.removeFirst(4) }
        if let q = p.firstIndex(where: { $0 == "?" || $0 == "#" }) { p = String(p[..<q]) }
        guard !p.isEmpty else { return (nil, nil) }
        if let slash = p.firstIndex(of: "/") {
            let host = String(p[..<slash])
            let path = String(p[slash...])
            return (host.isEmpty ? nil : host, (path == "/" || path == "/*") ? nil : path)
        }
        return (p, nil)
    }

    static func hostMatches(_ host: String, _ domain: String) -> Bool {
        domain == host || domain.hasSuffix("." + host)
    }

    private static func domainSpecificity(_ pattern: String, _ ctx: WindowContext) -> Int? {
        guard let rawDomain = ctx.domain?.lowercased(), !rawDomain.isEmpty else { return nil }
        let domain = rawDomain.hasPrefix("www.") ? String(rawDomain.dropFirst(4)) : rawDomain
        let (hostOpt, pathPattern) = splitDomainPattern(pattern)
        guard let host = hostOpt, host.contains("."), hostMatches(host, domain) else { return nil }
        var score = 100 + host.count
        if let pathPattern {
            let path = (ctx.urlPath?.isEmpty == false ? ctx.urlPath! : "/").lowercased()
            guard pathMatches(pattern: pathPattern, path: path) else { return nil }
            score += 50 + pathPattern.filter { $0 != "*" }.count * 2
        }
        return score
    }

    /// Glob match for URL paths. "*" matches any run of characters. A pattern without a
    /// trailing "*" matches the path itself and anything below it ("/feed" matches "/feed/123").
    /// "/in/*" also matches "/in" and "/in/".
    static func pathMatches(pattern: String, path: String) -> Bool {
        var pat = pattern
        if !pat.hasPrefix("/") { pat = "/" + pat }
        var p = path.isEmpty ? "/" : path
        if !p.hasPrefix("/") { p = "/" + p }

        if !pat.contains("*") {
            let base = pat.hasSuffix("/") ? String(pat.dropLast()) : pat
            return p == base || p == base + "/" || p.hasPrefix(base + "/")
        }
        if pat.hasSuffix("/*") {
            let base = String(pat.dropLast(2))
            if !base.contains("*"), p == base || p == base + "/" { return true }
        }
        return glob(Array(pat), Array(p))
    }

    private static func glob(_ pat: [Character], _ str: [Character]) -> Bool {
        var pi = 0, si = 0
        var starPi = -1, starSi = 0
        while si < str.count {
            if pi < pat.count, pat[pi] != "*", pat[pi] == str[si] {
                pi += 1; si += 1
            } else if pi < pat.count, pat[pi] == "*" {
                starPi = pi; starSi = si; pi += 1
            } else if starPi >= 0 {
                pi = starPi + 1; starSi += 1; si = starSi
            } else {
                return false
            }
        }
        while pi < pat.count, pat[pi] == "*" { pi += 1 }
        return pi == pat.count
    }

    /// True if `needle` occurs in `haystack` at word boundaries ("excel" in "microsoft excel",
    /// but not "mail" in "gmail").
    static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, options: [.caseInsensitive], range: searchRange) {
            let beforeOK = r.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: r.lowerBound)].isLetter
            let afterOK = r.upperBound == haystack.endIndex || !haystack[r.upperBound].isLetter
            if beforeOK && afterOK { return true }
            searchRange = haystack.index(after: r.lowerBound)..<haystack.endIndex
        }
        return false
    }

    // MARK: Normalization (used by ProfileGenerator)

    /// Cleans a list of patterns: trims, lowercases domain patterns, strips scheme and "www.",
    /// drops empties and duplicates (case-insensitive).
    static func normalize(_ patterns: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in patterns {
            var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if p.lowercased().hasPrefix("title:") {
                let kw = p.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
                guard !kw.isEmpty else { continue }
                p = "title:" + kw
            } else if looksLikeDomainPattern(p) {
                let (host, path) = splitDomainPattern(p)
                guard let host else { continue }
                p = host + (path ?? "")
            }
            let key = p.lowercased()
            if seen.insert(key).inserted { out.append(p) }
        }
        return out
    }

    /// Domain-like: no spaces, contains a dot, and either has a path/scheme or ends in a
    /// plausible TLD. Bundle ids ("com.apple.mail") are left untouched.
    static func looksLikeDomainPattern(_ p: String) -> Bool {
        let s = p.trimmingCharacters(in: .whitespaces)
        guard !s.contains(" "), s.contains(".") else { return false }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") { return true }
        if s.contains("/") { return true }
        let reverseDNSPrefixes = ["com.", "org.", "net.", "io.", "app.", "de.", "ru.", "us.", "dev.", "co."]
        let labels = s.split(separator: ".")
        // Reverse-DNS bundle ids have 3+ labels, a TLD first and usually no TLD last.
        let commonTLDs: Set<String> = ["com", "io", "de", "org", "net", "app", "ai", "co", "dev", "eu", "uk", "ch", "at"]
        if labels.count >= 3, reverseDNSPrefixes.contains(where: { lower.hasPrefix($0) }),
           !commonTLDs.contains(String(labels.last!).lowercased()) {
            return false
        }
        return true
    }
}
