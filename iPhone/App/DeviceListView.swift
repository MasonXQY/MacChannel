import MacChannelCore
import SwiftUI

struct DeviceListView: View {
    @Bindable var model: MobileAppModel
    @State private var removalCandidate: DeviceSummary?
    @State private var showingSend = false

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
        .sheet(isPresented: $showingSend, onDismiss: { model.send?.requestCancellation() }) {
            if let sender = model.send { MobileSendView(model: sender, devices: model.pairedDevices) }
        }
        .alert("devices.remove.title", isPresented: Binding(
            get: { removalCandidate != nil }, set: { if !$0 { removalCandidate = nil } }
        ), presenting: removalCandidate) { device in
            Button("action.cancel", role: .cancel) { removalCandidate = nil }
            Button("devices.remove", role: .destructive) {
                model.removeDevice(device.id)
                removalCandidate = nil
            }
        } message: { _ in Text("devices.remove.confirm") }
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
                Label(serviceLabel, systemImage: model.serviceState == .online ? "network" : "network.slash")
                    .accessibilityIdentifier("service-status")
                Label("receiving.foreground", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.body)
                    .foregroundStyle(.secondary)
                if model.serviceFailure != nil {
                    Text("service.error").foregroundStyle(.secondary)
                    Button("action.retry") { model.retryConnection() }
                } else if model.serviceState == .reconnecting {
                    Button("action.retry") { model.retryConnection() }
                }
            }

            Section("devices.title") {
                if model.pairedDevices.isEmpty {
                    Text("devices.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.pairedDevices, id: \.id) { device in
                        VStack(alignment: .leading, spacing: 12) {
                            DeviceRow(device: device)
                            Button("devices.remove", role: .destructive) { removalCandidate = device }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("remove-device-\(device.id.rawValue.uuidString)")
                                .disabled(model.removalState == .removing || model.removalState == .saveFailed)
                        }
                    }
                }
            }

            if model.removalState != .idle {
                Section {
                    switch model.removalState {
                    case .removing: ProgressView("devices.remove.saving")
                    case .saveFailed:
                        Text("devices.remove.save.failed")
                        Button("pairing.save.retry") { model.retryRemovalSave() }
                    case .failed: Text("devices.remove.failed")
                    case .saved: Text("devices.remove.saved")
                    case .idle: EmptyView()
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
            if model.send != nil {
                Section {
                    Button { showingSend = true } label: {
                        Label("send.title", systemImage: "arrow.up.doc")
                    }
                    .accessibilityIdentifier("send-open-button")
                }
            }
        }
        .refreshable { await model.refreshDevices() }
    }

    private var serviceLabel: LocalizedStringKey {
        switch model.serviceState {
        case .inactive: "service.inactive"
        case .starting: "service.starting"
        case .online: "service.online"
        case .reconnecting: "service.reconnecting"
        case .stopping: "service.stopping"
        case .failed: "service.failed"
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            details
        } else {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                details
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(device.displayName.isEmpty ? String(localized: "devices.paired.mac") : device.displayName)
            Text(device.id.rawValue.uuidString.prefix(8))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(device.availability == .offline ? "devices.offline" : "devices.online")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
