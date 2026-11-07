import Foundation

/// AI helpers for research, planning and drafting. You bring your own API keys;
/// they're stored in the Keychain and requests go straight from the device to the provider.
enum AIProvider: String, CaseIterable, Identifiable {
    case claude, chatgpt, grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .grok: return "Grok"
        }
    }

    var keychainName: String { "ai.\(rawValue).apiKey" }

    var apiKey: String? { CredentialStore.secret(named: keychainName) }

    var isConfigured: Bool { !(apiKey ?? "").isEmpty }

    static var configured: [AIProvider] { allCases.filter(\.isConfigured) }
}

enum AISettings {
    static let defaultProviderKey = "ai.defaultProvider"
    static let openAIModelKey = "ai.openai.model"
    static let defaultOpenAIModel = "gpt-5"
    static let grokModelKey = "ai.grok.model"
    static let defaultGrokModel = "grok-4.7" // cheaper/faster alternative: "grok-4.3"
    /// Claude's current default model.
    static let claudeModel = "claude-opus-5-5"
}

/// One back-and-forth conversation with an AI provider.
@MainActor
protocol AIConversation: AnyObject {
    func send(_ text: String) async throws -> String
}

enum AIConversationFactory {
    @MainActor
    static func make(_ provider: AIProvider, system: String, webSearch: Bool) throws -> AIConversation {
        guard let key = provider.apiKey, !key.isEmpty else {
            throw APIError.notConfigured("Add your \(provider.displayName) API key under Accounts → AI Assistants.")
        }
        switch provider {
        case .claude:
            return ClaudeConversation(apiKey: key, system: system, webSearch: webSearch)
        case .chatgpt:
            let model = UserDefaults.standard.string(forKey: AISettings.openAIModelKey)
            return OpenAIConversation(apiKey: key, model: (model?.isEmpty ?? true) ? AISettings.defaultOpenAIModel : model!,
                                      instructions: system, webSearch: webSearch)
        case .grok:
            let model = UserDefaults.standard.string(forKey: AISettings.grokModelKey)
            return GrokConversation(apiKey: key, model: (model?.isEmpty ?? true) ? AISettings.defaultGrokModel : model!,
                                    system: system, liveSearch: webSearch)
        }
    }
}

// MARK: - Claude (Anthropic Messages API, raw HTTP — there is no official Swift SDK)

@MainActor
final class ClaudeConversation: AIConversation {
    private static let url = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiKey: String
    private let system: String
    private let webSearch: Bool
    /// Full message history. Assistant turns are kept exactly as returned (including any
    /// thinking blocks) because the API requires history to be replayed unchanged.
    private var messages: [[String: Any]] = []

    init(apiKey: String, system: String, webSearch: Bool) {
        self.apiKey = apiKey
        self.system = system
        self.webSearch = webSearch
    }

    func send(_ text: String) async throws -> String {
        messages.append(["role": "user", "content": text])
        var collected: [String] = []

        // A long web-search turn can come back as `pause_turn`; send it back to let Claude continue.
        for _ in 0..<5 {
            var body: [String: Any] = [
                "model": AISettings.claudeModel,
                "max_tokens": 16000,
                "system": system,
                "messages": messages,
                "output_config": ["effort": "medium"],
                // If a safety classifier declines, retry server-side on Anthropic's recommended fallback model.
                "fallbacks": "default",
            ]
            if webSearch {
                body["tools"] = [["type": "web_search_20260209", "name": "web_search", "max_uses": 5]]
            }

            let data = try await HTTP.data(Self.url, method: "POST", headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2026-10-21",
                "anthropic-beta": "server-side-fallback-2026-07-01",
            ], body: .json(body), session: HTTP.longSession)

            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw APIError.api("Unexpected response from Claude.")
            }
            let stopReason = response["stop_reason"] as? String
            if stopReason == "refusal" {
                let details = response["stop_details"] as? [String: Any]
                let explanation = details?["explanation"] as? String
                messages.removeLast() // don't keep the declined prompt in the history
                throw APIError.api("Claude declined this request\(explanation.map { ": \($0)" } ?? ".")")
            }
            let content = response["content"] as? [Any] ?? []
            messages.append(["role": "assistant", "content": content])
            collected += content.compactMap { block in
                guard let block = block as? [String: Any], block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            if stopReason != "pause_turn" { break }
        }

