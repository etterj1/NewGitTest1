import Foundation

/// ClickUp API v2 using a personal API token (Settings → Apps → API Token, starts with "pk_").
/// Add one TaskHub account per ClickUp login; every workspace the login can see is included.
struct ClickUpProvider: TaskProvider {
    let account: Account
    private static let base = URL(string: "https://api.clickup.com/api/v2/")!

    // MARK: Connect

    static func connect(token: String) async throws -> (identity: String, options: [String: String]) {
        let me = try await HTTP.json(UserResponse.self, base, "user", headers: ["Authorization": token])
        return (me.user.email ?? me.user.username ?? "ClickUp", [AccountOption.userID.rawValue: String(me.user.id)])
    }

    // MARK: TaskProvider

    func fetchItems() async throws -> [TaskItem] {
        let userID = account.option(.userID)
        var items: [TaskItem] = []
        for team in try await teams() {
            var page = 0
            while page < 20 {
                var query = [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "subtasks", value: "true"),
                    URLQueryItem(name: "include_closed", value: "false"),
                    URLQueryItem(name: "order_by", value: "due_date"),
                ]
                if let userID { query.append(URLQueryItem(name: "assignees[]", value: userID)) }
                let response = try await get(TasksResponse.self, "team/\(team.id)/task", query: query)
                items += response.tasks.map { map($0, workspace: team.name) }
                if response.tasks.isEmpty || response.last_page ?? true { break }
                page += 1
            }
        }
        return items
    }

    func destinations() async throws -> [Destination] {
        var result: [Destination] = []
        for team in try await teams() {
            let spaces = try await get(SpacesResponse.self, "team/\(team.id)/space", query: [URLQueryItem(name: "archived", value: "false")]).spaces
            for space in spaces {
                let folders = try await get(FoldersResponse.self, "space/\(space.id)/folder", query: [URLQueryItem(name: "archived", value: "false")]).folders
                for folder in folders {
                    for list in folder.lists ?? [] {
                        result.append(destination(list: list, path: "\(space.name) › \(folder.name)", workspace: team.name))
                    }
                }
                let lists = try await get(ListsResponse.self, "space/\(space.id)/list", query: [URLQueryItem(name: "archived", value: "false")]).lists
                for list in lists {
                    result.append(destination(list: list, path: space.name, workspace: team.name))
                }
            }
        }
        return result
    }

    func create(_ draft: TaskDraft, in destination: Destination) async throws -> TaskItem {
        var body = fields(from: draft, clearing: false)
        if let userID = account.option(.userID), let id = Int(userID) { body["assignees"] = [id] }
        let task = try await send(ClickUpTask.self, "list/\(destination.containerID)/task", method: "POST", body: body)
        return map(task, workspace: destination.detail)
    }

    func update(_ item: TaskItem, with draft: TaskDraft) async throws -> TaskItem {
        let task = try await send(ClickUpTask.self, "task/\(item.externalID)", method: "PUT", body: fields(from: draft, clearing: true))
        var updated = map(task, workspace: nil)
        updated.project = updated.project ?? item.project
        return updated
    }

    func setCompleted(_ item: TaskItem, _ completed: Bool) async throws -> TaskItem {
        guard let listID = item.containerID else { throw APIError.api("This ClickUp task has no list.") }
        // Status names are per-list, so look up the list's "closed" / "open" status.
        let list = try await get(ListDetail.self, "list/\(listID)")
        let statuses = list.statuses ?? []
        let target: ClickUpStatus?
        if completed {
            target = statuses.first { $0.type == "closed" } ?? statuses.first { $0.type == "done" }
        } else {
            target = statuses.first { $0.type == "open" }
        }
        guard let status = target?.status else {
            throw APIError.api("Couldn't find a \(completed ? "closed" : "open") status on the list \"\(list.name ?? listID)\".")
        }
        _ = try await send(ClickUpTask.self, "task/\(item.externalID)", method: "PUT", body: ["status": status])
        var updated = item
        updated.isCompleted = completed
        updated.completedAt = completed ? Date() : nil
        updated.status = status
        return updated
    }

    // MARK: Helpers

    private var token: String { (try? CredentialStore.token(for: account.id)) ?? "" }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard !token.isEmpty else { throw APIError.missingCredential }
        return try await HTTP.json(T.self, Self.base, path, query: query, headers: ["Authorization": token])
    }

    private func send<T: Decodable>(_ type: T.Type, _ path: String, method: String, body: [String: Any]) async throws -> T {
        guard !token.isEmpty else { throw APIError.missingCredential }
        return try await HTTP.json(T.self, Self.base, path, method: method, headers: ["Authorization": token], body: .json(body))
    }

    private func teams() async throws -> [Team] {
        try await get(TeamsResponse.self, "team").teams
    }

    private func fields(from draft: TaskDraft, clearing: Bool) -> [String: Any] {
        var body: [String: Any] = ["name": draft.trimmedTitle, "description": draft.notes]
        if let due = draft.dueDate {
            let date = draft.dueHasTime ? due : Calendar.current.startOfDay(for: due)
            body["due_date"] = DateCoding.millisValue(date)
            body["due_date_time"] = draft.dueHasTime
        } else if clearing {
            body["due_date"] = NSNull()
        }
        switch draft.priority {
        case .urgent: body["priority"] = 1
        case .high: body["priority"] = 2
        case .normal: body["priority"] = 3
        case .low: body["priority"] = 4
        case .none: body["priority"] = NSNull()
        }
        return body
    }

    private func destination(list: NamedItem, path: String, workspace: String) -> Destination {
        Destination(accountID: account.id, source: .clickup, containerID: list.id, name: list.name, detail: "\(workspace) › \(path)")
    }

    private func map(_ task: ClickUpTask, workspace: String?) -> TaskItem {
        let due = DateCoding.millis(task.due_date)
        var item = TaskItem(accountID: account.id, source: .clickup, externalID: task.id, containerID: task.list?.id, title: task.name)
        item.notes = task.text_content ?? task.description ?? ""
        item.dueDate = due
        // ClickUp stores date-only due dates at a fixed hour; treat midnight/4am as "no time".
        if let due {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: due)
            item.dueHasTime = !((comps.hour == 0 || comps.hour == 4) && comps.minute == 0)
        }
        item.isCompleted = task.status?.type == "closed" || task.status?.type == "done"
        item.status = task.status?.status
        switch task.priority?.id {
        case "1": item.priority = .urgent
        case "2": item.priority = .high
        case "3": item.priority = .normal
        case "4": item.priority = .low
        default: item.priority = .none
        }
        let folder = (task.folder?.hidden ?? false) ? nil : task.folder?.name
        item.project = [folder, task.list?.name].compactMap { $0 }.joined(separator: " › ")
        if item.project?.isEmpty == true { item.project = workspace }
        item.requester = task.creator?.username
        item.webURL = task.url.flatMap(URL.init(string:))
        item.createdAt = DateCoding.millis(task.date_created)
        item.updatedAt = DateCoding.millis(task.date_updated)
        return item
    }

    // MARK: API models

    private struct UserResponse: Decodable {
        struct User: Decodable { let id: Int; let username: String?; let email: String? }
        let user: User
    }
    private struct Team: Decodable { let id: String; let name: String }
    private struct TeamsResponse: Decodable { let teams: [Team] }
    private struct NamedItem: Decodable { let id: String; let name: String }
    private struct SpacesResponse: Decodable { let spaces: [NamedItem] }
    private struct Folder: Decodable { let id: String; let name: String; let lists: [NamedItem]? }
    private struct FoldersResponse: Decodable { let folders: [Folder] }
    private struct ListsResponse: Decodable { let lists: [NamedItem] }
    private struct ClickUpStatus: Decodable { let status: String?; let type: String? }
    private struct ListDetail: Decodable { let name: String?; let statuses: [ClickUpStatus]? }
    private struct TasksResponse: Decodable { let tasks: [ClickUpTask]; let last_page: Bool? }
    private struct ClickUpTask: Decodable {
        struct Priority: Decodable { let id: String?; let priority: String? }
        struct ListRef: Decodable { let id: String; let name: String? }
        struct FolderRef: Decodable { let name: String?; let hidden: Bool? }
        struct Creator: Decodable { let username: String? }
        let id: String
        let name: String
        let description: String?
        let text_content: String?
        let status: ClickUpStatus?
        let due_date: String?
        let date_created: String?
        let date_updated: String?
        let priority: Priority?
        let list: ListRef?
        let folder: FolderRef?
        let creator: Creator?
        let url: String?
    }
}
