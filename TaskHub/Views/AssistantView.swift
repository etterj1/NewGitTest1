import SwiftUI

/// What the assistant is being asked about, plus an optional first question.
struct AIRequest: Identifiable {
    let id = UUID()
    let title: String
    let context: String
    var initialPrompt: String?
    var webSearch: Bool = true
    /// When set, replies can be appended to the task's notes.
    var onSaveToNotes: ((String) -> Void)?
}

struct AssistantView: View {
    let request: AIRequest

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AISettings.defaultProviderKey) private var defaultProvider = AIProvider.claude.rawValue

    @State private var provider: AIProvider = .claude
    @State private var webSearch = true
    @State private var conversation: AIConversation?
    @State private var turns: [Turn] = []
    @State private var input = ""
    @State private var isThinking = false
    @State private var errorMessage: String?
    @State private var savedTurnIDs: Set<UUID> = []
    /// Set after switching assistant or web search mid-chat, so the new conversation gets the earlier turns.
    @State private var conversationNeedsRecap = false

    struct Turn: Identifiable {
        let id = UUID()
        let isUser: Bool
        let text: String
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if AIProvider.configured.isEmpty {
                    ContentUnavailableView {
                        Label("No AI assistant connected", systemImage: "sparkles")
                    } description: {
                        Text("Add a Claude, ChatGPT or Grok API key under Accounts → AI Assistants.")
                    }
                } else {
                    transcript
                    Divider()
                    composer
                }
            }
            .navigationTitle(request.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if AIProvider.configured.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Assistant", selection: $provider) {
                            ForEach(AIProvider.configured) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isThinking)
                    }
                }
            }
            .onAppear(perform: start)
            .onChange(of: provider) { resetConversation() }
            .onChange(of: webSearch) { resetConversation() }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        #endif
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(turns) { turn in
                        bubble(turn).id(turn.id)
                    }
                    if isThinking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(webSearch ? "\(provider.displayName) is researching…" : "\(provider.displayName) is thinking…")
                                .foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            .onChange(of: turns.count) {
                if let last = turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ turn: Turn) -> some View {
        if turn.isUser {
            Text(turn.text)
                .padding(10)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.markdown(turn.text))
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    Button { Clipboard.copy(turn.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    if let save = request.onSaveToNotes {
                        Button {
                            save(turn.text)
                            savedTurnIDs.insert(turn.id)
                        } label: {
                            Label(savedTurnIDs.contains(turn.id) ? "Added to notes" : "Add to task notes",
                                  systemImage: savedTurnIDs.contains(turn.id) ? "checkmark" : "note.text.badge.plus")
                        }
                        .disabled(savedTurnIDs.contains(turn.id))
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom) {
                TextField("Ask a follow-up…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendInput)
                    .disabled(isThinking)
                Button(action: sendInput) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(isThinking || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Toggle("Search the web", isOn: $webSearch)
                .font(.caption)
                .disabled(isThinking)
            Text("Task details are sent to \(provider.displayName) to answer.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    // MARK: Actions

    private func start() {
        let configured = AIProvider.configured
        provider = AIProvider(rawValue: defaultProvider).flatMap { configured.contains($0) ? $0 : nil } ?? configured.first ?? .claude
        webSearch = request.webSearch
        resetConversation()
        if let prompt = request.initialPrompt, turns.isEmpty {
            send(prompt)
        }
    }

    private func resetConversation() {
        conversation = nil
        errorMessage = nil
        conversationNeedsRecap = !turns.isEmpty
    }

    private func sendInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        input = ""
        send(text)
    }

    private func send(_ text: String) {
        turns.append(Turn(isUser: true, text: text))
        errorMessage = nil
        isThinking = true
        Task { @MainActor in
            defer { isThinking = false }
            do {
                if conversation == nil {
                    conversation = try AIConversationFactory.make(provider, system: AIPrompts.system(context: request.context), webSearch: webSearch)
                }
                let question = conversationNeedsRecap ? recap(for: text) : text
                conversationNeedsRecap = false
                let reply = try await conversation!.send(question)
                turns.append(Turn(isUser: false, text: reply))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func recap(for text: String) -> String {
        let history = turns.dropLast().map { ($0.isUser ? "Me: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
        return "Earlier in this conversation:\n\(history)\n\nMy question now: \(text)"
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
