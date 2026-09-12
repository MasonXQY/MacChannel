import MacChannelCore
import SwiftUI

struct DeviceListView: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("app.name")
                .toolbar {
                    if model.bootstrapState == .ready {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                model.presentPairing()
                            } label: {
                                Label("pairing.add", systemImage: "plus")
                            }
                        }
                    }
                }
        }
        .sheet(item: $model.pairing) { pairing in
            PairingView(model: pairing) {
                model.dismissPairingIfAllowed()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.bootstrapState {
        case .idle, .loading:
            ProgressView("bootstrap.loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("bootstrap.failed.title", systemImage: "exclamationmark.shield")
            } description: {
                Text(model.bootstrapError ?? String(localized: "bootstrap.error"))
            } actions: {
                Button("action.retry") { Task { await model.retryBootstrap() } }
                    .buttonStyle(.borderedProminent)
            }
        case .ready:
            deviceList
        }
    }

    private var deviceList: some View {
        List {
            Section {
                Label("receiving.foreground", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Section("devices.title") {
                if model.pairedDevices.isEmpty {
                    Text("devices.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.pairedDevices, id: \.id) { device in
                        DeviceRow(device: device)
                    }
                }
            }

            Section {
                Button {
                    model.presentPairing()
                } label: {
                    Label("pairing.add", systemImage: "macbook.and.iphone")
                }
                .accessibilityIdentifier("pair-device-button")
            }
        }
        .refreshable { await model.refreshDevices() }
    }
}

private struct DeviceRow: View {
    let device: DeviceSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName.isEmpty ? String(localized: "devices.paired.mac") : device.displayName)
                Text(device.id.rawValue.uuidString.prefix(8))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
