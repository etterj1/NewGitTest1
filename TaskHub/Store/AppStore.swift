import Foundation
import Observation

enum SidebarFilter: Hashable {
    case all, today, upcoming, overdue, noDate, completed
    case source(TaskSource)
    case account(UUID)
    case project(String)
}

enum DateBucket: Int, CaseIterable, Identifiable {
    case overdue, today, tomorrow, thisWeek, later, noDate, done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .thisWeek: return "Next 7 Days"
        case .later: return "Later"
        case .noDate: return "No Date · Emails & Mentions"
        case .done: return "Completed"
        }
    }

    static func of(_ item: TaskItem, now: Date = Date()) -> DateBucket {
        if item.isCompleted { return .done }
        guard let due = item.dueDate else { return .noDate }
        if item.isOverdue { return .overdue }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: today)!
        let week = calendar.date(byAdding: .day, value: 7, to: today)!
        if due < tomorrow { return .today }
        if due < dayAfter { return .tomorrow }
        if due < week { return .thisWeek }
        return .later
    }
}

/// Central state: connected accounts, the merged item list, and every sync operation.
@MainActor
@Observable
final class AppStore {
    private(set) var accounts: [Account] = []
    private(set) var items: [TaskItem] = []
    private(set) var accountErrors: [UUID: String] = [:]
    private(set) var refreshingAccounts: Set<UUID> = []
    private(set) var lastRefresh: Date?
    var alertMessage: String?

    /// Items whose source can't record "done" (Slack search results, calendar events): id → completion date.
    @ObservationIgnored private var locallyDone: [String: Date] = [:]
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    let localDatabase = LocalTaskDatabase()

    private static let overlaySources: Set<TaskSource> = [.slack, .googleCalendar, .appleCalendar]

    private enum Files {
        static let accounts = "accounts.json"
        static let items = "items-cache.json"
        static let locallyDone = "locally-done.json"
    }

    var isRefreshing: Bool { !refreshingAccounts.isEmpty }

    init() {
        accounts = Persistence.load([Account].self, from: Files.accounts) ?? []
        items = Persistence.load([TaskItem].self, from: Files.items) ?? []
        locallyDone = Persistence.load([String: Date].self, from: Files.locallyDone) ?? [:]
        if accounts.isEmpty {
            accounts = [Account(kind: .local, name: "TaskHub", identity: "On this device")]
            saveAccounts()
        }
    }

    // MARK: Lookup

    func account(for id: UUID) -> Account? { accounts.first { $0.id == id } }

    func provider(for account: Account) -> TaskProvider {
        ProviderFactory.make(for: account, local: localDatabase)
    }

    private var enabledAccountIDs: Set<UUID> { Set(accounts.filter(\.isEnabled).map(\.id)) }

    var visibleItems: [TaskItem] {
        let enabled = enabledAccountIDs
        return items.filter { enabled.contains($0.accountID) }
    }

    func items(matching filter: SidebarFilter, search: String = "") -> [TaskItem] {
        filtered(filter, search: search).sorted(by: Self.ordering)
    }

    func count(for filter: SidebarFilter) -> Int { filtered(filter, search: "").count }

