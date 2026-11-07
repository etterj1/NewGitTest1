import SwiftUI

enum DueFormatter {
    static func label(for item: TaskItem) -> String? {
        guard let due = item.dueDate else { return nil }
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(due) {
            day = "Today"
        } else if calendar.isDateInTomorrow(due) {
            day = "Tomorrow"
        } else if calendar.isDateInYesterday(due) {
            day = "Yesterday"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: due).day, (0..<7).contains(days) {
            day = due.formatted(.dateTime.weekday(.wide))
        } else {
            day = due.formatted(.dateTime.month(.abbreviated).day())
        }
        guard item.dueHasTime else { return day }
        return "\(day) \(due.formatted(date: .omitted, time: .shortened))"
    }
}

struct SourceBadge: View {
    let source: TaskSource
    var compact = false

    var body: some View {
        Label(compact ? "" : source.displayName, systemImage: source.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(source.color.opacity(0.15), in: Capsule())
            .foregroundStyle(source.color)
    }
}

extension SidebarFilter {
    @MainActor
    func title(in store: AppStore) -> String {
        switch self {
        case .board: return "Board"
        case .client(let id): return store.clients.first { $0.id == id }?.name ?? "Client"
        case .all: return "All Open"
        case .today: return "Today"
        case .upcoming: return "Next 7 Days"
        case .overdue: return "Overdue"
        case .noDate: return "No Date"
        case .completed: return "Completed"
        case .source(let source): return source.displayName
        case .account(let id): return store.account(for: id)?.displayName ?? "Account"
        case .project(let name): return name
        }
    }
}
