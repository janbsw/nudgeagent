import Foundation

/// Turns a goal sentence into a TaskProfile with one LLM call.
final class ProfileGenerator: ProfileGenerating {
    private let llm: LLMClient
    private let settingsProvider: () -> AppSettings

    init(llm: LLMClient, settingsProvider: @escaping () -> AppSettings) {
        self.llm = llm
        self.settingsProvider = settingsProvider
    }

    func generateProfile(goal: String, deadline: Date?) async throws -> TaskProfile {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let settingsProvider = self.settingsProvider
        let settings = await MainActor.run { settingsProvider() }
        let answer: LLMProfileAnswer = try await llm.complete(
            model: settings.textModel,
            system: Self.systemPrompt(today: Date(), deadline: deadline),
            user: "Goal: \(trimmedGoal)",
            schema: Self.schema,
            maxTokens: 4000)
        return Self.makeProfile(from: answer, goal: trimmedGoal, deadline: deadline)
    }

    // MARK: Validation

    static func makeProfile(from a: LLMProfileAnswer, goal: String, deadline: Date?) -> TaskProfile {
        func clean(_ list: [String]) -> [String] { PatternMatcher.normalize(list) }
        var keywords: [String] = []
        var seen = Set<String>()
        for k in a.keywords {
            let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, seen.insert(t.lowercased()).inserted { keywords.append(t) }
        }
        let unit = a.targetUnit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = (a.targetCount ?? 0) > 0 ? a.targetCount : nil
        return TaskProfile(
            goal: goal,
            type: TaskType(rawValue: a.type.lowercased()) ?? .create,
            outputs: clean(a.outputs),
            sources: clean(a.sources),
            tools: clean(a.tools),
            drift: clean(a.drift),
            keywords: keywords,
            summary: a.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            targetCount: count,
            targetUnit: count == nil ? nil : ((unit?.isEmpty ?? true) ? nil : unit),
            deadline: deadline)
    }

    // MARK: Prompt

    static func systemPrompt(today: Date, deadline: Date?) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        var dateLine = "Now: \(df.string(from: today))."
        if let deadline { dateLine += " Deadline: \(df.string(from: deadline))." }

        return """
        You set up a focus assistant for a person with ADHD on a Mac. The person writes one goal \
        sentence. You turn it into a task profile that a program uses to decide, for every app, \
        window and web page, whether it serves this goal. \(dateLine)

        Task types:
        - create: produce something (deck, memo, code, design, model). Working means the output changes.
        - research: collect information into an output (leads, market research, due diligence). Working means moving from sources to the output.
        - process: work through a queue (inbox zero, admin, expenses, tickets). Working means items get done.
        - communicate: send messages (follow-ups, outreach, replies). Working means messages get sent.
        - learn: study (course, long report, documentation). Working means steady reading or watching in one place.

        Fields:
        - goal: repeat the goal sentence.
        - type: one of the task types.
        - outputs: where results land (the deck file's app, the CRM, the spreadsheet, the code editor).
        - sources: where input comes from (sites, databases, documents, search engines).
        - tools: supporting apps and sites (calculator, translator, AI chat, docs, file manager when relevant).
        - drift: what is distracting FOR THIS GOAL. Nothing is globally off task: email is the work for \
        "clear my inbox", YouTube is the work for "edit the YouTube video". Only list things that pull \
        away from this specific goal.
        - keywords: 5 to 15 topics, names and terms that make a search query, page title or document relevant \
        to this goal (include synonyms and the main entities, in the language of the goal and in English).
        - summary: one or two sentences describing what working on this goal looks like on screen.
        - targetCount and targetUnit: parse a countable target from the goal ("20 leads" gives 20 and "leads"). \
        Use null for both when there is no number.

        Pattern format for outputs, sources, tools and drift. Every entry must be one of:
        - a macOS app name as it appears in the menu bar, e.g. "PowerPoint", "Excel", "Keynote", "Numbers", \
        "Pages", "Word", "Attio", "Slack", "Cursor", "Xcode", "Figma", "Notion", "Mail", "Outlook"
        - a bundle id, e.g. "com.microsoft.Powerpoint"
        - a domain, optionally with a path glob where the path matters, e.g. "apollo.io", "linkedin.com/in/*", \
        "linkedin.com/sales/*", "docs.google.com/spreadsheets/*", "google.com/search". Use paths to separate \
        useful and distracting parts of one site: for a lead search "linkedin.com/in/*" is a source while \
        "linkedin.com/feed" is drift.
        - "title:<keyword>" to match a word in the window title, e.g. "title:Q3 Pitch".
        Prefer concrete app names and domains over descriptions. For web apps give the domain (and the \
        desktop app name too if one exists, e.g. both "Attio" and "app.attio.com"). Do not invent file paths. \
        Do not include the browser itself (Chrome, Safari, Arc) as a tool. Keep each list short and precise \
        (usually 1 to 8 entries); an empty list is fine.
        """
    }

    static let schema: [String: Any] = {
        let stringArray: [String: Any] = ["type": "array", "items": ["type": "string"]]
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "goal": ["type": "string"],
                "type": ["type": "string", "enum": TaskType.allCases.map(\.rawValue)],
                "outputs": stringArray,
                "sources": stringArray,
                "tools": stringArray,
                "drift": stringArray,
                "keywords": stringArray,
                "summary": ["type": "string"],
                "targetCount": ["type": ["integer", "null"]],
                "targetUnit": ["type": ["string", "null"]],
            ] as [String: Any],
            "required": ["goal", "type", "outputs", "sources", "tools", "drift", "keywords",
                         "summary", "targetCount", "targetUnit"],
        ]
    }()
}

/// Raw structured answer of the profile prompt.
struct LLMProfileAnswer: Decodable {
    var goal: String
    var type: String
    var outputs: [String]
    var sources: [String]
    var tools: [String]
    var drift: [String]
    var keywords: [String]
    var summary: String
    var targetCount: Int?
    var targetUnit: String?
}
