import AuthenticationServices
import SwiftUI

struct AddAccountView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL

    @State private var kind: AccountKind = .clickup
    @State private var label = ""
    @State private var token = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var usesToken: Bool { [.clickup, .asana, .slack].contains(kind) }
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Service", selection: $kind) {
                        ForEach(AccountKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    TextField("Label (optional)", text: $label, prompt: Text("e.g. Agency workspace"))
                }

                Section("How to connect") {
                    instructions
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let link = helpLink {
                        Button("Open \(kind == .slack ? "Slack apps" : kind.displayName + " settings")") { openURL(link) }
                    }
                }

                switch kind {
                case .clickup, .asana, .slack:
                    Section("Token") {
                        SecureField(tokenPlaceholder, text: $token)
                            .autocorrectionDisabled()
                        Text("Stored securely in your Keychain. It never leaves this device except to talk to \(kind.displayName).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .google:
                    Section {
                        Button {
                            Task { await connect() }
                        } label: {
                            Label("Sign in with Google", systemImage: "person.badge.key")
                        }
                        .disabled(isWorking)
                        if !GoogleAuth.isConfigured {
                            Text("Google sign-in needs a one-time setup: add your OAuth client ID to Config.local.xcconfig (see README).")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                case .apple:
                    Section {
                        Button {
                            Task { await connect() }
                        } label: {
                            Label("Allow access to Reminders & Calendar", systemImage: "lock.open")
                        }
                        .disabled(isWorking)
                    }
                case .local:
                    EmptyView()
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if usesToken || kind == .local {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await connect() }
                        } label: {
                            if isWorking { ProgressView().controlSize(.small) } else { Text("Connect") }
                        }
                        .disabled(isWorking || (usesToken && trimmedToken.isEmpty))
                    }
                }
            }
            .onChange(of: kind) {
                token = ""
                errorMessage = nil
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }

    // MARK: Copy

    private var tokenPlaceholder: String {
        switch kind {
        case .clickup: return "pk_…"
        case .asana: return "Personal access token"
        case .slack: return "xoxp-…"
        default: return "Token"
        }
    }

    private var helpLink: URL? {
        switch kind {
        case .clickup: return URL(string: "https://app.clickup.com/settings/apps")
        case .asana: return URL(string: "https://app.asana.com/0/my-apps")
        case .slack: return URL(string: "https://api.slack.com/apps")
        default: return nil
        }
    }

    @ViewBuilder
    private var instructions: some View {
        switch kind {
        case .clickup:
            Text("In ClickUp open **Settings → Apps**, click **Generate** under API Token and paste it below. Tasks assigned to you across every workspace that login can see will show up. Add another account for each additional ClickUp login.")
        case .asana:
            Text("In Asana open **My Settings → Apps → Manage Developer Apps** and create a **Personal access token**. Tasks assigned to you in all of its workspaces will show up.")
        case .slack:
            Text("Create a Slack app for your workspace, add the **User Token Scopes** `search:read` and `reactions:write`, install it, then paste the **User OAuth Token** (xoxp-…). Repeat for each workspace.")
        case .google:
            Text("Sign in with each Google account you use. TaskHub shows **starred Gmail** as to-dos (customisable), upcoming **Google Calendar** events, and all **Google Tasks** lists.")
        case .apple:
            Text("Uses every account already set up on this device in **Reminders** and **Calendar** (iCloud, Exchange, Google, …). Reminders can be created, edited and completed from TaskHub.")
        case .local:
            Text("A simple inbox stored only in TaskHub — handy for quick notes and to-dos that don't belong to any app.")
        }
    }

    // MARK: Connect

    @MainActor
    private func connect() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            switch kind {
            case .clickup:
                let result = try await ClickUpProvider.connect(token: trimmedToken)
                try add(identity: result.identity, options: result.options, credential: .token(trimmedToken))
            case .asana:
                let result = try await AsanaProvider.connect(token: trimmedToken)
                try add(identity: result.identity, options: result.options, credential: .token(trimmedToken))
            case .slack:
                let result = try await SlackProvider.connect(token: trimmedToken)
                try add(identity: result.identity, options: result.options, credential: .token(trimmedToken))
            case .google:
                let result = try await GoogleAuth.signIn(using: webAuthenticationSession)
                try add(identity: result.email, options: [:], credential: .oauth(result.token))
            case .apple:
                let access = try await AppleProvider.requestAccess()
                guard access.reminders || access.calendar else {
                    throw APIError.api("Access was denied. You can allow it later in System Settings → Privacy & Security.")
                }
                var sources: Set<TaskSource> = []
                if access.reminders { sources.insert(.appleReminders) }
                if access.calendar { sources.insert(.appleCalendar) }
                try add(identity: "This device", options: [:], credential: nil, sources: sources)
            case .local:
                try add(identity: "On this device", options: [:], credential: nil)
            }
            dismiss()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User closed the sign-in sheet.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func add(identity: String, options: [String: String], credential: Credential?, sources: Set<TaskSource>? = nil) throws {
        if kind != .local, store.accounts.contains(where: { $0.kind == kind && $0.identity == identity }) {
            throw APIError.api("\(identity) is already connected.")
        }
        var account = Account(kind: kind, name: label.trimmingCharacters(in: .whitespaces), identity: identity, options: options)
        if let sources { account.enabledSources = sources }
        try store.addAccount(account, credential: credential)
    }
}
