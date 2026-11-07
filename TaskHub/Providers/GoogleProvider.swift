import Foundation

/// One Google sign-in → Gmail (starred emails by default), Google Calendar (upcoming events)
/// and Google Tasks (all task lists). Sign in once per Google account.
struct GoogleProvider: TaskProvider {
    let account: Account

    private static let gmailBase = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    private static let calendarBase = URL(string: "https://www.googleapis.com/calendar/v3/")!
    private static let tasksBase = URL(string: "https://tasks.googleapis.com/tasks/v1/")!

    // MARK: TaskProvider

    func fetchItems() async throws -> [TaskItem] {
        var items: [TaskItem] = []
        var errors: [String] = []
        let sources = account.enabledSources

        await withTaskGroup(of: (TaskSource, Result<[TaskItem], Error>).self) { group in
            if sources.contains(.gmail) {
                group.addTask { await capture(.gmail) { try await fetchGmail() } }
            }
            if sources.contains(.googleCalendar) {
                group.addTask { await capture(.googleCalendar) { try await fetchCalendar() } }
            }
            if sources.contains(.googleTasks) {
                group.addTask { await capture(.googleTasks) { try await fetchTasks() } }
            }
            for await (source, result) in group {
                switch result {
                case .success(let fetched): items += fetched
                case .failure(let error): errors.append("\(source.displayName): \(error.localizedDescription)")
                }
            }
        }
        if !errors.isEmpty { throw PartialFetchError(items: items, messages: errors) }
        return items
    }

    func destinations() async throws -> [Destination] {
        var result: [Destination] = []
        if account.enabledSources.contains(.googleTasks) {
            let lists = try await get(ListResponse<TaskList>.self, Self.tasksBase, "users/@me/lists").items ?? []
            result += lists.map {
                Destination(accountID: account.id, source: .googleTasks, containerID: $0.id, name: $0.title ?? "Tasks", detail: "Google Tasks")
            }
        }
        if account.enabledSources.contains(.googleCalendar) {
            let calendars = try await calendars().filter { $0.accessRole == "owner" || $0.accessRole == "writer" }
            result += calendars.map {
                Destination(accountID: account.id, source: .googleCalendar, containerID: $0.id,
                            name: $0.summaryOverride ?? $0.summary ?? $0.id, detail: "Google Calendar")
            }
        }
        return result
    }

    func create(_ draft: TaskDraft, in destination: Destination) async throws -> TaskItem {
        switch destination.source {
        case .googleTasks:
            let task = try await send(GTask.self, Self.tasksBase, "lists/\(destination.containerID)/tasks",
                                      method: "POST", body: taskFields(draft, clearing: false))
            return map(task, listID: destination.containerID, listName: destination.name)
        case .googleCalendar:
            let start = draft.dueDate ?? Self.nextHour()
            var timed = draft
            timed.dueDate = start
            if draft.dueDate == nil { timed.dueHasTime = true }
            let event = try await send(GEvent.self, Self.calendarBase, "calendars/\(destination.containerID)/events",
                                       method: "POST", body: eventFields(timed, duration: 3600))
            return map(event, calendarID: destination.containerID, calendarName: destination.name)
        default:
            throw APIError.unsupported("Can't create \(destination.source.displayName) items.")
        }
    }

    func update(_ item: TaskItem, with draft: TaskDraft) async throws -> TaskItem {
        guard let container = item.containerID else { throw APIError.api("Missing list/calendar for this item.") }
        switch item.source {
        case .googleTasks:
            let task = try await send(GTask.self, Self.tasksBase, "lists/\(container)/tasks/\(item.externalID)",
                                      method: "PATCH", body: taskFields(draft, clearing: true))
            return map(task, listID: container, listName: item.project)
        case .googleCalendar:
            let duration = item.endDate.flatMap { end in item.dueDate.map { end.timeIntervalSince($0) } } ?? 3600
            let event = try await send(GEvent.self, Self.calendarBase, "calendars/\(container)/events/\(item.externalID)",
                                       method: "PATCH", body: eventFields(draft, duration: max(duration, 900)))
            return map(event, calendarID: container, calendarName: item.project)
        default:
            throw APIError.unsupported("Editing \(item.source.displayName) items isn't supported.")
        }
    }

    func setCompleted(_ item: TaskItem, _ completed: Bool) async throws -> TaskItem {
        var updated = item
        switch item.source {
        case .gmail:
            let labels = ["STARRED", "INBOX"]
            let body: [String: Any] = completed ? ["removeLabelIds": labels] : ["addLabelIds": labels]
            _ = try await send(GMessage.self, Self.gmailBase, "messages/\(item.externalID)/modify", method: "POST", body: body)
        case .googleTasks:
            guard let list = item.containerID else { throw APIError.api("Missing task list.") }
            let body: [String: Any] = completed ? ["status": "completed"] : ["status": "needsAction", "completed": NSNull()]
            let task = try await send(GTask.self, Self.tasksBase, "lists/\(list)/tasks/\(item.externalID)", method: "PATCH", body: body)
            updated = map(task, listID: list, listName: item.project)
        case .googleCalendar:
            break // Events can't be "completed"; TaskHub just hides them locally.
        default:
            throw APIError.unsupported("Unsupported source.")
        }
        updated.isCompleted = completed
        updated.completedAt = completed ? Date() : nil
        return updated
    }

