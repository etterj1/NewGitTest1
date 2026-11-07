import SwiftUI

/// Bring-your-own API keys for Claude, ChatGPT and Grok.
struct AISettingsView: View {
    @AppStorage(AISettings.defaultProviderKey) private var defaultProvider = AIProvider.claude.rawValue
    @AppStorage(AISettings.openAIModelKey) private var openAIModel = AISettings.defaultOpenAIModel
    @AppStorage(AISettings.grokModelKey) private var grokModel = AISettings.defaultGrokModel
    @Environment(\.openURL) private var openURL

    @State private var claudeKey = ""
    @State private var openAIKey = ""
    @State private var grokKey = ""
    @State private var status: [AIProvider: Bool] = [:]
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                keyRow(.claude, text: $claudeKey, placeholder: "sk-ant-…")
                Button("Get a Claude API key") { openURL(URL(string: "https://console.anthropic.com/settings/keys")!) }
            } header: {
                Text("Claude")
            } footer: {
                Text("Uses \(AISettings.claudeModel) with web search. API usage is billed by Anthropic to your Console account (separate from a Claude.ai subscription).")
            }

            Section {
                keyRow(.chatgpt, text: $openAIKey, placeholder: "sk-…")
                TextField("Model", text: $openAIModel, prompt: Text(AISettings.defaultOpenAIModel))
                    .autocorrectionDisabled()
                Button("Get an OpenAI API key") { openURL(URL(string: "https://platform.openai.com/api-keys")!) }
            } header: {
                Text("ChatGPT")
            } footer: {
                Text("API usage is billed by OpenAI to your platform account (separate from a ChatGPT Plus subscription).")
            }

            Section {
                keyRow(.grok, text: $grokKey, placeholder: "xai-…")
                TextField("Model", text: $grokModel, prompt: Text(AISettings.defaultGrokModel))
                    .autocorrectionDisabled()
                Button("Get an xAI API key") { openURL(URL(string: "https://console.x.ai")!) }
            } header: {
                Text("Grok")
            } footer: {
                Text("Default model grok-4.7; use grok-4.3 for cheaper, faster answers. With search on, Grok also searches X (last 30 days) and powers each task's “Check the buzz on X”. xAI bills X search per post fetched (about $5 per 1,000) on top of tokens, separately from X Premium or SuperGrok.")
            }

            if AIProvider.configured.count > 1 {
                Section("Default assistant") {
                    Picker("Use", selection: $defaultProvider) {
                        ForEach(AIProvider.configured) { Text($0.displayName).tag($0.rawValue) }
                    }
                }
            }

            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }

            Section {
                Text("Keys are stored in your Keychain on this device. When you use the assistant, that task's details (or your task list, for a briefing) are sent to the provider you pick.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Assistants")
        .onAppear(perform: refreshStatus)
    }

    private func keyRow(_ provider: AIProvider, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            SecureField(status[provider] == true ? "Saved — paste to replace" : placeholder, text: text)
                .autocorrectionDisabled()
            if status[provider] == true {
                Button("Remove", role: .destructive) { save("", for: provider) }
                    .buttonStyle(.borderless)
            }
            Button("Save") {
                save(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
                text.wrappedValue = ""
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func save(_ key: String, for provider: AIProvider) {
        do {
            try CredentialStore.saveSecret(key, named: provider.keychainName)
            message = key.isEmpty ? "\(provider.displayName) key removed." : "\(provider.displayName) key saved."
        } catch {
            message = error.localizedDescription
        }
        refreshStatus()
    }

    private func refreshStatus() {
        for provider in AIProvider.allCases { status[provider] = provider.isConfigured }
    }
}