        let reply = collected.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? "(No answer returned.)" : reply
    }
}

// MARK: - ChatGPT (OpenAI Responses API)

@MainActor
final class OpenAIConversation: AIConversation {
    private static let url = URL(string: "https://api.openai.com/v1/responses")!
    private let apiKey: String
    private let model: String
    private let instructions: String
    private let webSearch: Bool
    /// OpenAI keeps the conversation server-side; we chain turns by response ID.
    private var previousResponseID: String?

    init(apiKey: String, model: String, instructions: String, webSearch: Bool) {
        self.apiKey = apiKey
        self.model = model
        self.instructions = instructions
        self.webSearch = webSearch
    }

    func send(_ text: String) async throws -> String {
        var body: [String: Any] = ["model": model, "instructions": instructions, "input": text]
        if let previousResponseID { body["previous_response_id"] = previousResponseID }
        if webSearch { body["tools"] = [["type": "web_search"]] }

        let data = try await HTTP.data(Self.url, method: "POST",
                                       headers: ["Authorization": "Bearer \(apiKey)"],
                                       body: .json(body), session: HTTP.longSession)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.api("Unexpected response from ChatGPT.")
        }
        previousResponseID = response["id"] as? String

        var parts: [String] = []
        for item in response["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for piece in item["content"] as? [[String: Any]] ?? [] {
                if piece["type"] as? String == "output_text", let text = piece["text"] as? String { parts.append(text) }
                if piece["type"] as? String == "refusal", let text = piece["refusal"] as? String { parts.append(text) }
            }
        }
        let reply = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? "(No answer returned.)" : reply
    }
}

// MARK: - Grok (xAI Responses API)

/// Talks to xAI's Responses API (Chat Completions is legacy there). With search on, Grok gets the
/// server-side `web_search` and `x_search` tools; X search is limited to the last 30 days to keep
/// per-post search costs down. If xAI rejects the search request, Grok answers without search and says so.
@MainActor
final class GrokConversation: AIConversation {
    private static let url = URL(string: "https://api.x.ai/v1/responses")!
    private let apiKey: String
    private let model: String
    private let liveSearch: Bool
    /// Resent in full each turn, so switching search on/off never loses context.
    private var messages: [[String: String]]

    init(apiKey: String, model: String, system: String, liveSearch: Bool) {
        self.apiKey = apiKey
        self.model = model
        self.liveSearch = liveSearch
        self.messages = [["role": "system", "content": system]]
    }

    func send(_ text: String) async throws -> String {
        messages.append(["role": "user", "content": text])
        var reply: String
        if liveSearch {
            do {
                reply = try await respond(withSearch: true)
            } catch APIError.http(let status, _) where (400..<500).contains(status) && ![401, 403, 429].contains(status) {
                reply = try await respond(withSearch: false)
                reply += "\n\n_(Search wasn't available for this request, so this answer is from Grok's own knowledge.)_"
            }
        } else {
            reply = try await respond(withSearch: false)
        }
        messages.append(["role": "assistant", "content": reply])
        return reply
    }

    private func respond(withSearch: Bool) async throws -> String {
        var body: [String: Any] = ["model": model, "input": messages]
        if withSearch {
            let since = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            body["tools"] = [
                ["type": "web_search"],
                ["type": "x_search", "from_date": DateCoding.dayString(since)],
            ]
        }
        let data = try await HTTP.data(Self.url, method: "POST", headers: ["Authorization": "Bearer \(apiKey)"],
                                       body: .json(body), session: HTTP.longSession)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Search runs add tool-call items to `output`, so collect every message's output_text.
        var parts: [String] = []
        for item in json?["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for piece in item["content"] as? [[String: Any]] ?? [] where piece["type"] as? String == "output_text" {
                if let text = piece["text"] as? String { parts.append(text) }
            }
        }
        let reply = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? "(No answer returned.)" : reply
    }
}

// MARK: - Prompts

