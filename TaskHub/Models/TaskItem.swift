import Foundation

/// A single "thing on your plate", normalized from any source.
struct TaskItem: Identifiable, Codable, Hashable {
    /// Stable across refreshes: account + source + the source's own ID.
    var id: String { "\(accountID.uuidString)|\(source.rawValue)|\(externalID)" }

    let accountID: UUID
    let source: TaskSource
    /// ID of the item in the source system.
    let externalID: String
    /// ID of the list / project / calendar / channel the item lives in.
    var containerID: String?

    var title: String
    var notes: String = ""
    var dueDate: Date?
    var dueHasTime: Bool = false
    var endDate: Date?
    var isCompleted: Bool = false
    var completedAt: Date?
    var priority: TaskPriority = .none
    /// Human-readable project / list / channel / calendar name.
    var project: String?
    /// Who asked for it (email sender, Slack author, meeting organizer...).
    var requester: String?
    var status: String?
    var webURL: URL?
    var createdAt: Date?
    var updatedAt: Date?

    var kind: ItemKind { source.itemKind }

    /// The date used for sorting and bucketing.
    var effectiveDate: Date? { dueDate }

    var isOverdue: Bool {
        guard !isCompleted, let due = dueDate else { return false }
        if dueHasTime { return due < Date() && kind != .event }
        return due < Calendar.current.startOfDay(for: Date())
    }
}

/// The editable fields of a task, used for both create and update.
struct TaskDraft: Equatable {
    var title: String = ""
    var notes: String = ""
    var dueDate: Date?
    var dueHasTime: Bool = false
    var priority: TaskPriority = .none

    init() {}

    init(from item: TaskItem) {
        title = item.title
        notes = item.notes
        dueDate = item.dueDate
        dueHasTime = item.dueHasTime
        priority = item.priority
    }
}

/// A place a new item can be created: a ClickUp list, Asana project, Google task list, calendar...
struct Destination: Identifiable, Hashable {
    var id: String { "\(accountID.uuidString)|\(source.rawValue)|\(containerID)" }
    let accountID: UUID
    let source: TaskSource
    let containerID: String
    let name: String
    var detail: String?
    var meta: [String: String] = [:]
}