    private func filtered(_ filter: SidebarFilter, search: String) -> [TaskItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let week = calendar.date(byAdding: .day, value: 7, to: today)!
        let query = search.trimmingCharacters(in: .whitespaces)

        return visibleItems
            .filter { item in
                switch filter {
                case .all: return !item.isCompleted
                case .today: return !item.isCompleted && (item.dueDate.map { $0 < tomorrow } ?? false)
                case .upcoming: return !item.isCompleted && (item.dueDate.map { $0 >= today && $0 < week } ?? false)
                case .overdue: return item.isOverdue
                case .noDate: return !item.isCompleted && item.dueDate == nil
                case .completed: return item.isCompleted
                case .source(let source): return !item.isCompleted && item.source == source
                case .account(let id): return !item.isCompleted && item.accountID == id
                case .project(let name): return !item.isCompleted && item.project == name
                }
            }
            .filter { item in
                guard !query.isEmpty else { return true }
                return [item.title, item.notes, item.project ?? "", item.requester ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
    }

    /// Projects with the most open items, for the sidebar.
    var topProjects: [String] {
        var counts: [String: Int] = [:]
        for item in visibleItems where !item.isCompleted && item.kind == .task {
            if let project = item.project, !project.isEmpty { counts[project, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(25)
            .map(\.key)
    }

    nonisolated static func ordering(_ a: TaskItem, _ b: TaskItem) -> Bool {
        let bucketA = DateBucket.of(a), bucketB = DateBucket.of(b)
        if bucketA != bucketB { return bucketA.rawValue < bucketB.rawValue }
        if bucketA == .noDate || bucketA == .done {
            return (a.completedAt ?? a.createdAt ?? .distantPast) > (b.completedAt ?? b.createdAt ?? .distantPast)
        }
        if let da = a.dueDate, let db = b.dueDate, !Calendar.current.isDate(da, inSameDayAs: db) { return da < db }
        if a.priority != b.priority { return a.priority > b.priority }
        return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture)
    }

    // MARK: Refresh

    /// Starts a background sync loop (once per app launch).
    func startAutoRefresh(every interval: Duration = .seconds(300)) {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task {
            while !Task.isCancelled {
                await refreshAll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Called when the app comes to the foreground.
    func refreshIfStale(olderThan seconds: TimeInterval = 60) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < seconds { return }
        await refreshAll()
    }

    func refreshAll() async {
        let targets = accounts.filter(\.isEnabled)
        await withTaskGroup(of: Void.self) { group in
            for account in targets {
                group.addTask { await self.refresh(account) }
            }
        }
        lastRefresh = Date()
        saveItems()
    }

    func refresh(_ account: Account) async {
        guard !refreshingAccounts.contains(account.id) else { return }
        refreshingAccounts.insert(account.id)
        defer { refreshingAccounts.remove(account.id) }

        let provider = self.provider(for: account)
        do {
            let fetched = try await provider.fetchItems()
            merge(fetched, for: account)
            accountErrors[account.id] = nil
        } catch let partial as PartialFetchError {
            merge(partial.items, for: account, keepMissingSources: true)
            accountErrors[account.id] = partial.messages.joined(separator: "\n")
        } catch {
            accountErrors[account.id] = error.localizedDescription
        }
    }

    private func merge(_ fetched: [TaskItem], for account: Account, keepMissingSources: Bool = false) {
        guard let current = self.account(for: account.id) else { return } // removed while refreshing
        let cutoff = Date().addingTimeInterval(-86_400)
        var fresh = fetched.filter { current.enabledSources.contains($0.source) }
        let freshIDs = Set(fresh.map(\.id))
        let freshSources = Set(fresh.map(\.source))

        for index in fresh.indices {
            if let doneAt = locallyDone[fresh[index].id] {
                fresh[index].isCompleted = true
                fresh[index].completedAt = doneAt
            }
        }

        let previous = items.filter { $0.accountID == account.id }
        let kept = previous.filter { item in
            guard !freshIDs.contains(item.id), current.enabledSources.contains(item.source) else { return false }
            // Keep things completed in the last day so the Completed view isn't empty after a sync.
            if item.isCompleted, (item.completedAt ?? .distantPast) > cutoff { return true }
            // If a source failed this round, keep its cached items rather than blanking them out.
            return keepMissingSources && !freshSources.contains(item.source)
        }

        items = items.filter { $0.accountID != account.id } + fresh + kept

        // Forget local "done" marks for items that no longer exist upstream.
        let prefix = account.id.uuidString
        let liveIDs = Set(items.map(\.id))
        locallyDone = locallyDone.filter { !$0.key.hasPrefix(prefix) || liveIDs.contains($0.key) }
        saveLocallyDone()
    }

    // MARK: Item operations (each pushes to the source app)

    func setCompleted(_ item: TaskItem, _ completed: Bool) async {
        guard let account = account(for: item.accountID) else { return }
        var optimistic = item
        optimistic.isCompleted = completed
        optimistic.completedAt = completed ? Date() : nil
        replace(optimistic)

        do {
            let updated = try await provider(for: account).setCompleted(item, completed)
            replace(updated)
            if Self.overlaySources.contains(item.source) {
                if completed { locallyDone[item.id] = Date() } else { locallyDone[item.id] = nil }
                saveLocallyDone()
            }
        } catch {
            replace(item)
            alertMessage = "Couldn't update “\(item.title)” in \(item.source.displayName): \(error.localizedDescription)"
        }
        saveItems()
    }

    func toggleCompleted(_ item: TaskItem) async {
        await setCompleted(item, !item.isCompleted)
    }

    @discardableResult
    func create(_ draft: TaskDraft, in destination: Destination) async throws -> TaskItem {
        guard let account = account(for: destination.accountID) else { throw APIError.api("Account not found.") }
        var created = try await provider(for: account).create(draft, in: destination)
        if created.project == nil || created.project?.isEmpty == true { created.project = destination.name }
        replace(created)
        saveItems()
        return created
    }

    @discardableResult
    func update(_ item: TaskItem, with draft: TaskDraft) async throws -> TaskItem {
        guard let account = account(for: item.accountID) else { throw APIError.api("Account not found.") }
        var updated = try await provider(for: account).update(item, with: draft)
        if updated.project == nil { updated.project = item.project }
        if updated.requester == nil { updated.requester = item.requester }
        replace(updated)
        saveItems()
        return updated
    }

    func destinations(for account: Account) async throws -> [Destination] {
        try await provider(for: account).destinations()
            .filter { account.enabledSources.contains($0.source) }
    }

    private func replace(_ item: TaskItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    // MARK: Accounts

    func addAccount(_ account: Account, credential: Credential?) throws {
        if let credential { try CredentialStore.save(credential, for: account.id) }
        accounts.append(account)
        saveAccounts()
        Task { await refresh(account); saveItems() }
    }

    func updateAccount(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        items.removeAll { $0.accountID == account.id && !account.enabledSources.contains($0.source) }
        saveAccounts()
        saveItems()
    }

    func removeAccount(_ account: Account) {
        CredentialStore.delete(for: account.id)
        accounts.removeAll { $0.id == account.id }
        items.removeAll { $0.accountID == account.id }
        accountErrors[account.id] = nil
        let prefix = account.id.uuidString
        locallyDone = locallyDone.filter { !$0.key.hasPrefix(prefix) }
        if account.kind == .local {
            let database = localDatabase
            Task { await database.removeAll(for: account.id) }
        }
        saveAccounts()
        saveItems()
        saveLocallyDone()
    }

    // MARK: Persistence

    private func saveAccounts() { Persistence.save(accounts, to: Files.accounts) }
    private func saveItems() { Persistence.save(items, to: Files.items) }
    private func saveLocallyDone() { Persistence.save(locallyDone, to: Files.locallyDone) }
}