enum AIPrompts {
    static func system(context: String) -> String {
        """
        You are the assistant inside TaskHub, a to-do app that collects a marketing professional's \
        work from ClickUp, Asana, Slack, Gmail, calendars and reminders. Help them research, plan and \
        get things done. Be practical and concise: short paragraphs or bullet points, concrete next \
        steps, and realistic time estimates. When you use web sources, name them. Write drafts in a \
        friendly, professional voice that is ready to paste. Today is \
        \(Date().formatted(date: .complete, time: .omitted)).

        <context>
        \(context)
        </context>
        """
    }

    static func describe(_ item: TaskItem, accountName: String?) -> String {
        var lines = ["Title: \(item.title)", "From: \(item.source.displayName)\(accountName.map { " (\($0))" } ?? "")"]
        if let project = item.project, !project.isEmpty { lines.append("Project/list: \(project)") }
        if let requester = item.requester, !requester.isEmpty { lines.append("Requested by: \(requester)") }
        if let due = item.dueDate {
            lines.append("Due: \(due.formatted(date: .abbreviated, time: item.dueHasTime ? .shortened : .omitted))")
        }
        if item.priority != .none { lines.append("Priority: \(item.priority.label)") }
        if let status = item.status { lines.append("Status: \(status)") }
        if !item.notes.isEmpty { lines.append("Details:\n\(String(item.notes.prefix(8000)))") }
        return lines.joined(separator: "\n")
    }

    static func describe(list items: [TaskItem]) -> String {
        items.prefix(120).map { item in
            var line = "- [\(item.source.displayName)] \(item.title)"
            if let due = DueFormatter.label(for: item) { line += " — due \(due)" }
            if item.isOverdue { line += " (OVERDUE)" }
            if let project = item.project, !project.isEmpty { line += " — \(project)" }
            if let requester = item.requester, !requester.isEmpty { line += " — from \(requester)" }
            if item.priority >= .high { line += " — \(item.priority.label) priority" }
            return line
        }.joined(separator: "\n")
    }

    enum TaskAction: String, CaseIterable, Identifiable {
        case research, plan, reply, social, ask

        var id: String { rawValue }

        var label: String {
            switch self {
            case .research: return "Research this"
            case .plan: return "Break into steps"
            case .reply: return "Draft a reply"
            case .social: return "Check the buzz on X (Grok)"
            case .ask: return "Ask anything…"
            }
        }

        var symbol: String {
            switch self {
            case .research: return "magnifyingglass"
            case .plan: return "list.number"
            case .reply: return "arrowshape.turn.up.left"
            case .social: return "bubble.left.and.exclamationmark.bubble.right"
            case .ask: return "bubble.left.and.text.bubble.right"
            }
        }

        var usesWebSearch: Bool { self == .research || self == .social || self == .ask }

        /// Social listening needs Grok's X search; other actions use the default assistant.
        var requiredProvider: AIProvider? { self == .social ? .grok : nil }

        static var available: [TaskAction] {
            allCases.filter { $0.requiredProvider?.isConfigured ?? true }
        }

        var prompt: String? {
            switch self {
            case .research:
                return "Research what I need to know to get this task done well: background, best practices, examples or benchmarks, and anything I should watch out for. Search the web where it helps and name your sources."
            case .plan:
                return "Break this task into a short checklist of concrete next steps, in order, each with a rough time estimate. Flag anything I need from someone else."
            case .reply:
                return "Draft a short reply to the person who asked for this, confirming I'm on it and what happens next. If the request is unclear, include the questions I should ask."
            case .social:
                return "Do social listening on X for this task's topic (brand, campaign, client or competitor; work out the right search terms from the task). Use both keyword and semantic search over recent posts. Summarize the main narratives, overall sentiment, notable posts (handle, quote and why it matters), questions people are asking, and content opportunities. Separate official/brand accounts from regular users. Cite specific posts. Don't invent posts; if results are thin, say so."
            case .ask:
                return nil
            }
        }
    }

    static let briefing = "Here's everything currently on my plate. Give me a prioritized plan for today: the top 3 things to do first and why, anything overdue or at risk, what I could delegate, defer or drop, and any quick wins under 15 minutes."
}
