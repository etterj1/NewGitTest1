import Foundation

/// Every connected service implements this. Providers are cheap value types created
/// on demand by `ProviderFactory`; they read their secrets from the Keychain.
protocol TaskProvider {
    var account: Account { get }

    /// Open items assigned to / requested of you.
    func fetchItems() async throws -> [TaskItem]

    /// Lists / projects / calendars a new item can be created in.
    func destinations() async throws -> [Destination]

    func create(_ draft: TaskDraft, in destination: Destination) async throws -> TaskItem
    func update(_ item: TaskItem, with draft: TaskDraft) async throws -> TaskItem
    func setCompleted(_ item: TaskItem, _ completed: Bool) async throws -> TaskItem
}

extension TaskProvider {
    func destinations() async throws -> [Destination] { [] }

    func create(_ draft: TaskDraft, in destination: Destination) async throws -> TaskItem {
        throw APIError.unsupported("Creating items isn't supported for \(destination.source.displayName).")
    }

    func update(_ item: TaskItem, with draft: TaskDraft) async throws -> TaskItem {
        throw APIError.unsupported("Editing isn't supported for \(item.source.displayName).")
    }
}

/// Thrown when some of an account's sources loaded and others failed
/// (e.g. Gmail worked but the Tasks API isn't enabled).
struct PartialFetchError: LocalizedError {
    let items: [TaskItem]
    let messages: [String]
    var errorDescription: String? { messages.joined(separator: "\n") }
}

enum ProviderFactory {
    static func make(for account: Account, local: LocalTaskDatabase) -> TaskProvider {
        switch account.kind {
        case .clickup: return ClickUpProvider(account: account)
        case .asana: return AsanaProvider(account: account)
        case .slack: return SlackProvider(account: account)
        case .google: return GoogleProvider(account: account)
        case .apple: return AppleProvider(account: account)
        case .local: return LocalProvider(account: account, database: local)
        }
    }
}

extension TaskDraft {
    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
}
