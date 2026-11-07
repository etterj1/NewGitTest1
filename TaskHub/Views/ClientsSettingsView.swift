import SwiftUI

/// Edit the clients used to color-code and filter the board.
struct ClientsSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var clients: [ClientTag] = []

    var body: some View {
        Form {
            Section {
                ForEach($clients) { $client in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Client name", text: $client.name)
                            .font(.headline)
                        TextField("Match words (comma separated)", text: Binding(
                            get: { client.keywords.joined(separator: ", ") },
                            set: { client.keywords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                        ))
                        .font(.callout)
                        .autocorrectionDisabled()
                        HStack(spacing: 10) {
                            ForEach(ClientTag.palette, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: client.colorHex == hex ? 2 : 0))
                                    .onTapGesture { client.colorHex = hex }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { clients.remove(atOffsets: $0) }

                Button {
                    clients.append(ClientTag(name: "New client", colorHex: ClientTag.palette[clients.count % ClientTag.palette.count], keywords: []))
                } label: {
                    Label("Add Client", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("A card gets a client's color when one of its match words appears in the task's project, title or account name. The first match wins, so put more specific clients first. Swipe to delete.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clients")
        .onAppear { clients = store.clients }
        .onChange(of: clients) { store.updateClients(clients) }
    }
}
