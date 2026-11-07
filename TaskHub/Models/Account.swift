import Foundation

/// A connected account. Secrets are NOT stored here — they live in the Keychain
/// (see `CredentialStore`) keyed by `id`.
struct Account: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: AccountKind
    /// User-facing label, e.g. "Agency ClickUp" or "Client Gmail".
    var name: String
    /// Email / username / workspace returned by the service.
    var identity: String
    var isEnabled: Bool = true
    var enabledSources: Set<TaskSource>
    /// Per-account settings and IDs (user IDs, custom search queries...).
    var options: [String: String] = [:]

    init(kind: AccountKind, name: String, identity: String, options: [String: String] = [:]) {
        self.kind = kind
        self.name = name
        self.identity = identity
        self.enabledSources = Set(kind.sources)
        self.options = options
    }

    var displayName: String { name.isEmpty ? identity : name }

    func option(_ key: AccountOption) -> String? {
        guard let value = options[key.rawValue], !value.isEmpty else { return nil }
        return value
    }
}

enum AccountOption: String {
    case userID
    case gmailQuery
    case slackQuery
    case slackTeamURL
    case calendarDaysAhead
}

enum OptionDefaults {
    /// Starred emails are treated as to-dos by default.
    static let gmailQuery = "is:starred -in:trash"
    /// `{me}` is replaced with your Slack user ID; `{since}` with a date 14 days ago.
    static let slackQuery = "<@{me}> after:{since}"
    static let calendarDaysAhead = 14
}
