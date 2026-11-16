import Foundation

/// Classifier cascade (DESIGN.md section 4):
/// corrections, profile rules, built-in rules, session cache, text LLM, screenshot (OCR text or vision).
/// Thread safe: all mutable state is guarded by a lock, so it can be called from the main thread
/// or from any task.
final class Classifier: Classifying, @unchecked Sendable {
    private let llm: LLMClient
    private let inspector: ScreenInspecting?
    private let settingsProvider: () -> AppSettings

    private let lock = NSLock()
    // Guarded by `lock`.
    private var cache: [String: ClassifierCacheEntry] = [:]
    private var screenResults: [String: Classification] = [:]
    private var inFlight: [String: (id: UUID, task: Task<Classification, Never>)] = [:]
    private var generation = 0
    private var corrections: [String: ClassifierCorrectionSet]
    private var textCallCount = 0
    private var visionCallCount = 0

    static let correctionsFile = "corrections.json"
    static let unsureThreshold = 0.55

    init(llm: LLMClient, inspector: ScreenInspecting?, settingsProvider: @escaping () -> AppSettings) {
        self.llm = llm
        self.inspector = inspector
        self.settingsProvider = settingsProvider
        self.corrections = LocalStore.load([String: ClassifierCorrectionSet].self, from: Self.correctionsFile) ?? [:]
    }

