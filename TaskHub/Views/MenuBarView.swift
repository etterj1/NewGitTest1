#if os(macOS)
import AppKit
import SwiftUI

/// Compact "what's on my plate today" panel in the macOS menu bar.
struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let items = store.items(matching: .today)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Today").font(.headline)
                Text("\(items.count)").foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    if store.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
            }
            .padding(12)

            Divider()

            if items.isEmpty {
                Text("Nothing due today 🎉")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items.prefix(20)) { item in
                            TaskRowView(item: item, accountName: "") {
                                Task { await store.toggleCompleted(item) }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 420)
            }

            Divider()

            HStack {
                Button("Open TaskHub") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 380)
    }
}
#endif
