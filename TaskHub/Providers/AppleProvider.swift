import EventKit
import Foundation

/// Apple Reminders + Calendar through EventKit. This covers every account configured on the
/// device (iCloud, Exchange, Google/CalDAV, ...) — the account name shows up as the item's project.
struct AppleProvider: TaskProvider {
    let account: Account
    static let store = EKEventStore()

    static func requestAccess() async throws -> (reminders: Bool, calendar: Bool) {
        let reminders = try await store.requestFullAccessToReminders()
        let calendar = try await store.requestFullAccessToEvents()
        return (reminders, calendar)
    }

    private static var hasReminderAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    private static var hasEventAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    // MARK: TaskProvider

    func fetchItems() async throws -> [TaskItem] {
        var items: [TaskItem] = []
        var problems: [String] = []

        if account.enabledSources.contains(.appleReminders) {
            if Self.hasReminderAccess {
                let predicate = Self.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
                let reminders: [EKReminder] = await withCheckedContinuation { continuation in
                    _ = Self.store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
                }
                items += reminders.map(mapReminder)
            } else {
                problems.append("Reminders: access not granted. Enable it in System Settings → Privacy & Security → Reminders.")
            }
        }

        if account.enabledSources.contains(.appleCalendar) {
            if Self.hasEventAccess {
                let days = Int(account.option(.calendarDaysAhead) ?? "") ?? OptionDefaults.calendarDaysAhead
                let start = Calendar.current.startOfDay(for: Date())
                let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
                let predicate = Self.store.predicateForEvents(withStart: start, end: end, calendars: nil)
                items += Self.store.events(matching: predicate)
                    .filter { $0.status != .canceled && !Self.isDeclined($0) }
                    .map(mapEvent)
            } else {
                problems.append("Calendar: access not granted. Enable it in System Settings → Privacy & Security → Calendars.")
            }
        }

        if !problems.isEmpty { throw PartialFetchError(items: items, messages: problems) }
        return items
    }

    func destinations() async throws -> [Destination] {
        var result: [Destination] = []
        if account.enabledSources.contains(.appleReminders), Self.hasReminderAccess {
            result += Self.store.calendars(for: .reminder)
                .filter(\.allowsContentModifications)
                .map { Destination(accountID: account.id, source: .appleReminders, containerID: $0.calendarIdentifier,
                                   name: $0.title, detail: "Reminders · \(Self.sourceTitle($0))") }
        }
        if account.enabledSources.contains(.appleCalendar), Self.hasEventAccess {
            result += Self.store.calendars(for: .event)
                .filter(\.allowsContentModifications)
                .map { Destination(accountID: account.id, source: .appleCalendar, containerID: $0.calendarIdentifier,
                                   name: $0.title, detail: "Calendar · \(Self.sourceTitle($0))") }
        }
        return result
    }

    func create(_ draft: TaskDraft, in destination: Destination) async throws -> TaskItem {
        guard let calendar = Self.store.calendar(withIdentifier: destination.containerID) else {
            throw APIError.api("That list or calendar no longer exists.")
        }
        switch destination.source {
        case .appleReminders:
            let reminder = EKReminder(eventStore: Self.store)
            reminder.calendar = calendar
            apply(draft, to: reminder)
            try Self.store.save(reminder, commit: true)
            return mapReminder(reminder)
        case .appleCalendar:
            let event = EKEvent(eventStore: Self.store)
            event.calendar = calendar
            let start = draft.dueDate ?? Date().addingTimeInterval(3600)
            event.title = draft.trimmedTitle
            event.notes = draft.notes.isEmpty ? nil : draft.notes
            event.isAllDay = draft.dueDate != nil && !draft.dueHasTime
            event.startDate = event.isAllDay ? Calendar.current.startOfDay(for: start) : start
            event.endDate = event.isAllDay ? event.startDate : start.addingTimeInterval(3600)
            try Self.store.save(event, span: .thisEvent, commit: true)
            return mapEvent(event)
        default:
            throw APIError.unsupported("Unsupported destination.")
        }
    }

    func update(_ item: TaskItem, with draft: TaskDraft) async throws -> TaskItem {
        switch item.source {
        case .appleReminders:
            let reminder = try findReminder(item)
            apply(draft, to: reminder)
            try Self.store.save(reminder, commit: true)
            return mapReminder(reminder)
        case .appleCalendar:
            let event = try findEvent(item)
            let duration = max(event.endDate.timeIntervalSince(event.startDate), 900)
            event.title = draft.trimmedTitle
            event.notes = draft.notes.isEmpty ? nil : draft.notes
            if let start = draft.dueDate {
                event.isAllDay = !draft.dueHasTime
                event.startDate = event.isAllDay ? Calendar.current.startOfDay(for: start) : start
                event.endDate = event.isAllDay ? event.startDate : start.addingTimeInterval(duration)
            }
            try Self.store.save(event, span: .thisEvent, commit: true)
            return mapEvent(event)
        default:
            throw APIError.unsupported("Unsupported source.")
        }
    }

