import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct TaskListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL

    let filter: SidebarFilter
    @Binding var selection: TaskItem.ID?
    @Binding var showingNewTask: Bool

    @State private var search = ""

    var body: some View {
        let items = store.items(matching: filter, search: search)
        let groups = Dictionary(grouping: items) { DateBucket.of($0) }

        List(selection: $selection) {
            ForEach(DateBucket.allCases) { bucket in
                if let bucketItems = groups[bucket], !bucketItems.isEmpty {
                    Section {
                        ForEach(bucketItems) { item in
                            TaskRowView(item: item, accountName: store.account(for: item.accountID)?.displayName ?? "") {
                                Task { await store.toggleCompleted(item) }
                            }
                            .tag(item.id)
                            .contextMenu { menu(for: item) }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await store.toggleCompleted(item) }
                                } label: {
                                    Label(item.isCompleted ? "Reopen" : "Done", systemImage: item.isCompleted ? "arrow.uturn.backward" : "checkmark")
                                }
                                .tint(.green)
                            }
                        }
                    } header: {
                        Text("\(bucket.title) · \(bucketItems.count)")
                            .foregroundStyle(bucket == .overdue ? Color.red : Color.secondary)
                    }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                if store.isRefreshing {
                    ProgressView("Syncing…")
                } else if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ContentUnavailableView("All clear", systemImage: "checkmark.seal",
                                           description: Text("Nothing here. Add accounts or a task to get started."))
                }
            }
        }
        .searchable(text: $search, prompt: "Search tasks, people, projects")
        .navigationTitle(filter.title(in: store))
        .refreshable { await store.refreshAll() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewTask = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isRefreshing)
            }
        }
    }

    @ViewBuilder
    private func menu(for item: TaskItem) -> some View {
        Button(item.isCompleted ? "Mark as Not Done" : "Mark as Done") {
            Task { await store.toggleCompleted(item) }
        }
        if let url = item.webURL {
            Button("Open in \(item.source.displayName)") { openURL(url) }
        }
        Button("Copy Title") { Clipboard.copy(item.title) }
    }
}

enum Clipboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

struct TaskRowView: View {
    let item: TaskItem
    let accountName: String
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: checkboxSymbol)
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? Color.green : item.source.color.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(item.source.completionHint)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    SourceBadge(source: item.source)
                    if let project = item.project, !project.isEmpty {
                        Text(project).lineLimit(1)
                    }
                    if let requester = item.requester, !requester.isEmpty {
                        Text("· \(requester)").lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !accountName.isEmpty {
                    Text(accountName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                if let due = DueFormatter.label(for: item) {
                    Text(due)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(item.isOverdue ? Color.red : Color.secondary)
                } else if let created = item.createdAt, item.kind != .task {
                    Text(created.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if item.priority >= .high {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(item.priority.color)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var checkboxSymbol: String {
        if item.isCompleted { return "checkmark.circle.fill" }
        switch item.kind {
        case .event: return "calendar.circle"
        case .email: return "envelope.circle"
        case .message: return "bubble.left.circle"
        case .task: return "circle"
        }
    }
}
