import Foundation

/// Slack Web API with a *user* token (xoxp-…) from your own Slack app.
/// Shows messages that mention you (customisable search). Add one account per workspace.
struct SlackProvider: TaskProvider {
    let account: Account
    private static let base = URL(string: "https://slack.com/api/")!
    private static let doneReaction = "white_check_mark"

    static func connect(token: String) async throws -> (identity: String, options: [String: String]) {
        let auth = try await call(AuthTest.self, "auth.test", token: token)
        return (
            "\(auth.user ?? "me") @ \(auth.team ?? "Slack")",
            [AccountOption.userID.rawValue: auth.user_id ?? "", AccountOption.slackTeamURL.rawValue: auth.url ?? ""]
        )
    }

    func fetchItems() async throws -> [TaskItem] {
        let token = try CredentialStore.token(for: account.id)
        let userID = account.option(.userID) ?? ""
        let since = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        let query = (account.option(.slackQuery) ?? OptionDefaults.slackQuery)
            .replacingOccurrences(of: "{me}", with: userID)
            .replacingOccurrences(of: "{since}", with: DateCoding.dayString(since))

        let result = try await Self.call(SearchResponse.self, "search.messages", token: token, query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "sort", value: "timestamp"),
            URLQueryItem(name: "sort_dir", value: "desc"),
            URLQueryItem(name: "count", value: "50"),
        ])
        return (result.messages?.matches ?? [])
            .filter { $0.user != userID } // skip your own messages
            .map { map($0) }
    }

    func setCompleted(_ item: TaskItem, _ completed: Bool) async throws -> TaskItem {
        let token = try CredentialStore.token(for: account.id)
        let parts = item.externalID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw APIError.api("Invalid Slack message reference.") }
        do {
            _ = try await Self.call(SlackOK.self, completed ? "reactions.add" : "reactions.remove",
                                    token: token, method: "POST",
                                    body: ["channel": parts[0], "timestamp": parts[1], "name": Self.doneReaction])
        } catch APIError.api(let message) where message.contains("already_reacted") || message.contains("no_reaction") {
            // Already in the desired state.
        }
        var updated = item
        updated.isCompleted = completed
        updated.completedAt = completed ? Date() : nil
        return updated
    }

    private func map(_ match: Match) -> TaskItem {
        let channelID = match.channel?.id ?? "unknown"
        var item = TaskItem(accountID: account.id, source: .slack, externalID: "\(channelID)|\(match.ts)",
                            containerID: channelID, title: Self.clean(match.text ?? "").firstLine)
        item.notes = Self.clean(match.text ?? "")
        item.requester = match.username
        if let name = match.channel?.name, !name.hasPrefix("U"), !name.hasPrefix("D") {
            item.project = "#\(name)"
        } else {
            item.project = "Direct message"
        }
        item.webURL = match.permalink.flatMap(URL.init(string:))
        if let seconds = Double(match.ts) { item.createdAt = Date(timeIntervalSince1970: seconds) }
        return item
    }

    /// Turns Slack markup like `<https://x|label>` and `<@U123>` into readable text.
    private static func clean(_ text: String) -> String {
        var output = ""
        var remainder = Substring(text)
        while let open = remainder.firstIndex(of: "<"), let close = remainder[open...].firstIndex(of: ">") {
            output += remainder[..<open]
            let inner = remainder[remainder.index(after: open)..<close]
            if let pipe = inner.firstIndex(of: "|") {
                output += inner[inner.index(after: pipe)...]
            } else if inner.hasPrefix("@") {
                output += "@mention"
            } else if inner.hasPrefix("#") {
                output += "#channel"
            } else {
                output += inner
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        output += remainder
        return output.decodingHTMLEntities
    }

    // MARK: API

    private static func call<T: SlackResponse>(
        _ type: T.Type, _ endpoint: String, token: String,
        method httpMethod: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil
    ) async throws -> T {
        let response = try await HTTP.json(
            T.self, base, endpoint, method: httpMethod, query: query,
            headers: ["Authorization": "Bearer \(token)"],
            body: body.map { HTTPBody.json($0) }
        )
        guard response.ok else { throw APIError.api("Slack: \(response.error ?? "unknown error")") }
        return response
    }

    private struct SlackOK: SlackResponse { let ok: Bool; let error: String? }
    private struct AuthTest: SlackResponse {
        let ok: Bool; let error: String?
        let user: String?; let user_id: String?; let team: String?; let url: String?
    }
    private struct SearchResponse: SlackResponse {
        struct Messages: Decodable { let matches: [Match]? }
        let ok: Bool; let error: String?
        let messages: Messages?
    }
    private struct Match: Decodable {
        struct Channel: Decodable { let id: String; let name: String? }
        let ts: String
        let text: String?
        let user: String?
        let username: String?
        let permalink: String?
        let channel: Channel?
    }
}

private protocol SlackResponse: Decodable {
    var ok: Bool { get }
    var error: String? { get }
}
