import Foundation

/// Asana API using a Personal Access Token (My Settings → Apps → Developer apps → Personal access token).
/// Includes tasks assigned to you in every workspace the token can see.
struct AsanaProvider: TaskProvider {
    let account: Account
    private static let base = URL(string: "https://app.asana.com/api/1.0/")!
    private static let taskFields = "name,notes,due_on,due_at,completed,completed_at,permalink_url,created_at,modified_at,projects.name,workspace.gid"

    static func connect(token: String) async throws -> (identity: String, options: [String: String]) {
        let me = try await HTTP.json(
            Envelope<User>.self, base, "users/me",
            query: [URLQueryItem(name: "opt_fields", value: "name,email")],
            headers: ["Authorization": "Bearer \(token)"]
        ).data
        return (me.email ?? me.name ?? "Asana", [AccountOption.userID.rawValue: me.gid])
    }

    func fetchItems() async throws -> [TaskItem] {
        var items: [TaskItem] = []
        for workspace in try await workspaces() {
            var offset: String?
            repeat {
                var query = [
                    URLQueryItem(name: "assignee", value: "me"),
                    URLQueryItem(name: "workspace", value: workspace.gid),
                    URLQueryItem(name: "completed_since", value: "now"),
                    URLQueryItem(name: "limit", value: "100"),
                    URLQueryItem(name: "opt_fields", value: Self.taskFields),
                ]
                if let offset { query.append(URLQueryItem(name: "offset", value: offset)) }
                let page = try await get(Envelope<[AsanaTask]>.self, "tasks", query: query)
                items += page.data.map { map($0, workspace: workspace) }
                offset = page.next_page?.offset
            } while offset != nil && items.count < 2000
        }
        return items
    }

    func destinations() async throws -> [Destination] {
        var result: [Destination] = []
        for workspace in try await workspaces() {
            result.append(Destination(
                accountID: account.id, source: .asana, containerID: "ws:\(workspace.gid)",
                name: "My Tasks", detail: workspace.name, meta: ["workspace": workspace.gid]
            ))
            let projects = try await get(Envelope<[Named]>.self, "projects", query: [
                URLQueryItem(name: "workspace", value: workspace.gid),
                URLQueryItem(name: "archived", value: "false"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "opt_fields", value: "name"),
            ]).data
            for project in projects {
                result.append(Destination(
                    accountID: account.id, source: .asana, containerID: "proj:\(project.gid)",
                    name: project.name ?? "Untitled project", detail: workspace.name,
                    meta: ["workspace": workspace.gid, "project": project.gid]
                ))
            }
        }
        return result
    }

    func create(_ draft: TaskDraft, in destination: Destination) async throws -> TaskItem {
        var data = fields(from: draft, clearing: false)
        data["assignee"] = "me"
        data["workspace"] = destination.meta["workspace"]
        if let project = destination.meta["project"] { data["projects"] = [project] }
        let task = try await send("tasks", method: "POST", data: data)
        return map(task, workspace: Named(gid: destination.meta["workspace"] ?? "", name: destination.detail))
    }

    func update(_ item: TaskItem, with draft: TaskDraft) async throws -> TaskItem {
        let task = try await send("tasks/\(item.externalID)", method: "PUT", data: fields(from: draft, clearing: true))
        return map(task, workspace: nil)
    }

    func setCompleted(_ item: TaskItem, _ completed: Bool) async throws -> TaskItem {
        let task = try await send("tasks/\(item.externalID)", method: "PUT", data: ["completed": completed])
        var updated = map(task, workspace: nil)
        updated.completedAt = completed ? Date() : nil
        return updated
    }

    // MARK: Helpers

    private func headers() throws -> [String: String] {
        ["Authorization": "Bearer \(try CredentialStore.token(for: account.id))"]
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await HTTP.json(T.self, Self.base, path, query: query, headers: try headers())
    }

    private func send(_ path: String, method: String, data: [String: Any]) async throws -> AsanaTask {
        try await HTTP.json(
            Envelope<AsanaTask>.self, Self.base, path, method: method,
            query: [URLQueryItem(name: "opt_fields", value: Self.taskFields)],
            headers: try headers(), body: .json(["data": data])
        ).data
    }

    private func workspaces() async throws -> [Named] {
        try await get(Envelope<[Named]>.self, "workspaces", query: [URLQueryItem(name: "limit", value: "100")]).data
    }

    private func fields(from draft: TaskDraft, clearing: Bool) -> [String: Any] {
        var data: [String: Any] = ["name": draft.trimmedTitle, "notes": draft.notes]
        if let due = draft.dueDate {
            if draft.dueHasTime {
                data["due_at"] = DateCoding.isoString(due)
            } else {
                // Setting due_on replaces any due_at (they're mutually exclusive in Asana).
                data["due_on"] = DateCoding.dayString(due)
            }
        } else if clearing {
            data["due_on"] = NSNull()
        }
        return data
    }

    private func map(_ task: AsanaTask, workspace: Named?) -> TaskItem {
        var item = TaskItem(accountID: account.id, source: .asana, externalID: task.gid,
                            containerID: task.workspace?.gid ?? workspace?.gid, title: task.name ?? "Untitled task")
        item.notes = task.notes ?? ""
        if let dueAt = DateCoding.iso(task.due_at) {
            item.dueDate = dueAt
            item.dueHasTime = true
        } else {
            item.dueDate = DateCoding.day(task.due_on)
        }
        item.isCompleted = task.completed ?? false
        item.completedAt = DateCoding.iso(task.completed_at)
        let projects = (task.projects ?? []).compactMap(\.name)
        item.project = projects.isEmpty ? workspace?.name : projects.joined(separator: ", ")
        item.webURL = task.permalink_url.flatMap(URL.init(string:))
        item.createdAt = DateCoding.iso(task.created_at)
        item.updatedAt = DateCoding.iso(task.modified_at)
        return item
    }

    // MARK: API models

    private struct Envelope<T: Decodable>: Decodable {
        struct NextPage: Decodable { let offset: String? }
        let data: T
        let next_page: NextPage?
    }
    private struct User: Decodable { let gid: String; let name: String?; let email: String? }
    private struct Named: Decodable { let gid: String; let name: String? }
    private struct AsanaTask: Decodable {
        struct Ref: Decodable { let gid: String }
        let gid: String
        let name: String?
        let notes: String?
        let due_on: String?
        let due_at: String?
        let completed: Bool?
        let completed_at: String?
        let permalink_url: String?
        let created_at: String?
        let modified_at: String?
        let projects: [Named]?
        let workspace: Ref?
    }
}
