import MacChannelCore
import SwiftUI

struct DeviceListView: View {
    @Bindable var model: MobileAppModel
    private enum Page { case send, history, devices }
    @State private var selectedPage: Page = .send
    @State private var presentsAccountInvitation = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TabView(selection: $selectedPage) {
            page(.send).tabItem { Label("tab.send", systemImage: "paperplane") }.tag(Page.send)
            page(.history).tabItem { Label("history.title", systemImage: "clock") }.tag(Page.history)
                .badge(model.history?.unreadCount ?? 0)
            page(.devices).tabItem { Label("tab.devices", systemImage: "laptopcomputer.and.iphone") }.tag(Page.devices)
        }
        .sheet(item: $model.pairing) { pairing in
            PairingView(model: pairing) { model.dismissPairingIfAllowed() }
        }
        .sheet(item: pickerBinding) { presentation in
            if let sender = model.send { MobilePickerPresentation(model: sender, presentation: presentation) }
        }
        .sheet(item: Binding(get: { model.history?.presentation },
            set: { if $0 == nil { model.history?.dismissPresentation() } })) { item in
            MobileReceivedFileSheet(item: item)
        }
        .sheet(isPresented: $presentsAccountInvitation) {
            if let settings = model.settings {
                NavigationStack { MobileAccountView(model: settings.account) }
            }
        }
        .onOpenURL { url in
            Task {
                if await model.prepareInvitationFromOpenURL(url) {
                    presentsAccountInvitation = true
                }
            }
        }
        .alert("identity.recovery.confirm.title", isPresented: Binding(
            get: { model.identityRecoveryConfirmationPresented },
            set: { presented in
                if !presented, let confirmationID = model.identityRecoveryConfirmationID {
                    model.identityRecoveryPresentationDismissed(confirmationID)
                }
            }
        )) {
            Button("action.cancel", role: .cancel) {
                model.cancelIdentityRecovery(model.identityRecoveryConfirmationID)
            }
            Button("identity.recovery.confirm.action", role: .destructive) {
                guard let confirmationID = model.identityRecoveryConfirmationID,
                      let operationID = model.acceptIdentityRecovery(confirmationID) else { return }
                Task { await model.performAcceptedIdentityRecovery(operationID) }
            }
        } message: {
            Text("identity.recovery.confirm.message")
        }
    }

    private var pickerBinding: Binding<MobileSendModel.Presentation?> {
        let token = model.send?.presentation?.id
        return Binding(get: { model.send?.presentation }, set: { value in
            if value == nil, let token { model.send?.presentationDismissed(token) }
        })
    }

    private func page(_ page: Page) -> some View {
        NavigationStack {
            Group {
                if model.bootstrapState != .ready { content }
                else if page == .history, let history = model.history { MobileHistoryView(model: history, isVisible: selectedPage == .history) }
                else { deviceList(page) }
            }
                .navigationTitle(page == .send ? "tab.send" : page == .history ? "history.title" : "tab.devices")
                .toolbar {
                    if model.bootstrapState == .ready {
                        if let settings = model.settings {
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink { MobileSettingsView(model: settings) } label: {
                                    Label("settings.title", systemImage: "gearshape")
                                }.accessibilityIdentifier("settings-open-button")
                            }
                        }
                        if page == .devices { ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                model.presentPairing()
                            } label: {
                                Label("pairing.add", systemImage: "plus")
                            }
                        } }
                    }
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
                if model.identityRecoveryAvailable {
                    if model.identityRecoveryInProgress {
                        ProgressView("identity.recovery.progress")
                    } else {
                        Button("identity.recovery.action") { model.requestIdentityRecovery() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("action.retry") { Task { await model.retryBootstrap() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .ready:
            deviceList(.send)
        }
    }

    private func deviceList(_ page: Page) -> some View {
        List {
            if page == .send {
            Section {
                HStack(spacing: 6) {
                    Circle().fill(model.serviceState == .online ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(serviceLabel).font(.caption).foregroundStyle(.secondary)
                }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("service-status")
                    .listRowBackground(Color.clear)
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

            if let sender = model.send {
                Section {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 12) { sendPhotosButton(sender); sendFilesButton(sender) }
                    } else {
                        HStack(spacing: 12) { sendPhotosButton(sender); sendFilesButton(sender) }
                    }
                    Label("receiving.foreground", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MobileSendView(model: sender, devices: model.pairedDevices).preparation
                if let failure = sender.failureKey { Text(LocalizedStringKey(failure)).foregroundStyle(.secondary) }
                MobilePendingShareView(model: model.pendingShares, sender: sender) { selectedPage = .send }
                let active = sender.transfers.filter { ![TransferPhase.completed, .cancelled].contains($0.phase) }
                if !active.isEmpty {
                    Section("send.active") {
                        ForEach(active, id: \.id) { transfer in
                            MobileTransferView(transfer: transfer, model: sender,
                                peerName: model.pairedDevices.first(where: { $0.id == transfer.peer })?.displayName ?? "")
                        }
                    }
                }
                if let key = sender.actionFailure {
                    Text(LocalizedStringKey(key)).accessibilityIdentifier("home-transfer-action-error")
                }
            }

            }
            if page == .devices {
            if model.accountConfigurationUnavailable {
                Section {
                    Text("account.configuration.unavailable").foregroundStyle(.secondary)
                        .accessibilityIdentifier("account-configuration-unavailable")
                }
            } else if let settings = model.settings {
                Section {
                    NavigationLink {
                        MobileAccountView(model: settings.account)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("devices.account.invitations")
                                Text("devices.account.invitations.subtitle")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                    }
                    .accessibilityIdentifier("account-invitations-entry")
                }
            }
            Section("devices.title") {
                if model.pairedDevices.isEmpty {
                    Text("devices.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.pairedDevices, id: \.id) { device in
                        NavigationLink {
                            MobileDeviceDetailView(device: device, model: model)
                        } label: {
                            DeviceRow(device: device, presentation: model.presentation(for: device))
                        }
                        .accessibilityIdentifier("device-details-\(device.id.rawValue.uuidString)")
                        .accessibilityLabel(PeerConnectionPresentation.displayName(device.displayName,
                            unnamed: String(localized: "presence.unnamed")))
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
            }
        }
        .refreshable {
            await model.refreshDevices(); await model.history?.refresh()
            await model.pendingShares.refresh()
        }
    }

    private func openSend(_ source: MobileSendStart) {
        switch source {
        case .photos: model.send?.openPhotos()
        case .files: model.send?.openFiles()
        }
    }

    private func sendPhotosButton(_ sender: MobileSendModel) -> some View {
        Button { openSend(.photos) } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "photo.on.rectangle")
                    .accessibilityHidden(true)
                Text("send.home.photos")
            }
                .frame(maxWidth: .infinity, minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!sender.canSelect)
        .accessibilityIdentifier("home-send-photos")
    }

    private func sendFilesButton(_ sender: MobileSendModel) -> some View {
        Button { openSend(.files) } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "folder")
                    .accessibilityHidden(true)
                Text("send.home.files")
            }
                .frame(maxWidth: .infinity, minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
        .disabled(!sender.canSelect)
        .accessibilityIdentifier("home-send-files")
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

private enum HomeSendPresentation: String, Identifiable {
    case manual, photos, files
    var id: String { rawValue }
    var source: MobileSendStart? {
        switch self {
        case .manual: nil
        case .photos: .photos
        case .files: .files
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
                Image(systemName: "network")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                details
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PeerConnectionPresentation.displayName(device.displayName, unnamed: String(localized: "presence.unnamed")))
            Text(LocalizedStringKey(presentation.rawValue))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MobileDeviceDetailView: View {
    let device: DeviceSummary
    @Bindable var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
    @State private var renaming = false
    @State private var proposedName = ""

    private var currentDevice: DeviceSummary {
        model.currentDevice(device)
    }

    private var validProposedName: Bool {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 512
    }

    var body: some View {
        List {
            Section("devices.details") {
                LabeledContent("devices.name", value: PeerConnectionPresentation.displayName(
                    currentDevice.displayName, unnamed: String(localized: "presence.unnamed")))
                LabeledContent("devices.status") { Text(LocalizedStringKey(model.presentation(for: currentDevice).rawValue)) }
                LabeledContent("devices.id") {
                    Text(device.id.rawValue.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let key = model.renameFailureKey {
                Section { Text(LocalizedStringKey(key)).foregroundStyle(.secondary) }
                    .accessibilityIdentifier("device-rename-error")
            }
            Section {
                Button("devices.rename") {
                    proposedName = currentDevice.displayName
                    renaming = true
                }
                .disabled(model.renamingDeviceID != nil)
                .accessibilityIdentifier("rename-device-\(device.id.rawValue.uuidString)")
                if model.manualPeerIDs.contains(device.id) {
                Button("devices.remove.manual", role: .destructive) { confirmingRemoval = true }
                    .accessibilityIdentifier("remove-device-\(device.id.rawValue.uuidString)")
                    .disabled(model.removalState == .removing || model.removalState == .saveFailed)
                }
            }
            if !model.manualPeerIDs.contains(device.id), let settings = model.settings {
                Section {
                    Text("devices.account.managed").foregroundStyle(.secondary)
                    NavigationLink("account.title") { MobileAccountView(model: settings.account) }
                        .accessibilityIdentifier("device-account-management")
                }
            }
        }
        .navigationTitle(PeerConnectionPresentation.displayName(currentDevice.displayName,
            unnamed: String(localized: "presence.unnamed")))
        .alert("devices.rename.title", isPresented: $renaming) {
            TextField("devices.rename.placeholder", text: $proposedName)
            Button("action.cancel", role: .cancel) {}
            Button("devices.rename") {
                Task {
                    if await model.renameDevice(device.id, name: proposedName) { renaming = false }
                    else { renaming = true }
                }
            }
            .disabled(!validProposedName || model.renamingDeviceID != nil)
        } message: {
            Text("devices.rename.help")
        }
        .alert("devices.remove.title", isPresented: $confirmingRemoval) {
            Button("action.cancel", role: .cancel) {}
            Button("devices.remove", role: .destructive) {
                model.removeDevice(device.id)
                dismiss()
            }
        } message: { Text("devices.remove.manual.confirm") }
    }
}
