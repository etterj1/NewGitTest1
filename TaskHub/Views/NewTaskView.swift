import SwiftUI

/// Create a task and send it straight to ClickUp, Asana, Google Tasks, a calendar, Reminders or TaskHub.
struct NewTaskView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastDestinationID") private var lastDestinationID = ""

    @State private var draft = TaskDraft()
    @State private var accountID: UUID?
    @State private var destinations: [Destination] = []
    @State private var destinationID: Destination.ID?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var creatableAccounts: [Account] {
        store.accounts.filter { account in account.isEnabled && account.enabledSources.contains { $0.canCreate } }
    }

    private var destination: Destination? { destinations.first { $0.id == destinationID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("What needs doing?", text: $draft.title, axis: .vertical)
                        .font(.headline)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...8)
                }

                Section("Send to") {
                    Picker("Account", selection: $accountID) {
                        ForEach(creatableAccounts) { account in
                            Label(account.displayName, systemImage: account.kind.symbol)
                                .tag(Optional(account.id))
                        }
                    }
                    if isLoading {
                        HStack { ProgressView().controlSize(.small); Text("Loading lists…").foregroundStyle(.secondary) }
                    } else {
                        Picker("List / Project", selection: $destinationID) {
                            Text("Choose…").tag(Destination.ID?.none)
                            ForEach(destinations) { destination in
                                Text(destination.detail.map { "\(destination.name) — \($0)" } ?? destination.name)
                                    .tag(Optional(destination.id))
                            }
                        }
                    }
                }

                Section(destination?.source.itemKind == .event ? "When" : "Schedule") {
                    DueDateEditor(draft: $draft, supportsTime: destination?.source.supportsDueTime ?? true,
                                  label: destination?.source.itemKind == .event ? "Start" : "Due")
                    if destination?.source.supportsPriority ?? false {
                        PriorityPicker(priority: $draft.priority)
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView().controlSize(.small) } else { Text("Add") }
                    }
                    .disabled(draft.trimmedTitle.isEmpty || destination == nil || isSaving)
                }
            }
            .onAppear {
                if accountID == nil {
                    let remembered = creatableAccounts.first { lastDestinationID.hasPrefix($0.id.uuidString) }
                    accountID = remembered?.id ?? creatableAccounts.first?.id
                }
            }
            .task(id: accountID) { await loadDestinations() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 540)
        #endif
    }

    @MainActor
    private func loadDestinations() async {
        guard let accountID, let account = store.account(for: accountID) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            destinations = try await store.destinations(for: account).filter { $0.source.canCreate }
            if destinations.contains(where: { $0.id == lastDestinationID }) {
                destinationID = lastDestinationID
            } else {
                destinationID = destinations.first?.id
            }
            errorMessage = nil
        } catch {
            destinations = []
            destinationID = nil
            errorMessage = "Couldn't load lists: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func save() async {
        guard let destination else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.create(draft, in: destination)
            lastDestinationID = destination.id
            dismiss()
        } catch {
            errorMessage = "Couldn't create in \(destination.source.displayName): \(error.localizedDescription)"
        }
    }
}
