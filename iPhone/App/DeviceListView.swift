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
                        if let settings = model.settings {
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink { MobileSettingsView(model: settings) } label: {
                                    Label("settings.title", systemImage: "gearshape")
                                }.accessibilityIdentifier("settings-open-button")
                            }
                        }
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
        .sheet(isPresented: $showingSend, onDismiss: {
            model.send?.requestCancellation()
            Task { await model.send?.cancelAndWait(); await model.pendingShares.refresh() }
        }) {
            if let sender = model.send { MobileSendView(model: sender, devices: model.pairedDevices) }
        }
        .sheet(item: Binding(get: { model.history?.presentation },
            set: { model.history?.presentation = $0 })) { item in
            MobileReceivedFileSheet(item: item)
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
                Text("presence.service.explanation").font(.caption).foregroundStyle(.secondary)
                if model.trustSyncState == .needsAttention {
                    Label("presence.sync.attention", systemImage: "exclamationmark.triangle")
                } else if model.trustSyncState == .pendingPersistence {
                    Text("presence.pending.save")
                } else if model.serviceState == .online && model.trustSyncState != .synchronized {
                    Text("presence.syncing")
                }
                if model.serviceFailure == .trustPersistence {
                    Text("presence.save.failed")
                    Button("presence.retry.save") { model.retryTrustSave() }
                } else if model.serviceFailure != nil {
                    Text("service.error").foregroundStyle(.secondary)
                    Button("action.retry") { model.retryConnection() }
                } else if model.serviceState == .reconnecting || model.trustSyncState == .needsAttention {
                    Button("action.retry") { model.retryConnection() }
                }
            }

            if let history = model.history {
                MobileHistorySection(model: history, latestOnly: true)
            }
            if let sender = model.send {
                MobilePendingShareView(model: model.pendingShares, sender: sender) { showingSend = true }
            }

            Section("devices.title") {
                if model.pairedDevices.isEmpty {
                    Text("devices.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.pairedDevices, id: \.id) { device in
                        VStack(alignment: .leading, spacing: 12) {
                            DeviceRow(device: device, presentation: model.presentation(for: device))
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
        .refreshable {
            await model.refreshDevices(); await model.history?.refresh()
            await model.pendingShares.refresh()
        }
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
    let presentation: PeerConnectionPresentation
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
            Text(PeerConnectionPresentation.displayName(device.displayName, unnamed: String(localized: "presence.unnamed")))
            Text(device.id.rawValue.uuidString.prefix(8))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(presentation.rawValue))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