    var textCalls: Int { locked { textCallCount } }
    var visionCalls: Int { locked { visionCallCount } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Classifying

    func quickClassify(_ ctx: WindowContext, profile: TaskProfile) -> Classification? {
        let goalKey = Self.goalKey(profile.goal)

        // 1. User corrections.
        if let label = locked({ Self.lookupCorrection(corrections[goalKey], ctx: ctx) }) {
            return Self.correctionClassification(label)
        }
        // 2. Profile rules.
        if let c = Self.profileRule(ctx, profile: profile) { return c }
        // 3. Built-in rules.
        if let c = Self.builtinRule(ctx, profile: profile) { return c }
        // 4. Session cache.
        let key = Self.cacheKey(goalKey: goalKey, ctx: ctx)
        let now = Date()
        if let cached: Classification = locked({
            guard let entry = cache[key] else { return nil }
            if let expires = entry.expires, expires < now {
                cache[key] = nil
                return nil
            }
            return entry.classification
        }) {
            var c = cached
            if c.source != .correction { c.source = .cache }
            c.at = now
            return c
        }
        // Private windows never go to an LLM.
        if ctx.isPrivateWindow {
            return Classification(label: .neutral, role: .other, confidence: 0.5,
                                  reason: "private window", source: .builtin)
        }
        return nil
    }

    func classify(_ ctx: WindowContext, profile: TaskProfile, trip: TripSummary, allowScreen: Bool) async -> Classification {
        if let quick = quickClassify(ctx, profile: profile) { return quick }

        guard LLMClient.hasAPIKey else {
            return Self.unsure("No API key set", source: .fallback)
        }

        let key = Self.cacheKey(goalKey: Self.goalKey(profile.goal), ctx: ctx)
        let id = UUID()
        let (task, gen, isOwner): (Task<Classification, Never>, Int, Bool) = locked {
            if let existing = inFlight[key] { return (existing.task, generation, false) }
            let gen = generation
            let task = Task { [self] in
                await self.slowPath(ctx, profile: profile, trip: trip, allowScreen: allowScreen, key: key, generation: gen)
            }
            inFlight[key] = (id, task)
            return (task, gen, true)
        }

        let result = await task.value
        if isOwner {
            locked {
                if inFlight[key]?.id == id { inFlight[key] = nil }
                if generation == gen, result.label != .unsure {
                    let expires = Self.cacheTTL(for: ctx).map { Date().addingTimeInterval($0) }
                    cache[key] = ClassifierCacheEntry(classification: result, expires: expires)
                }
            }
        }
        return result
    }

    func recordCorrection(_ ctx: WindowContext, label: ActivityLabel, profile: TaskProfile) {
        let goalKey = Self.goalKey(profile.goal)
        let entry = ClassifierCorrectionEntry(label: label, at: Date())
        let snapshot: [String: ClassifierCorrectionSet] = locked {
            var set = corrections[goalKey] ?? ClassifierCorrectionSet()
            set.exact[ctx.identity] = entry
            set.general[Self.generalRecordKey(ctx)] = entry
            corrections[goalKey] = set

            let key = Self.cacheKey(goalKey: goalKey, ctx: ctx)
            cache[key] = ClassifierCacheEntry(classification: Self.correctionClassification(label), expires: nil)
            screenResults[key] = nil
            return corrections
        }
        LocalStore.save(snapshot, to: Self.correctionsFile)
    }

    func resetSession() {
        locked {
            cache.removeAll()
            screenResults.removeAll()
            inFlight.removeAll()
            generation += 1
        }
    }

    // MARK: - Slow path (LLM and screen)

    private func slowPath(_ ctx: WindowContext, profile: TaskProfile, trip: TripSummary,
                          allowScreen: Bool, key: String, generation gen: Int) async -> Classification {
        let settingsProvider = self.settingsProvider
        let settings = await MainActor.run { settingsProvider() }

        // 5. Text LLM.
        let textResult: Classification
        do {
            locked { textCallCount += 1 }
            textResult = try await askLLM(model: settings.textModel, ctx: ctx, profile: profile, trip: trip,
                                          screenText: nil, image: nil, source: .textLLM)
        } catch {
            return Self.unsure(Self.friendly(error), source: .fallback)
        }
        if textResult.label != .unsure { return textResult }

        // 6. Screenshot: OCR text, or the image for the vision model.
        guard allowScreen, settings.screenshotsEnabled, !ctx.isPrivateWindow, let inspector else { return textResult }
        let excluded = await MainActor.run { inspector.isExcluded(ctx) }
        guard !excluded else { return textResult }

        do {
            let observation = try await inspector.observe(ctx)
            if observation.unchanged, let previous = locked({ screenResults[key] }) {
                return previous
            }
            let result: Classification
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.meaningfulCharacterCount(text) >= 200 {
                locked { textCallCount += 1 }
                result = try await askLLM(model: settings.textModel, ctx: ctx, profile: profile, trip: trip,
                                          screenText: String(text.prefix(6000)), image: nil, source: .screenText)
            } else if let jpeg = observation.imageJPEG {
                locked { visionCallCount += 1 }
                result = try await askLLM(model: settings.visionModel, ctx: ctx, profile: profile, trip: trip,
                                          screenText: text.isEmpty ? nil : text, image: jpeg, source: .vision)
            } else {
                return Self.unsure("Not enough visible in the window to tell.", source: .fallback)
            }
            locked { if generation == gen { screenResults[key] = result } }
            return result
        } catch {
            return Self.unsure("Screen check failed: \(Self.friendly(error))", source: .fallback)
        }
    }

    private func askLLM(model: String, ctx: WindowContext, profile: TaskProfile, trip: TripSummary,
                        screenText: String?, image: Data?, source: ClassificationSource) async throws -> Classification {
        let answer: ClassifierLLMAnswer = try await llm.complete(
            model: model,
            system: Self.systemPrompt(profile: profile),
            user: Self.userPrompt(ctx: ctx, trip: trip, screenText: screenText, hasImage: image != nil),
            imageJPEG: image,
            schema: Self.answerSchema,
            maxTokens: 600)
        return Self.classification(from: answer, source: source)
    }

    // MARK: - Helpers (static, testable)

    static func unsure(_ reason: String, source: ClassificationSource) -> Classification {
        Classification(label: .unsure, role: .other, confidence: 0, reason: reason, source: source)
    }

    static func friendly(_ error: Error) -> String {
        if let e = error as? LLMError {
            if case .missingAPIKey = e { return "No API key set" }
            return e.errorDescription ?? "AI request failed"
        }
        if error is CancellationError { return "Cancelled" }
        return error.localizedDescription
    }

    static func classification(from a: ClassifierLLMAnswer, source: ClassificationSource) -> Classification {
        var label = ActivityLabel(rawValue: a.label) ?? .unsure
        let confidence = min(max(a.confidence, 0), 1)
        if confidence < unsureThreshold { label = .unsure }
        let reason = a.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return Classification(label: label,
                              role: ActivityRole(rawValue: a.role) ?? .other,
                              confidence: confidence,
                              reason: reason.isEmpty ? "No reason given." : reason,
                              source: source)
    }

    static func meaningfulCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.alphanumerics.contains($1) ? 1 : 0) }
    }

    // MARK: Keys

    static func goalKey(_ goal: String) -> String {
        let lowered = goal.lowercased()
        let mapped = String(lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        return mapped.split(separator: " ").joined(separator: " ")
    }

    static func cacheKey(goalKey: String, ctx: WindowContext) -> String {
        goalKey + "\n" + ctx.identity
    }

    static func normalizedDomain(_ domain: String) -> String {
        let d = domain.lowercased()
        return d.hasPrefix("www.") ? String(d.dropFirst(4)) : d
    }

    static func firstPathSegment(_ path: String?) -> String {
        guard let path else { return "" }
        return path.split(separator: "/", omittingEmptySubsequences: true).first.map { String($0).lowercased() } ?? ""
    }

    /// General key a correction is stored under.
    static func generalRecordKey(_ ctx: WindowContext) -> String {
        if let d = ctx.domain, !d.isEmpty {
            return "web|\(normalizedDomain(d))/\(firstPathSegment(ctx.urlPath))"
        }
        let title = ctx.cleanTitle.trimmingCharacters(in: .whitespaces).lowercased()
        let bundle = ctx.bundleID.lowercased()
        return title.isEmpty ? "app|\(bundle)" : "app|\(bundle)|\(title)"
    }

    /// General keys checked on lookup, most specific first.
    static func generalLookupKeys(_ ctx: WindowContext) -> [String] {
        if let d = ctx.domain, !d.isEmpty {
            return ["web|\(normalizedDomain(d))/\(firstPathSegment(ctx.urlPath))"]
        }
        let title = ctx.cleanTitle.trimmingCharacters(in: .whitespaces).lowercased()
        let bundle = ctx.bundleID.lowercased()
        var keys: [String] = []
        if !title.isEmpty { keys.append("app|\(bundle)|\(title)") }
        if !ctx.isBrowser { keys.append("app|\(bundle)") }
        return keys
    }

    static func lookupCorrection(_ set: ClassifierCorrectionSet?, ctx: WindowContext) -> ActivityLabel? {
        guard let set else { return nil }
        if let e = set.exact[ctx.identity] { return e.label }
        for k in generalLookupKeys(ctx) {
            if let e = set.general[k] { return e.label }
        }
        return nil
    }

    static func correctionClassification(_ label: ActivityLabel) -> Classification {
        let reason: String
        switch label {
        case .onTask, .supporting: reason = "You marked this as part of your task."
        case .offTask: reason = "You marked this as not part of your task."
        case .neutral: reason = "You marked this as neutral."
        case .unsure: reason = "You were not sure about this one."
        }
        return Classification(label: label, role: label == .onTask ? .output : .other,
                              confidence: 1.0, reason: reason, source: .correction)
    }

    // MARK: Profile rules

    static func profileRule(_ ctx: WindowContext, profile: TaskProfile) -> Classification? {
        typealias Candidate = (score: Int, label: ActivityLabel, role: ActivityRole, confidence: Double, reason: String)
        var best: Candidate?
        func consider(_ list: [String], _ make: (String) -> (ActivityLabel, ActivityRole, Double, String)) {
            guard let m = PatternMatcher.bestMatch(in: list, ctx: ctx) else { return }
            // Strictly greater: on ties the earlier list (output, source, tool, drift) wins.
            if m.score > (best?.score ?? Int.min) {
                let (l, r, c, reason) = make(m.pattern)
                best = (m.score, l, r, c, reason)
            }
        }
        let place = displayName(ctx)
        consider(profile.outputs) { _ in (.onTask, .output, 0.95, "You are in your output: \(place).") }
        consider(profile.sources) { _ in (.supporting, .source, 0.85, "\(place) is a source for your goal.") }
        consider(profile.tools) { _ in (.supporting, .tool, 0.85, "\(place) is one of your tools for this goal.") }
        consider(profile.drift) { p in (.offTask, .other, 0.85, "\(p) tends to pull you away from this goal.") }
        if let best {
            return Classification(label: best.label, role: best.role, confidence: best.confidence,
                                  reason: best.reason, source: .rule)
        }

        if let q = ctx.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty,
           let kw = matchingKeyword(query: q, keywords: profile.keywords) {
            return Classification(label: .supporting, role: .source, confidence: 0.8,
                                  reason: "Searching for \"\(kw)\" fits your goal.", source: .rule)
        }
        return nil
    }

    static func displayName(_ ctx: WindowContext) -> String {
        if let d = ctx.domain, !d.isEmpty { return normalizedDomain(d) }
        return ctx.appName.isEmpty ? ctx.bundleID : ctx.appName
    }

    static func matchingKeyword(query: String, keywords: [String]) -> String? {
        let q = query.lowercased()
        for k in keywords {
            let kl = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard kl.count >= 2 else { continue }
            if kl.count >= 4 ? q.contains(kl) : PatternMatcher.containsWord(q, kl) { return k }
            let words = kl.split(separator: " ").map(String.init).filter { $0.count >= 4 }
            if words.count >= 2, words.allSatisfy({ q.contains($0) }) { return k }
        }
        return nil
    }

    // MARK: Built-in rules

    static let neutralBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.settings",
        "app.nudgeagent.nudgeagent", "com.apple.loginwindow", "com.apple.dock", "com.apple.spotlight",
        "com.raycast.macos", "com.apple.keychainaccess", "com.apple.passwords",
        "com.bitwarden.desktop", "com.lastpass.lastpass", "org.keepassxc.keepassxc",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.screencaptureui",
    ]
    static let neutralBundlePrefixes = ["com.runningwithcrayons.alfred", "com.agilebits.", "com.1password.", "com.dashlane."]
    static let neutralAppNames: Set<String> = [
        "finder", "system settings", "system preferences", "nudgeagent", "nudge agent", "loginwindow",
        "dock", "spotlight", "raycast", "alfred", "1password", "bitwarden", "passwords", "keychain access",
        "lastpass", "dashlane", "keepassxc",
    ]

    struct DistractionSite {
        var host: String
        var aliases: [String]
        var frontPageOnly: Bool
    }

    static let distractionSites: [DistractionSite] = [
        .init(host: "youtube.com", aliases: ["youtube"], frontPageOnly: false),
        .init(host: "youtu.be", aliases: ["youtube"], frontPageOnly: false),
        .init(host: "netflix.com", aliases: ["netflix"], frontPageOnly: false),
        .init(host: "tiktok.com", aliases: ["tiktok"], frontPageOnly: false),
        .init(host: "instagram.com", aliases: ["instagram"], frontPageOnly: false),
        .init(host: "facebook.com", aliases: ["facebook"], frontPageOnly: false),
        .init(host: "x.com", aliases: ["twitter", "x.com", "tweet"], frontPageOnly: false),
        .init(host: "twitter.com", aliases: ["twitter", "x.com", "tweet"], frontPageOnly: false),
        .init(host: "reddit.com", aliases: ["reddit", "subreddit"], frontPageOnly: false),
        .init(host: "twitch.tv", aliases: ["twitch"], frontPageOnly: false),
        .init(host: "9gag.com", aliases: ["9gag"], frontPageOnly: false),
        .init(host: "spiegel.de", aliases: ["spiegel"], frontPageOnly: true),
        .init(host: "bild.de", aliases: ["bild.de", "bild zeitung"], frontPageOnly: true),
        .init(host: "cnn.com", aliases: ["cnn"], frontPageOnly: true),
        .init(host: "welt.de", aliases: ["welt.de"], frontPageOnly: true),
        .init(host: "n-tv.de", aliases: ["n-tv", "ntv"], frontPageOnly: true),
        .init(host: "tagesschau.de", aliases: ["tagesschau"], frontPageOnly: true),
        .init(host: "nytimes.com", aliases: ["new york times", "nytimes"], frontPageOnly: true),
        .init(host: "bbc.com", aliases: ["bbc"], frontPageOnly: true),
        .init(host: "bbc.co.uk", aliases: ["bbc"], frontPageOnly: true),
        .init(host: "foxnews.com", aliases: ["fox news", "foxnews"], frontPageOnly: true),
    ]

    static func isNeutralApp(_ ctx: WindowContext) -> Bool {
        let b = ctx.bundleID.lowercased()
        if neutralBundleIDs.contains(b) || neutralBundlePrefixes.contains(where: { b.hasPrefix($0) }) { return true }
        // Match app names only for non-browser apps (a browser tab cannot be "Finder").
        return !ctx.isBrowser && neutralAppNames.contains(ctx.appName.lowercased())
    }

    static func distractionSite(for ctx: WindowContext) -> DistractionSite? {
        guard let raw = ctx.domain, !raw.isEmpty else { return nil }
        let domain = normalizedDomain(raw)
        let path = ctx.urlPath ?? ""
        let isFront = path.isEmpty || path == "/"
        return distractionSites.first { site in
            PatternMatcher.hostMatches(site.host, domain) && (!site.frontPageOnly || isFront)
        }
    }

    static func builtinRule(_ ctx: WindowContext, profile: TaskProfile) -> Classification? {
        if isNeutralApp(ctx) {
            return Classification(label: .neutral, role: .other, confidence: 0.9,
                                  reason: "\(ctx.appName.isEmpty ? "This app" : ctx.appName) is a system utility.",
                                  source: .builtin)
        }
        guard let site = distractionSite(for: ctx) else { return nil }
        // The goal or its keywords mention this site.
        let haystack = ([profile.goal] + profile.keywords).joined(separator: " | ").lowercased()
        if site.aliases.contains(where: { PatternMatcher.containsWord(haystack, $0) }) || haystack.contains(site.host) {
            return nil
        }
        // The profile uses this site as output, source or tool (perhaps with a different path).
        for p in profile.outputs + profile.sources + profile.tools {
            if let host = PatternMatcher.host(ofDomainPattern: p),
               PatternMatcher.hostMatches(site.host, host) || PatternMatcher.hostMatches(host, site.host) {
                return nil
            }
        }
        return Classification(label: .offTask, role: .other, confidence: 0.75,
                              reason: "\(site.host) does not look related to your goal.", source: .builtin)
    }

    // MARK: Cache TTL

    static let changingBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.mail", "com.microsoft.outlook",
        "com.microsoft.teams", "com.microsoft.teams2", "com.apple.mobilesms",
        "com.hnc.discord", "ru.keepcoder.telegram", "org.telegram.desktop",
        "net.whatsapp.whatsapp", "desktop.whatsapp",
    ]

    static let fileExtensions: Set<String> = [
        "pptx", "ppt", "key", "xlsx", "xls", "xlsm", "csv", "numbers", "docx", "doc", "pages", "pdf", "txt",
        "md", "rtf", "fig", "sketch", "psd", "ai", "indd", "swift", "py", "js", "ts", "tsx", "jsx", "json",
        "html", "css", "go", "rs", "java", "kt", "rb", "c", "h", "cpp", "m", "yml", "yaml", "ipynb", "tex",
        "png", "jpg", "jpeg", "mov", "mp4",
    ]

    static func titleLooksLikeFileName(_ title: String) -> Bool {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{2013}|:()[]"))
        for token in title.components(separatedBy: separators) where token.contains(".") {
            let ext = token.split(separator: ".").last.map { String($0).lowercased() } ?? ""
            if token.split(separator: ".").count >= 2, fileExtensions.contains(ext) { return true }
        }
        return false
    }

    static func isChangingContext(_ ctx: WindowContext) -> Bool {
        if changingBundleIDs.contains(ctx.bundleID.lowercased()) { return true }
        if let q = ctx.searchQuery, !q.isEmpty { return true }
        if let d = ctx.domain, !d.isEmpty {
            let domain = normalizedDomain(d)
            if distractionSites.contains(where: { PatternMatcher.hostMatches($0.host, domain) }) { return true }
            if PatternMatcher.hostMatches("linkedin.com", domain), firstPathSegment(ctx.urlPath) == "feed" { return true }
        }
        return false
    }

    /// nil means "whole session".
    static func cacheTTL(for ctx: WindowContext) -> TimeInterval? {
        if ctx.documentPath != nil { return nil }
        if isChangingContext(ctx) { return 10 * 60 }
        if !ctx.isBrowser, titleLooksLikeFileName(ctx.cleanTitle) { return nil }
        return 30 * 60
    }

    // MARK: Prompts

    static func list(_ items: [String]) -> String {
        items.isEmpty ? "(none)" : items.joined(separator: ", ")
    }

    static func systemPrompt(profile: TaskProfile) -> String {
        var target = ""
        if let n = profile.targetCount { target = "\nTarget: \(n) \(profile.targetUnit ?? "items")" }
        var deadline = ""
        if let d = profile.deadline {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd HH:mm"
            deadline = "\nDeadline: \(df.string(from: d))"
        }
        return """
        You help a person with ADHD stay on their goal. You judge whether the window they have in front \
        of them right now serves that goal. Be fair and kind: nothing is off task in general, only relative \
        to this goal. A site that is often distracting can be real work, and a work app can be a distraction.

        Goal: \(profile.goal)
        Task type: \(profile.type.rawValue)
        Outputs (where results land): \(list(profile.outputs))
        Sources (where input comes from): \(list(profile.sources))
        Tools: \(list(profile.tools))
        Drift for this goal: \(list(profile.drift))
        Relevant topics: \(list(profile.keywords))
        What working looks like: \(profile.summary.isEmpty ? "(not described)" : profile.summary)\(target)\(deadline)

        Labels:
        - on_task: working in the output itself.
        - supporting: a source, tool, search or lookup that serves the goal.
        - neutral: neither helps nor hurts (system utilities, a quick look at the calendar or a file manager).
        - off_task: not connected to the goal.
        - unsure: there is not enough information to tell.

        Trips: people leave their output to look things up. Judge the current window as part of the trip:
        - A lookup that started from the output and relates to the goal is supporting, even on a site that \
        is often distracting.
        - Copying during the trip and the output changing recently are strong signs of work.
        - Relevance weakens with every hop. A chain that drifts away from the goal topic (for example from a \
        company page to unrelated news, videos, shopping or social feeds) is off_task.
        - A long time away with no copy and no change to the output weakens the case for supporting.
        - Communication apps (Slack, Mail, Outlook, Teams, Messages) are neutral unless the goal is about \
        communicating or the visible content is clearly about the goal.

        role: output (where results land), source, tool, or other.
        confidence: 0 to 1. Below 0.55 means you are guessing; then use unsure.
        reason: one short, friendly sentence addressed to the person ("you"), never shaming, in the language \
        of the goal. Example: "Looks like a lead profile on LinkedIn, which feeds your Attio list."
        """
    }

    static func userPrompt(ctx: WindowContext, trip: TripSummary, screenText: String?, hasImage: Bool) -> String {
        func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "..." : s }
        var lines: [String] = ["Current window:"]
        lines.append("- App: \(ctx.appName) (\(ctx.bundleID))")
        let title = ctx.cleanTitle.isEmpty ? ctx.windowTitle : ctx.cleanTitle
        lines.append("- Title: \(title.isEmpty ? "(no title)" : clip(title, 200))")
        if let d = ctx.domain, !d.isEmpty {
            lines.append("- Page: \(normalizedDomain(d))\(clip(ctx.urlPath ?? "", 150))")
        }
        if let q = ctx.searchQuery, !q.isEmpty { lines.append("- Search query: \(clip(q, 200))") }
        if let doc = ctx.documentPath {
            lines.append("- Document: \((doc as NSString).lastPathComponent)")
        }

        lines.append("")
        lines.append("Trip so far:")
        if let start = trip.startedFrom {
            lines.append("- Started from: \(clip(start, 200))")
        } else {
            lines.append("- Started from: (not from the output, or no trip)")
        }
        lines.append("- Minutes away from the output: \(String(format: "%.1f", trip.minutesAway))")
        if trip.hops.isEmpty {
            lines.append("- Hops: (none)")
        } else {
            lines.append("- Hops, oldest first:")
            for hop in trip.hops.suffix(12) { lines.append("  - \(clip(hop, 200))") }
        }
        lines.append("- Copies during the trip: \(trip.copiesDuringTrip)")
        lines.append("- Output changed recently: \(trip.outputChangedRecently ? "yes" : "no")")

        if let screenText, !screenText.isEmpty {
            lines.append("")
            lines.append("Text visible in the window:")
            lines.append(screenText)
        }
        if hasImage {
            lines.append("")
            lines.append("The attached image is a screenshot of this window.")
        }
        lines.append("")
        lines.append("Classify the current window.")
        return lines.joined(separator: "\n")
    }

    static let answerSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "label": ["type": "string", "enum": ["on_task", "supporting", "neutral", "off_task", "unsure"]],
            "role": ["type": "string", "enum": ["output", "source", "tool", "other"]],
            "confidence": ["type": "number"],
            "reason": ["type": "string"],
        ] as [String: Any],
        "required": ["label", "role", "confidence", "reason"],
    ]
}

// MARK: - Supporting types

struct ClassifierLLMAnswer: Decodable {
    var label: String
    var role: String
    var confidence: Double
    var reason: String
}

struct ClassifierCacheEntry {
    var classification: Classification
    /// nil means valid for the whole session.
    var expires: Date?
}

struct ClassifierCorrectionEntry: Codable {
    var label: ActivityLabel
    var at: Date
}

/// Corrections for one goal: exact identity keys and general keys.
struct ClassifierCorrectionSet: Codable {
    var exact: [String: ClassifierCorrectionEntry] = [:]
    var general: [String: ClassifierCorrectionEntry] = [:]
}
