import Foundation

/// Tasks that live only in TaskHub (quick personal to-dos and notes that don't belong to any app).
actor LocalTaskDatabase {
    private static let fileName = "local-tasks.json"
    private var tasks: [TaskItem]

    init() {
        tasks = Persistence.load([TaskItem].self, from: Self.fileName) ?? []
    }

    func all(for accountID: UUID) -> [TaskItem] {
        tasks.filter { $0.accountID == accountID }
    }

    func upsert(_ item: TaskItem) {
        if let index = tasks.firstIndex(where: { $0.id == item.id }) {
            tasks[index] = item
        } else {
            tasks.append(item)
        }
        Persistence.save(tasks, to: Self.fileName)
    }

    func removeAll(for accountID: UUID) {
        tasks.removeAll { $0.accountID == accountID }
        Persistence.save(tasks, to: Self.fileName)
    }
}

struct LocalProvider: TaskProvider {
    let account: Account
    let database: LocalTaskDatabase

    func fetchItems() async throws -> [TaskItem] {
        // Keep recently completed local tasks for a day so "Completed" view has them.
        let cutoff = Date().addingTimeInterval(-86_400)
        return await database.all(for: account.id).filter { !$0.isCompleted || ($0.completedAt ?? .distantPast) > cutoff }
    }

    func destinations() async throws -> [Destination] {
        [Destination(accountID: account.id, source: .local, containerID: "inbox", name: "TaskHub Inbox", detail: account.displayName)]
    }

    func create(_ draft: TaskDraft, in destination: Destination) async throws -> TaskItem {
        var item = TaskItem(accountID: account.id, source: .local, externalID: UUID().uuidString, containerID: "inbox", title: draft.trimmedTitle)
        apply(draft, to: &item)
        item.createdAt = Date()
        item.project = "Inbox"
        await database.upsert(item)
        return item
    }

    func update(_ item: TaskItem, with draft: TaskDraft) async throws -> TaskItem {
        var updated = item
        apply(draft, to: &updated)
        await database.upsert(updated)
        return updated
    }

    func setCompleted(_ item: TaskItem, _ completed: Bool) async throws -> TaskItem {
        var updated = item
        updated.isCompleted = completed
        updated.completedAt = completed ? Date() : nil
        updated.updatedAt = Date()
        await database.upsert(updated)
        return updated
    }

    private func apply(_ draft: TaskDraft, to item: inout TaskItem) {
        item.title = draft.trimmedTitle
        item.notes = draft.notes
        item.dueDate = draft.dueDate
        item.dueHasTime = draft.dueHasTime
        item.priority = draft.priority
        item.updatedAt = Date()
    }
}
