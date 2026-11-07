import SwiftUI

@main
struct TaskHubApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("TaskHub", id: "main") {
            ContentView()
                .environment(store)
                .onAppear { store.startAutoRefresh() }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif

        #if os(macOS)
        Settings {
            AccountsView()
                .environment(store)
                .frame(minWidth: 620, minHeight: 460)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            let count = store.count(for: .today)
            Label(count > 0 ? "\(count)" : "TaskHub", systemImage: "checklist")
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}
