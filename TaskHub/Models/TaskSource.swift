import SwiftUI

/// The kind of account a user connects. One account can feed several sources
/// (e.g. one Google sign-in provides Gmail, Google Calendar and Google Tasks).
enum AccountKind: String, Codable, CaseIterable, Identifiable {
    case clickup, asana, slack, google, apple, local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clickup: return "ClickUp"
        case .asana: return "Asana"
        case .slack: return "Slack"
        case .google: return "Google (Gmail, Calendar, Tasks)"
        case .apple: return "Apple (Reminders, Calendar)"
        case .local: return "On this device"
        }
    }

    var symbol: String {
        switch self {
        case .clickup: return "checklist"
        case .asana: return "circle.hexagongrid"
        case .slack: return "number"
        case .google: return "g.circle"
        case .apple: return "applelogo"
        case .local: return "iphone.and.arrow.forward"
        }
    }

    /// Sources this account kind can provide.
    var sources: [TaskSource] {
        switch self {
        case .clickup: return [.clickup]
        case .asana: return [.asana]
        case .slack: return [.slack]
        case .google: return [.gmail, .googleCalendar, .googleTasks]
        case .apple: return [.appleReminders, .appleCalendar]
        case .local: return [.local]
        }
    }
}

/// Where an individual item came from.
enum TaskSource: String, Codable, CaseIterable, Identifiable, Hashable {
    case clickup, asana, slack, gmail, googleCalendar, googleTasks, appleReminders, appleCalendar, local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clickup: return "ClickUp"
        case .asana: return "Asana"
        case .slack: return "Slack"
        case .gmail: return "Gmail"
        case .googleCalendar: return "Google Calendar"
        case .googleTasks: return "Google Tasks"
        case .appleReminders: return "Reminders"
        case .appleCalendar: return "Apple Calendar"
        case .local: return "TaskHub"
        }
    }

    var symbol: String {
        switch self {
        case .clickup: return "checklist"
        case .asana: return "circle.hexagongrid"
        case .slack: return "number"
        case .gmail: return "envelope"
        case .googleCalendar, .appleCalendar: return "calendar"
        case .googleTasks: return "checkmark.circle"
        case .appleReminders: return "list.bullet.circle"
        case .local: return "tray"
        }
    }

    var color: Color {
        switch self {
        case .clickup: return Color(red: 0.48, green: 0.33, blue: 0.96)
        case .asana: return Color(red: 0.94, green: 0.42, blue: 0.42)
        case .slack: return Color(red: 0.29, green: 0.08, blue: 0.29)
        case .gmail: return Color(red: 0.86, green: 0.27, blue: 0.22)
        case .googleCalendar: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .googleTasks: return Color(red: 0.10, green: 0.45, blue: 0.91)
        case .appleReminders: return .orange
        case .appleCalendar: return .red
        case .local: return .gray
        }
    }

    var accountKind: AccountKind {
        switch self {
        case .clickup: return .clickup
        case .asana: return .asana
        case .slack: return .slack
        case .gmail, .googleCalendar, .googleTasks: return .google
        case .appleReminders, .appleCalendar: return .apple
        case .local: return .local
        }
    }

    var itemKind: ItemKind {
        switch self {
        case .gmail: return .email
        case .slack: return .message
        case .googleCalendar, .appleCalendar: return .event
        default: return .task
        }
    }

    /// New items can be created here from TaskHub.
    var canCreate: Bool {
        switch self {
        case .slack, .gmail: return false
        default: return true
        }
    }

    /// Title/notes/date edits are pushed back to the source app.
    var canEdit: Bool { canCreate }

    var supportsPriority: Bool {
        switch self {
        case .clickup, .appleReminders, .local: return true
        default: return false
        }
    }

    var supportsNotes: Bool { true }

    /// Whether the due date may carry a time of day.
    var supportsDueTime: Bool {
        switch self {
        case .googleTasks: return false // Google Tasks API stores dates only
        default: return true
        }
    }

    /// What "mark done" does in the source app — shown in the UI so it's never a surprise.
    var completionHint: String {
        switch self {
        case .gmail: return "Marking done un-stars and archives the email in Gmail."
        case .slack: return "Marking done adds a ✅ reaction to the message in Slack."
        case .googleCalendar, .appleCalendar: return "Marking an event done only hides it in TaskHub."
        case .clickup: return "Marking done moves the task to its list's closed status in ClickUp."
        default: return "Marking done completes it in \(displayName)."
        }
    }
}

enum ItemKind: String, Codable {
    case task, email, message, event
}

enum TaskPriority: Int, Codable, CaseIterable, Identifiable, Comparable {
    case none = 0, low = 1, normal = 2, high = 3, urgent = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }

    var color: Color {
        switch self {
        case .none: return .secondary
        case .low: return .gray
        case .normal: return .blue
        case .high: return .orange
        case .urgent: return .red
        }
    }

    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}
