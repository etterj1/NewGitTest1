import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: SidebarFilter?
    @Binding var showingAccounts: Bool

    var body: some View {
        List(selection: $selection) {
            Section("Focus") {
                row(.board, "Board", "rectangle.split.3x1", .indigo)
                row(.today, "Today", "sun.max", .orange)
                row(.upcoming, "Next 7 Days", "calendar", .blue)
                row(.overdue, "Overdue", "exclamationmark.circle", .red)
                row(.all, "All Open", "tray.full", .purple)
                row(.noDate, "No Date", "tray", .gray)
                row(.completed, "Completed", "checkmark.circle", .green, showCount: false)
            }

            let activeSources = TaskSource.allCases.filter { source in
                store.accounts.contains { $0.isEnabled && $0.enabledSources.contains(source) }
            }
            if !activeSources.isEmpty {
                Section("Apps") {
                    ForEach(activeSources) { source in
                        row(.source(source), source.displayName, source.symbol, source.color)
                    }
                }
            }

            let activeClients = store.clients.filter { store.count(for: .client($0.id)) > 0 }
            if !activeClients.isEmpty {
                Section("Clients") {
                    ForEach(activeClients) { client in
                        row(.client(client.id), client.name, "circle.fill", client.color)
                    }
                }
            }

            let projects = store.topProjects
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects, id: \.self) { project in
                        row(.project(project), project, "folder", .secondary)
                    }
                }
            }

            Section("Accounts") {
                ForEach(store.accounts.filter(\.isEnabled)) { account in
                    HStack {
                        Label(account.displayName, systemImage: account.kind.symbol)
                        Spacer()
                        if store.refreshingAccounts.contains(account.id) {
                            ProgressView().controlSize(.small)
                        } else if store.accountErrors[account.id] != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help(store.accountErrors[account.id] ?? "")
                        }
                    }
                    .badge(store.count(for: .account(account.id)))
                    .tag(SidebarFilter.account(account.id))
                }
                accountsButton
            }
        }
        .navigationTitle("TaskHub")
        .safeAreaInset(edge: .bottom) {
            if let last = store.lastRefresh {
                Text("Synced \(last.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingAccounts = true } label: { Image(systemName: "person.crop.circle") }
            }
        }
        #endif
    }

    @ViewBuilder
    private var accountsButton: some View {
        #if os(macOS)
        SettingsLink {
            Label("Manage Accounts…", systemImage: "gearshape")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        #else
        Button {
            showingAccounts = true
        } label: {
            Label("Manage Accounts…", systemImage: "gearshape")
        }
        #endif
    }

    private func row(_ filter: SidebarFilter, _ title: String, _ symbol: String, _ tint: Color, showCount: Bool = true) -> some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .badge(showCount ? store.count(for: filter) : 0)
        .tag(filter)
    }
}
