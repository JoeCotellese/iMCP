// ABOUTME: Settings view for managing MCP services, grouped by category.
// ABOUTME: Displays services with toggles and optional drill-down for granular controls.

import OSLog
import SwiftUI

private let log = Logger.service("settings")

struct ServiceSettingsView: View {
    @ObservedObject var serverController: ServerController

    private var serviceConfigs: [ServiceConfig] {
        serverController.computedServiceConfigs
    }

    private func services(for category: ServiceCategory) -> [ServiceConfig] {
        serviceConfigs.filter { $0.category == category }
    }

    var body: some View {
        Form {
            ForEach(ServiceCategory.allCases) { category in
                let categoryServices = services(for: category)
                if !categoryServices.isEmpty {
                    Section(category.rawValue) {
                        ForEach(categoryServices) { config in
                            ServiceRowView(config: config)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ServiceRowView: View {
    let config: ServiceConfig
    @State private var isServiceActivated = false
    @State private var activationError: String?
    @State private var showingErrorAlert = false

    var body: some View {
        HStack {
            serviceIcon
            Text(config.name)
            Spacer()
            Toggle("", isOn: config.binding)
                .toggleStyle(.switch)
                .labelsHidden()
            if config.hasDetailView {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if config.hasDetailView {
                // TODO: Navigate to detail view for granular service controls
            } else {
                config.binding.wrappedValue.toggle()
                if config.binding.wrappedValue && !isServiceActivated {
                    Task { @MainActor in
                        do {
                            try await config.service.activate()
                            isServiceActivated = true
                        } catch {
                            log.error("Failed to activate \(config.name): \(error.localizedDescription)")
                            config.binding.wrappedValue = false
                            activationError = error.localizedDescription
                            showingErrorAlert = true
                        }
                    }
                }
            }
        }
        .task {
            isServiceActivated = await config.isActivated
        }
        .alert("Unable to Enable \(config.name)", isPresented: $showingErrorAlert) {
            Button("OK") {}
        } message: {
            Text(activationError ?? "An unknown error occurred.")
        }
    }

    private var serviceIcon: some View {
        Circle()
            .fill(config.binding.wrappedValue ? config.color : Color(NSColor.controlColor).opacity(0.3))
            .frame(width: 26, height: 26)
            .overlay(
                Image(systemName: config.iconName)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(config.binding.wrappedValue ? .white : .primary.opacity(0.5))
                    .padding(5)
            )
            .animation(.snappy, value: config.binding.wrappedValue)
    }
}
