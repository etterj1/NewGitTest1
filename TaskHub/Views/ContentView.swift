import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var filter: SidebarFilter? = .board
    @State private var selection: TaskItem.ID?
    @State private var showingNewTask = false
    @State private var showingAccounts = false

    var body: some View {
        Group {
            if filter == .board {
                NavigationSplitView {
                    sidebar
                } detail: {
                    NavigationStack { BoardView(showingNewTask: $showingNewTask) }
                }
            } else {
                NavigationSplitView {
                    sidebar
                } content: {
                    TaskListView(filter: filter ?? .all, selection: $selection, showingNewTask: $showingNewTask)
                        .navigationSplitViewColumnWidth(min: 340, ideal: 440)
                } detail: {
                    if let selection, let item = store.items.first(where: { $0.id == selection }) {
                        TaskDetailView(item: item)
                            .id(item.id)
                    } else {
                        ContentUnavailableView("Nothing selected", systemImage: "checklist",
                                               description: Text("Pick a task, email or mention to see details and edit it."))
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskView()
        }
        .sheet(isPresented: $showingAccounts) {
            AccountsView()
        }
        .alert("Sync problem", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await store.refreshIfStale() } }
        }
        .onChange(of: filter) { selection = nil }
    }

    private var sidebar: some View {
        SidebarView(selection: $filter, showingAccounts: $showingAccounts)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
    }
}