    // MARK: Gmail

    private func fetchGmail() async throws -> [TaskItem] {
        let query = account.option(.gmailQuery) ?? OptionDefaults.gmailQuery
        let list = try await get(GMessageList.self, Self.gmailBase, "messages", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "50"),
        ])
        let ids = (list.messages ?? []).map(\.id)
        return try await withThrowingTaskGroup(of: TaskItem.self) { group in
            for id in ids {
                group.addTask {
                    let message = try await get(GMessage.self, Self.gmailBase, "messages/\(id)", query: [
                        URLQueryItem(name: "format", value: "metadata"),
                        URLQueryItem(name: "metadataHeaders", value: "Subject"),
                        URLQueryItem(name: "metadataHeaders", value: "From"),
                    ])
                    return map(message)
                }
            }
            var items: [TaskItem] = []
            for try await item in group { items.append(item) }
            return items
        }
    }

    private func map(_ message: GMessage) -> TaskItem {
        let headers = message.payload?.headers ?? []
        func header(_ name: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        let subject = header("Subject").flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)"
        var item = TaskItem(accountID: account.id, source: .gmail, externalID: message.id, containerID: message.threadId, title: subject)
        item.notes = (message.snippet ?? "").decodingHTMLEntities
        item.requester = header("From").map(Self.senderName)
        item.project = (message.labelIds ?? []).contains("IMPORTANT") ? "Inbox · Important" : "Inbox"
        item.createdAt = DateCoding.millis(message.internalDate)
        if let thread = message.threadId {
            var components = URLComponents(string: "https://mail.google.com/mail/")!
            components.queryItems = [URLQueryItem(name: "authuser", value: account.identity)]
            item.webURL = URL(string: (components.url?.absoluteString ?? "https://mail.google.com/mail/") + "#all/\(thread)")
        }
        return item
    }

    /// `"Jane Doe" <jane@x.com>` → `Jane Doe`
    private static func senderName(_ from: String) -> String {
        if let bracket = from.firstIndex(of: "<") {
            let name = from[..<bracket].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
            if !name.isEmpty { return name }
        }
        return from.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    // MARK: Calendar

    private func calendars() async throws -> [GCalendar] {
        try await get(ListResponse<GCalendar>.self, Self.calendarBase, "users/me/calendarList").items ?? []
    }

    private func fetchCalendar() async throws -> [TaskItem] {
        let days = Int(account.option(.calendarDaysAhead) ?? "") ?? OptionDefaults.calendarDaysAhead
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let calendars = try await calendars().filter { $0.selected ?? ($0.primary ?? false) }

        return try await withThrowingTaskGroup(of: [TaskItem].self) { group in
            for calendar in calendars {
                group.addTask {
                    let events = try await get(ListResponse<GEvent>.self, Self.calendarBase, "calendars/\(calendar.id)/events", query: [
                        URLQueryItem(name: "timeMin", value: DateCoding.isoString(start)),
                        URLQueryItem(name: "timeMax", value: DateCoding.isoString(end)),
                        URLQueryItem(name: "singleEvents", value: "true"),
                        URLQueryItem(name: "orderBy", value: "startTime"),
                        URLQueryItem(name: "maxResults", value: "250"),
                    ]).items ?? []
                    return events
                        .filter { event in
                            event.status != "cancelled"
                                && event.eventType != "workingLocation"
                                && !(event.attendees ?? []).contains { $0.isSelf == true && $0.responseStatus == "declined" }
                        }
                        .map { map($0, calendarID: calendar.id, calendarName: calendar.summaryOverride ?? calendar.summary) }
                }
            }
            var items: [TaskItem] = []
            for try await batch in group { items += batch }
            return items
        }
    }

    private func map(_ event: GEvent, calendarID: String, calendarName: String?) -> TaskItem {
        var item = TaskItem(accountID: account.id, source: .googleCalendar, externalID: event.id,
                            containerID: calendarID, title: event.summary ?? "(no title)")
        item.notes = event.description ?? ""
        if let dateTime = DateCoding.iso(event.start?.dateTime) {
            item.dueDate = dateTime
            item.dueHasTime = true
            item.endDate = DateCoding.iso(event.end?.dateTime)
        } else {
            item.dueDate = DateCoding.day(event.start?.date)
            item.endDate = DateCoding.day(event.end?.date)
        }
        item.project = calendarName
        if event.organizer?.isSelf != true {
            item.requester = event.organizer?.displayName ?? event.organizer?.email
        }
        item.webURL = event.htmlLink.flatMap(URL.init(string:))
        item.updatedAt = DateCoding.iso(event.updated)
        return item
    }

    private func eventFields(_ draft: TaskDraft, duration: TimeInterval) -> [String: Any] {
        var body: [String: Any] = ["summary": draft.trimmedTitle, "description": draft.notes]
        if let start = draft.dueDate {
            if draft.dueHasTime {
                body["start"] = ["dateTime": DateCoding.isoString(start)]
                body["end"] = ["dateTime": DateCoding.isoString(start.addingTimeInterval(duration))]
            } else {
                let day = Calendar.current.startOfDay(for: start)
                let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
                body["start"] = ["date": DateCoding.dayString(day)]
                body["end"] = ["date": DateCoding.dayString(next)]
            }
        }
        return body
    }

    private static func nextHour() -> Date {
        let now = Date()
        let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        return hour.addingTimeInterval(3600)
    }

    // MARK: Tasks

    private func fetchTasks() async throws -> [TaskItem] {
        let lists = try await get(ListResponse<TaskList>.self, Self.tasksBase, "users/@me/lists", query: [
            URLQueryItem(name: "maxResults", value: "100"),
        ]).items ?? []
        return try await withThrowingTaskGroup(of: [TaskItem].self) { group in
            for list in lists {
                group.addTask {
                    let tasks = try await get(ListResponse<GTask>.self, Self.tasksBase, "lists/\(list.id)/tasks", query: [
                        URLQueryItem(name: "showCompleted", value: "false"),
                        URLQueryItem(name: "showHidden", value: "false"),
                        URLQueryItem(name: "maxResults", value: "100"),
                    ]).items ?? []
                    return tasks
                        .filter { !($0.title ?? "").isEmpty }
                        .map { map($0, listID: list.id, listName: list.title) }
                }
            }
            var items: [TaskItem] = []
            for try await batch in group { items += batch }
            return items
        }
    }

    private func map(_ task: GTask, listID: String, listName: String?) -> TaskItem {
        var item = TaskItem(accountID: account.id, source: .googleTasks, externalID: task.id,
                            containerID: listID, title: task.title ?? "Untitled task")
        item.notes = task.notes ?? ""
        item.dueDate = DateCoding.googleTasksDue(task.due)
        item.isCompleted = task.status == "completed"
        item.completedAt = DateCoding.iso(task.completed)
        item.project = listName
        item.webURL = task.webViewLink.flatMap(URL.init(string:))
        item.updatedAt = DateCoding.iso(task.updated)
        return item
    }

    private func taskFields(_ draft: TaskDraft, clearing: Bool) -> [String: Any] {
        var body: [String: Any] = ["title": draft.trimmedTitle, "notes": draft.notes]
        if let due = draft.dueDate {
            body["due"] = DateCoding.googleTasksDueString(due)
        } else if clearing {
            body["due"] = NSNull()
        }
        return body
    }

    // MARK: HTTP

    private func authHeaders() async throws -> [String: String] {
        ["Authorization": "Bearer \(try await GoogleTokenManager.shared.accessToken(for: account.id))"]
    }

    private func get<T: Decodable>(_ type: T.Type, _ base: URL, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await HTTP.json(T.self, base, path, query: query, headers: try await authHeaders())
    }

    private func send<T: Decodable>(_ type: T.Type, _ base: URL, _ path: String, method: String, body: [String: Any]) async throws -> T {
        try await HTTP.json(T.self, base, path, method: method, headers: try await authHeaders(), body: .json(body))
    }

    // MARK: API models

    private struct ListResponse<T: Decodable>: Decodable { let items: [T]? }
    private struct GMessageList: Decodable {
        struct Ref: Decodable { let id: String }
        let messages: [Ref]?
    }
    private struct GMessage: Decodable {
        struct Payload: Decodable { let headers: [Header]? }
        struct Header: Decodable { let name: String; let value: String }
        let id: String
        let threadId: String?
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Payload?
    }
    private struct GCalendar: Decodable {
        let id: String
        let summary: String?
        let summaryOverride: String?
        let primary: Bool?
        let selected: Bool?
        let accessRole: String?
    }
    private struct GEvent: Decodable {
        struct When: Decodable { let date: String?; let dateTime: String? }
        struct Person: Decodable {
            let email: String?
            let displayName: String?
            let isSelf: Bool?
            let responseStatus: String?
            enum CodingKeys: String, CodingKey { case email, displayName, responseStatus, isSelf = "self" }
        }
        let id: String
        let status: String?
        let summary: String?
        let description: String?
        let htmlLink: String?
        let updated: String?
        let eventType: String?
        let start: When?
        let end: When?
        let organizer: Person?
        let attendees: [Person]?
    }
    private struct TaskList: Decodable { let id: String; let title: String? }
    private struct GTask: Decodable {
        let id: String
        let title: String?
        let notes: String?
        let due: String?
        let status: String?
        let completed: String?
        let updated: String?
        let webViewLink: String?
    }
}

private func capture(
    _ source: TaskSource,
    _ body: () async throws -> [TaskItem]
) async -> (TaskSource, Result<[TaskItem], Error>) {
    do { return (source, .success(try await body())) } catch { return (source, .failure(error)) }
}
