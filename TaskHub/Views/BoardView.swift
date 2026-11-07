import SwiftUI

/// Now / Next / Someday board across every connected app, color-coded by client.
struct BoardView: View {
    @Environment(AppStore.self) private var store
    @Binding var showingNewTask: Bool

    @State private var clientFilter: UUID?
    @State private var selectedID: TaskItem.ID?
    @State private var compactLane: BoardLane = .now
    @State private var aiRequest: AIRequest?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            legend
            if isCompact {
                Picker("Lane", selection: $compactLane) {
                    ForEach(BoardLane.allCases) { lane in
                        Text("\(lane.title) (\(store.boardItems(in: lane, client: clientFilter).count))").tag(lane)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                ScrollView { laneCards(compactLane).padding(.horizontal) }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(BoardLane.allCases) { lane in
                        laneColumn(lane)
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Board")
        .refreshable { await store.refreshAll() }
        .inspector(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
            if let id = selectedID, let item = store.items.first(where: { $0.id == id }) {
                NavigationStack { TaskDetailView(item: item).id(item.id) }
                    .inspectorColumnWidth(min: 320, ideal: 380)
            }
        }
        .sheet(item: $aiRequest) { AssistantView(request: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewTask = true } label: { Label("New Task", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let open = store.items(matching: .board)
                    aiRequest = AIRequest(title: "Daily briefing",
                                          context: "My open items (\(open.count) total):\n" + AIPrompts.describe(list: open),
                                          initialPrompt: AIPrompts.briefing, webSearch: false)
                } label: { Label("Daily Briefing", systemImage: "sparkles") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await store.refreshAll() } } label: {
                    if store.isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isRefreshing)
            }
        }
    }

    // MARK: Legend / client filter

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", color: .secondary, selected: clientFilter == nil) { clientFilter = nil }
                ForEach(store.clients) { client in
                    let count = store.count(for: .client(client.id))
                    if count > 0 {
                        chip("\(client.name) \(count)", color: client.color, selected: clientFilter == client.id) {
                            clientFilter = clientFilter == client.id ? nil : client.id
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func chip(_ title: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(title).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? color.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Lanes

    private func laneColumn(_ lane: BoardLane) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lane.title.uppercased())
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("\(store.boardItems(in: lane, client: clientFilter).count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            .padding(.bottom, 6)
            Divider()
            ScrollView { laneCards(lane).padding(.vertical, 8) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dropDestination(for: String.self) { ids, _ in
            for id in ids {
                if let item = store.items.first(where: { $0.id == id }) { store.move(item, to: lane) }
            }
            return true
        }
    }

    private func laneCards(_ lane: BoardLane) -> some View {
        let items = store.boardItems(in: lane, client: clientFilter)
        return LazyVStack(spacing: 10) {
            if items.isEmpty {
                Text(lane == .now ? "Nothing urgent 🎉" : "Empty")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            ForEach(items) { item in
                BoardCard(item: item, client: store.client(for: item), title: store.boardTitle(for: item),
                          isSelected: selectedID == item.id)
                    .onTapGesture { selectedID = item.id }
                    .draggable(item.id)
                    .contextMenu { menu(for: item, current: lane) }
            }
        }
    }

    @ViewBuilder
    private func menu(for item: TaskItem, current: BoardLane) -> some View {
        Button("Mark as Done") { Task { await store.setCompleted(item, true) } }
        if !item.isOverdue {
            ForEach(BoardLane.allCases.filter { $0 != current }) { lane in
                Button("Move to \(lane.title)") { store.move(item, to: lane) }
            }
        }
        if let url = item.webURL {
            Link("Open in \(item.source.displayName)", destination: url)
        }
    }
}

struct BoardCard: View {
    let item: TaskItem
    let client: ClientTag?
    let title: String
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(client?.color ?? .secondary).frame(width: 9, height: 9)
                Text((client?.name ?? item.project ?? item.source.displayName).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(client?.color ?? .secondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: item.source.symbol)
                    .font(.caption)
                    .foregroundStyle(item.source.color)
                    .help(item.source.displayName)
            }
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let due = DueFormatter.label(for: item) {
                    Text(item.isOverdue ? "Overdue · \(due)" : "Due \(due)")
                        .font(.caption.weight(item.isOverdue || isDueToday ? .bold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(chipColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(chipColor)
                } else if let requester = item.requester {
                    Text("From \(requester)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if item.priority >= .high {
                    Image(systemName: "flag.fill").font(.caption).foregroundStyle(item.priority.color)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var isDueToday: Bool { item.dueDate.map(Calendar.current.isDateInToday) ?? false }

    private var chipColor: Color {
        if item.isOverdue { return .red }
        if isDueToday { return .orange }
        return .secondary
    }
}
