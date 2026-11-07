import SwiftUI

struct AccountsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.accounts) { account in
                        NavigationLink {
                            AccountDetailView(account: account)
                        } label: {
                            HStack {
                                Image(systemName: account.kind.symbol)
                                    .frame(width: 24)
                                VStack(alignment: .leading) {
                                    Text(account.displayName)
                                    Text("\(account.kind.displayName) · \(account.identity)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !account.isEnabled {
                                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                                } else if store.accountErrors[account.id] != nil {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Connect as many accounts per app as you like — e.g. two ClickUp workspaces, a personal and a work Gmail, or several Slack workspaces.")
                }

                Section {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add Account", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("Accounts")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .sheet(isPresented: $showingAdd) {
                AddAccountView()
            }
        }
    }
}

struct AccountDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var account: Account
    @State private var confirmingRemoval = false

    init(account: Account) {
        _account = State(initialValue: account)
    }

    var body: some View {
        Form {
            Section("Account") {
                TextField("Label", text: $account.name, prompt: Text(account.identity))
                LabeledContent("Connected as", value: account.identity)
                Toggle("Sync this account", isOn: $account.isEnabled)
            }

            if account.kind.sources.count > 1 {
                Section("Include") {
                    ForEach(account.kind.sources) { source in
                        Toggle(isOn: Binding(
                            get: { account.enabledSources.contains(source) },
                            set: { isOn in
                                if isOn { account.enabledSources.insert(source) } else { account.enabledSources.remove(source) }
                            }
                        )) {
                            Label(source.displayName, systemImage: source.symbol)
                        }
                    }
                }
            }

            if account.kind == .google, account.enabledSources.contains(.gmail) {
                Section {
                    TextField("Gmail search", text: option(.gmailQuery), prompt: Text(OptionDefaults.gmailQuery))
                        .autocorrectionDisabled()
                } header: {
                    Text("Which emails count as to-dos")
                } footer: {
                    Text("Any Gmail search works, e.g. “is:starred”, “label:to-do”, or “is:unread to:me newer_than:3d”. Leave blank for starred emails.")
                }
            }

            if account.kind == .slack {
                Section {
                    TextField("Slack search", text: option(.slackQuery), prompt: Text(OptionDefaults.slackQuery))
                        .autocorrectionDisabled()
                } header: {
                    Text("Which messages count as asks")
                } footer: {
                    Text("Slack search syntax. {me} = your user ID, {since} = 14 days ago. Leave blank for messages that @mention you.")
                }
            }

            if account.kind == .google || account.kind == .apple {
                Section("Calendar") {
                    Stepper(value: Binding(
                        get: { Int(account.options[AccountOption.calendarDaysAhead.rawValue] ?? "") ?? OptionDefaults.calendarDaysAhead },
                        set: { account.options[AccountOption.calendarDaysAhead.rawValue] = String($0) }
                    ), in: 1...60) {
                        Text("Show events \(Int(account.options[AccountOption.calendarDaysAhead.rawValue] ?? "") ?? OptionDefaults.calendarDaysAhead) days ahead")
                    }
                }
            }

            Section("Status") {
                if let error = store.accountErrors[account.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else {
                    Label("Working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button("Sync Now") {
                    Task { await store.refresh(account) }
                }
                .disabled(store.refreshingAccounts.contains(account.id))
            }

            Section {
                Button("Remove Account", role: .destructive) { confirmingRemoval = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(account.displayName)
        .onChange(of: account) { store.updateAccount(account) }
        .confirmationDialog("Remove \(account.displayName)?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) {
                store.removeAccount(account)
                dismiss()
            }
        } message: {
            Text("TaskHub forgets this account and its saved token. Nothing is deleted in \(account.kind.displayName).")
        }
    }

    private func option(_ key: AccountOption) -> Binding<String> {
        Binding(
            get: { account.options[key.rawValue] ?? "" },
            set: { account.options[key.rawValue] = $0 }
        )
    }
}
