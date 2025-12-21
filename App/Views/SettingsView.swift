import SwiftUI

struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var selectedSection: SettingsSection? = .services

    enum SettingsSection: String, CaseIterable, Identifiable {
        case services = "Services"
        case general = "General"

        var id: String { self.rawValue }

        var icon: String {
            switch self {
            case .services: return "square.grid.2x2"
            case .general: return "gear"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section {
                    ForEach(SettingsSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                    }
                }
            }
        } detail: {
            if let selectedSection {
                switch selectedSection {
                case .services:
                    ServiceSettingsView(serverController: serverController)
                        .navigationTitle("Services")
                case .general:
                    GeneralSettingsView(serverController: serverController)
                        .navigationTitle("General")
                        .formStyle(.grouped)
                }
            } else {
                Text("Select a category")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Text("")
        }
        .task {
            let window = NSApplication.shared.keyWindow
            window?.toolbarStyle = .unified
            window?.toolbar?.displayMode = .iconOnly
        }
    }

}

struct GeneralSettingsView: View {
    @ObservedObject var serverController: ServerController
    @AppStorage("useHTTPTransport") private var useHTTPTransport = true
    @State private var showingResetAlert = false
    @State private var showingRestartAlert = false
    @State private var selectedClients = Set<String>()

    private var trustedClients: [String] {
        serverController.getTrustedClients()
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Transport")
                            .font(.headline)
                        Spacer()
                    }

                    Text("Choose how clients connect to the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                Picker("Protocol", selection: $useHTTPTransport) {
                    Text("HTTP").tag(true)
                    Text("Bonjour").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: useHTTPTransport) { _, _ in
                    showingRestartAlert = true
                }

                if useHTTPTransport {
                    Text("HTTP transport on localhost. Recommended for stability.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Bonjour uses network discovery. May have connection issues.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Trusted Clients")
                            .font(.headline)
                        Spacer()
                        if !trustedClients.isEmpty {
                            Button("Remove All") {
                                showingResetAlert = true
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }

                    Text("Clients that automatically connect without approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                if trustedClients.isEmpty {
                    HStack {
                        Text("No trusted clients")
                            .foregroundStyle(.secondary)
                            .italic()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    List(trustedClients, id: \.self, selection: $selectedClients) { client in
                        HStack {
                            Text(client)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                        }
                        .contextMenu {
                            Button("Remove Client", role: .destructive) {
                                serverController.removeTrustedClient(client)
                            }
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 200)
                    .onDeleteCommand {
                        for clientID in selectedClients {
                            serverController.removeTrustedClient(clientID)
                        }
                        selectedClients.removeAll()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Remove All Trusted Clients", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove All", role: .destructive) {
                serverController.resetTrustedClients()
                selectedClients.removeAll()
            }
        } message: {
            Text(
                "This will remove all trusted clients. They will need to be approved again when connecting."
            )
        }
        .alert("Restart Required", isPresented: $showingRestartAlert) {
            Button("OK") {}
        } message: {
            Text("Restart the app for the transport change to take effect.")
        }
    }
}
