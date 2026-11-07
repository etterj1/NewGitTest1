import SwiftUI

struct TaskDetailView: View {
    @Environment(AppStore.self) private var store
    let item: TaskItem

    @State private var draft: TaskDraft
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(item: TaskItem) {
        self.item = item
        _draft = State(initialValue: TaskDraft(from: item))
    }

    private var hasChanges: Bool { draft != TaskDraft(from: item) }
    private var account: Account? { store.account(for: item.accountID) }

    var body: some View {
        Form {
            Section {
                HStack {
                    SourceBadge(source: item.source)
                    if let account { Text(account.displayName).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let status = item.status { Text(status.capitalized).font(.caption).foregroundStyle(.secondary) }
                }
            }

            if item.source.canEdit {
                Section("Details") {
                    TextField("Title", text: $draft.title, axis: .vertical)
                        .font(.headline)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...14)
                }
                Section(item.kind == .event ? "When" : "Schedule") {
                    DueDateEditor(draft: $draft, supportsTime: item.source.supportsDueTime,
                                  label: item.kind == .event ? "Start" : "Due",
                                  allowsClearing: item.kind != .event)
                    if item.source.supportsPriority {
                        PriorityPicker(priority: $draft.priority)
                    }
                }
            } else {
                Section(item.kind == .email ? "Email" : "Message") {
                    Text(item.title).font(.headline).textSelection(.enabled)
                    if !item.notes.isEmpty, item.notes != item.title {
                        Text(item.notes).textSelection(.enabled)
                    }
                    if let requester = item.requester { LabeledContent("From", value: requester) }
                    if let created = item.createdAt {
                        LabeledContent("Received", value: created.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            Section {
                Button {
                    Task { await store.toggleCompleted(item) }
                } label: {
                    Label(item.isCompleted ? "Mark as Not Done" : "Mark as Done",
                          systemImage: item.isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle")
                }
            } footer: {
                Text(item.source.completionHint)
            }

            Section("Info") {
                if let project = item.project, !project.isEmpty { LabeledContent("Project / List", value: project) }
                if let requester = item.requester, item.source.canEdit { LabeledContent("Requested by", value: requester) }
                if let end = item.endDate, item.kind == .event {
                    LabeledContent("Ends", value: end.formatted(date: .abbreviated, time: item.dueHasTime ? .shortened : .omitted))
                }
                if let updated = item.updatedAt {
                    LabeledContent("Last updated", value: updated.formatted(date: .abbreviated, time: .shortened))
                }
                if let url = item.webURL {
                    Link(destination: url) {
                        Label("Open in \(item.source.displayName)", systemImage: "arrow.up.right.square")
                    }
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.source.displayName)
        .toolbar {
            if item.source.canEdit {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!hasChanges || draft.trimmedTitle.isEmpty || isSaving)
                }
            }
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await store.update(item, with: draft)
            draft = TaskDraft(from: updated)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save to \(item.source.displayName): \(error.localizedDescription)"
        }
    }
}

struct DueDateEditor: View {
    @Binding var draft: TaskDraft
    var supportsTime = true
    var label = "Due"
    var allowsClearing = true

    var body: some View {
        if allowsClearing {
            Toggle("\(label) date", isOn: Binding(
                get: { draft.dueDate != nil },
                set: { isOn in
                    draft.dueDate = isOn ? (draft.dueDate ?? Calendar.current.startOfDay(for: Date())) : nil
                    if !isOn { draft.dueHasTime = false }
                }
            ))
        }
        if let due = draft.dueDate {
            if supportsTime {
                Toggle("Include time", isOn: $draft.dueHasTime)
            }
            DatePicker(
                label,
                selection: Binding(get: { due }, set: { draft.dueDate = $0 }),
                displayedComponents: draft.dueHasTime && supportsTime ? [.date, .hourAndMinute] : [.date]
            )
        }
    }
}

struct PriorityPicker: View {
    @Binding var priority: TaskPriority

    var body: some View {
        Picker("Priority", selection: $priority) {
            ForEach(TaskPriority.allCases) { level in
                Label(level.label, systemImage: level == .none ? "flag.slash" : "flag.fill")
                    .tag(level)
            }
        }
    }
}
