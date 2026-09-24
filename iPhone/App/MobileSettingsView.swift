import SwiftUI

struct MobileSettingsView: View {
    let model: MobileSettingsModel
    var body: some View {
        List {
            if model.accountRowVisible {
                Section("account.section") {
                    NavigationLink {
                        MobileAccountView(model: model.account)
                    } label: {
                        HStack {
                            Label("account.title", systemImage: "person.crop.circle")
                            Spacer()
                            accountSummary
                        }
                    }
                    .accessibilityIdentifier("account-row")
                }
            }
            Section("settings.discovery.title") {
                Toggle("settings.discovery.toggle", isOn: Binding(
                    get: { model.discoveryEnabled },
                    set: { enabled in Task { await model.setDiscovery(enabled) } }))
                    .disabled(model.saving).accessibilityIdentifier("discovery-toggle")
                Text("settings.discovery.explanation").foregroundStyle(.secondary)
                Text(!model.discoveryEnabled ? "settings.discovery.off" :
                    model.localNetworkAvailable ? "settings.discovery.available" : "settings.discovery.unavailable")
                    .accessibilityIdentifier("discovery-capability")
                Text("settings.discovery.permission").foregroundStyle(.secondary)
                if model.saveFailed { Text("settings.discovery.save.error") }
            }
            Section("settings.receiving.title") {
                Text("receiving.foreground")
                Text("received.location.instructions")
                    .accessibilityIdentifier("received-location-instructions")
            }
            Section("settings.about") {
                LabeledContent("settings.version", value: model.version)
                Text("settings.language").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("settings.title")
        .task { await model.account.load() }
    }

    @ViewBuilder private var accountSummary: some View {
        switch model.account.phase {
        case .signedIn: Text("account.status.signed-in").foregroundStyle(.secondary)
        case .unavailable, .secureStorageError:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}