    func setCompleted(_ item: TaskItem, _ completed: Bool) async throws -> TaskItem {
        var updated = item
        if item.source == .appleReminders {
            let reminder = try findReminder(item)
            reminder.isCompleted = completed
            try Self.store.save(reminder, commit: true)
            updated = mapReminder(reminder)
        }
        // Calendar events are only hidden locally.
        updated.isCompleted = completed
        updated.completedAt = completed ? Date() : nil
        return updated
    }

    // MARK: Mapping

    private func mapReminder(_ reminder: EKReminder) -> TaskItem {
        var item = TaskItem(accountID: account.id, source: .appleReminders, externalID: reminder.calendarItemIdentifier,
                            containerID: Self.calendar(of: reminder)?.calendarIdentifier, title: reminder.title ?? "Untitled reminder")
        item.notes = reminder.notes ?? ""
        if let components = reminder.dueDateComponents {
            item.dueDate = Calendar.current.date(from: components)
            item.dueHasTime = components.hour != nil
        }
        item.isCompleted = reminder.isCompleted
        item.completedAt = reminder.completionDate
        switch reminder.priority {
        case 1...4: item.priority = .high
        case 5: item.priority = .normal
        case 6...9: item.priority = .low
        default: item.priority = .none
        }
        if let calendar = Self.calendar(of: reminder) {
            item.project = "\(calendar.title) · \(Self.sourceTitle(calendar))"
        }
        item.webURL = reminder.url
        item.createdAt = reminder.creationDate
        item.updatedAt = reminder.lastModifiedDate
        return item
    }

    private func mapEvent(_ event: EKEvent) -> TaskItem {
        let start = event.startDate ?? Date()
        let identifier = "\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(Int(start.timeIntervalSince1970))"
        var item = TaskItem(accountID: account.id, source: .appleCalendar, externalID: identifier,
                            containerID: Self.calendar(of: event)?.calendarIdentifier, title: event.title ?? "(no title)")
        item.notes = event.notes ?? ""
        item.dueDate = start
        item.endDate = event.endDate
        item.dueHasTime = !event.isAllDay
        if let calendar = Self.calendar(of: event) { item.project = "\(calendar.title) · \(Self.sourceTitle(calendar))" }
        if let organizer = event.organizer, !organizer.isCurrentUser { item.requester = organizer.name }
        item.webURL = event.url
        item.updatedAt = event.lastModifiedDate
        return item
    }

    private func apply(_ draft: TaskDraft, to reminder: EKReminder) {
        reminder.title = draft.trimmedTitle
        reminder.notes = draft.notes.isEmpty ? nil : draft.notes
        if let due = draft.dueDate {
            let fields: Set<Calendar.Component> = draft.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: due)
        } else {
            reminder.dueDateComponents = nil
        }
        switch draft.priority {
        case .urgent, .high: reminder.priority = 1
        case .normal: reminder.priority = 5
        case .low: reminder.priority = 9
        case .none: reminder.priority = 0
        }
    }

    // MARK: Lookup

    private func findReminder(_ item: TaskItem) throws -> EKReminder {
        guard let reminder = Self.store.calendarItem(withIdentifier: item.externalID) as? EKReminder else {
            throw APIError.api("This reminder no longer exists.")
        }
        return reminder
    }

    private func findEvent(_ item: TaskItem) throws -> EKEvent {
        let parts = item.externalID.split(separator: "|").map(String.init)
        guard let identifier = parts.first else { throw APIError.api("Invalid event reference.") }
        // For recurring events, find the specific occurrence by its start time.
        if parts.count == 2, let seconds = TimeInterval(parts[1]) {
            let start = Date(timeIntervalSince1970: seconds)
            let predicate = Self.store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(60), calendars: nil)
            if let match = Self.store.events(matching: predicate).first(where: { $0.eventIdentifier == identifier }) {
                return match
            }
        }
        guard let event = Self.store.event(withIdentifier: identifier) else {
            throw APIError.api("This event no longer exists.")
        }
        return event
    }

    // EventKit's nullability annotations vary by SDK; normalise to optionals.
    private static func calendar(of item: EKCalendarItem) -> EKCalendar? {
        let calendar: EKCalendar? = item.calendar
        return calendar
    }

    private static func sourceTitle(_ calendar: EKCalendar) -> String {
        let source: EKSource? = calendar.source
        return source?.title ?? "On My Device"
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        (event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }
}
