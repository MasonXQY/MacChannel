import AppKit
import Combine
import MacChannelCore
import SwiftUI

enum SettingsSizeLimit {
    static func bytes(megabytes value: String) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasValidDecimalSyntax(trimmed),
            let megabytes = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")),
            megabytes > 0
        else { return nil }
        var unroundedBytes = megabytes * Decimal(1_000_000)
        var roundedBytes = Decimal()
        NSDecimalRound(&roundedBytes, &unroundedBytes, 0, .plain)
        guard roundedBytes > 0, roundedBytes <= Decimal(UInt64.max) else { return nil }
        return NSDecimalNumber(decimal: roundedBytes).uint64Value
    }

    static func megabytes(bytes: UInt64?) -> String {
        guard let bytes else { return "" }
        return NSDecimalNumber(decimal: Decimal(bytes) / Decimal(1_000_000)).stringValue
    }

    static func isValidInput(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || bytes(megabytes: trimmed) != nil
    }

    private static func hasValidDecimalSyntax(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}

struct DeviceSetting: Identifiable, Equatable, Sendable {
    let id: DeviceID
    var displayName: String
    var availability: DeviceAvailability
    var autoAccept: Bool
    var maximumMegabytes: String
    var directory: URL?

    init(
        device: DeviceSummary,
        autoAccept: Bool = true,
        maximumBytes: UInt64? = nil,
        directory: URL? = nil
    ) {
        id = device.id
        displayName = device.displayName
        availability = device.availability
        self.autoAccept = autoAccept
        maximumMegabytes = SettingsSizeLimit.megabytes(bytes: maximumBytes)
        self.directory = directory
    }
}

struct SettingsSurfaceSnapshot: Equatable, Sendable {
    let localDisplayName: String
    let defaultDirectory: URL?
    let autoReceive: Bool
    let launchAtLogin: Bool
    let devices: [DeviceSetting]
    let directoryAuthorizationError: String?

    init(
        localDisplayName: String = Host.current().localizedName ?? "Mac",
        defaultDirectory: URL?,
        autoReceive: Bool = true,
        launchAtLogin: Bool = false,
        devices: [DeviceSetting],
        directoryAuthorizationError: String? = nil
    ) {
        self.localDisplayName = localDisplayName
        self.defaultDirectory = defaultDirectory
        self.autoReceive = autoReceive
        self.launchAtLogin = launchAtLogin
        self.devices = devices
        self.directoryAuthorizationError = directoryAuthorizationError
    }
}

@MainActor
protocol DirectorySelecting: AnyObject {
    func chooseDirectory(current: URL?) -> URL?
}

@MainActor
protocol DirectoryRevealing: AnyObject {
    func revealDirectory(_ directory: URL) throws
}

@MainActor
protocol DeviceSettingsServicing: AnyObject {
    var isAvailable: Bool { get }
    func updateLocalDisplayName(_ name: String) async throws
    func updateAutoReceive(_ enabled: Bool) async throws
    func updateLaunchAtLogin(_ enabled: Bool) async throws
    func rename(_ id: DeviceID, to displayName: String) async throws
    func revoke(_ id: DeviceID) async throws -> SurfaceActionResult
    func updateReceivePolicy(
        _ id: DeviceID,
        autoAccept: Bool,
        maximumBytes: UInt64?
    ) async throws
    func updateDefaultDirectory(_ directory: URL) async throws
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws
}

extension DeviceSettingsServicing {
    func updateLocalDisplayName(_ name: String) async throws {
        throw DeviceSettingsSurfaceError.unavailable
    }
    func updateAutoReceive(_ enabled: Bool) async throws {
        throw DeviceSettingsSurfaceError.unavailable
    }
    func updateLaunchAtLogin(_ enabled: Bool) async throws {
        throw DeviceSettingsSurfaceError.unavailable
    }
}

private enum DeviceSettingsSurfaceError: Error { case unavailable }

enum SettingsReceiveDirectoryPresentation {
    static var guidance: String { L10n.text(.receiveDirectoryGuidance) }

    static func directory(
        defaultDirectory: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        defaultDirectory?.standardizedFileURL
            ?? DownloadDirectory(homeDirectory: homeDirectory).defaultDirectory
    }

    static func path(
        defaultDirectory: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        guard defaultDirectory != nil else { return L10n.text(.receiveDirectoryLegacy) }
        let home = homeDirectory.standardizedFileURL
        let directory = directory(defaultDirectory: defaultDirectory, homeDirectory: home)
        var path = directory.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let homePath = home.path(percentEncoded: false)
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }
}

@MainActor
final class SettingsSurfaceModel: ObservableObject {
    @Published var localDisplayName: String
    @Published var defaultDirectory: URL?
    @Published var autoReceive: Bool
    @Published var launchAtLogin: Bool
    @Published var devices: [DeviceSetting]
    @Published var runtimeStatus: AppRuntimeStatus
    @Published var runtimePresence = RuntimePresenceSnapshot()
    @Published var updateSnapshot: SoftwareUpdateSnapshot
    @Published var receiveNotificationSnapshot: ReceiveNotificationSnapshot
    @Published var actionErrorContent: LocalizedContent?
    var actionError: String? {
        get { actionErrorContent?.text }
        set { actionErrorContent = newValue.map(LocalizedContent.verbatim) }
    }
    @Published var actionNotice: String?
    private let announcer: any AccessibilityAnnouncing
    private var openNotificationSettingsHandler: (() -> Void)?

    init(
        localDisplayName: String = Host.current().localizedName ?? "Mac",
        defaultDirectory: URL? = nil,
        autoReceive: Bool = true,
        launchAtLogin: Bool = false,
        devices: [DeviceSetting] = [],
        runtimeStatus: AppRuntimeStatus = .loading,
        updateSnapshot: SoftwareUpdateSnapshot = SoftwareUpdateSnapshot(
            installedVersion: InstalledAppVersion(),
            phase: .idle,
            canCheck: false,
            lastCheckedAt: nil
        ),
        receiveNotificationSnapshot: ReceiveNotificationSnapshot = ReceiveNotificationSnapshot(
            authorizationState: .notDetermined
        ),
        actionError: String? = nil,
        announcer: (any AccessibilityAnnouncing)? = nil
    ) {
        self.localDisplayName = localDisplayName
        self.defaultDirectory = defaultDirectory
        self.autoReceive = autoReceive
        self.launchAtLogin = launchAtLogin
        self.devices = devices
        self.runtimeStatus = runtimeStatus
        self.updateSnapshot = updateSnapshot
        self.receiveNotificationSnapshot = receiveNotificationSnapshot
        self.actionErrorContent = actionError.map(LocalizedContent.verbatim)
        self.announcer = announcer ?? NativeAccessibilityAnnouncer.shared
    }

    func updateLocalDisplayName(
        _ value: String,
        using service: any DeviceSettingsServicing
    ) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previous = localDisplayName
        do {
            try await service.updateLocalDisplayName(trimmed)
            localDisplayName = trimmed
            actionError = nil
        } catch {
            localDisplayName = previous
            publishError(.settingsSaveNameFailed)
        }
    }

    func updateAutoReceive(
        _ enabled: Bool,
        using service: any DeviceSettingsServicing
    ) async {
        let previous = autoReceive
        do {
            try await service.updateAutoReceive(enabled)
            autoReceive = enabled
            actionError = nil
        } catch {
            autoReceive = previous
            publishError(.settingsAutoReceiveFailed)
        }
    }

    func updateLaunchAtLogin(
        _ enabled: Bool,
        loginItems: any LoginItemRegistering,
        using service: any DeviceSettingsServicing
    ) async {
        let previous = launchAtLogin
        do {
            try loginItems.setEnabled(enabled)
        } catch {
            launchAtLogin = previous
            publishError(.settingsLoginPermissionFailed)
            return
        }
        do {
            try await service.updateLaunchAtLogin(enabled)
            launchAtLogin = enabled
            actionError = nil
        } catch {
            try? loginItems.setEnabled(previous)
            launchAtLogin = previous
            publishError(.settingsLoginSaveFailed)
        }
    }

    func rename(
        _ id: DeviceID,
        to displayName: String,
        using service: any DeviceSettingsServicing
    ) async {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await service.rename(id, to: name)
            mutate(id) { $0.displayName = name }
            actionError = nil
        } catch {
            publishError(.settingsDeviceNameFailed)
        }
    }

    func revoke(_ id: DeviceID, using service: any DeviceSettingsServicing) async {
        do {
            let result = try await service.revoke(id)
            devices.removeAll { $0.id == id }
            actionErrorContent = result.warningContent
            if let warning = result.warning { announcer.announce(warning) }
        } catch {
            publishError(.settingsRevokeFailed)
        }
    }

    func updatePolicy(
        _ id: DeviceID,
        autoAccept: Bool,
        maximumBytes: UInt64?,
        using service: any DeviceSettingsServicing
    ) async {
        do {
            try await service.updateReceivePolicy(
                id,
                autoAccept: autoAccept,
                maximumBytes: maximumBytes
            )
            mutate(id) {
                $0.autoAccept = autoAccept
                $0.maximumMegabytes = SettingsSizeLimit.megabytes(bytes: maximumBytes)
            }
            actionError = nil
        } catch {
            publishError(.settingsReceivePolicyFailed)
        }
    }

    func updateDefaultDirectory(
        _ directory: URL,
        using service: any DeviceSettingsServicing
    ) async {
        do {
            try await service.updateDefaultDirectory(directory)
            defaultDirectory = directory
            actionError = nil
        } catch {
            publishError(error is DirectoryAuthorizationError ? .receiveDirectoryReauthorize : .receiveDirectoryDefaultSaveFailed)
        }
    }

    func updateDirectory(
        _ directory: URL?,
        for id: DeviceID,
        using service: any DeviceSettingsServicing
    ) async {
        do {
            try await service.updateDirectory(directory, for: id)
            mutate(id) { $0.directory = directory }
            actionError = nil
        } catch {
            publishError(error is DirectoryAuthorizationError ? .receiveDirectoryReauthorize : .receiveDirectorySaveFailed)
        }
    }

    func performUpdateAction(using service: any SoftwareUpdateServicing) {
        guard service.isAvailable else { return }
        if updateSnapshot.phase.hasAvailableUpdate {
            guard updateSnapshot.canShowUpdate else { return }
            service.showAvailableUpdate()
        } else {
            guard updateSnapshot.canCheck else { return }
            service.checkForUpdates()
        }
    }

    func updateReceiveNotification(
        _ snapshot: ReceiveNotificationSnapshot,
        openSystemSettings: @escaping () -> Void
    ) {
        receiveNotificationSnapshot = snapshot
        openNotificationSettingsHandler = openSystemSettings
    }

    func openNotificationSettings() {
        guard receiveNotificationSnapshot.authorizationState == .denied else { return }
        openNotificationSettingsHandler?()
    }

    func revealDefaultDirectory(
        using revealer: any DirectoryRevealing,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let directory = SettingsReceiveDirectoryPresentation.directory(
            defaultDirectory: defaultDirectory,
            homeDirectory: homeDirectory
        )
        do {
            try revealer.revealDirectory(directory)
            actionError = nil
        } catch {
            publishError(.receiveDirectoryRevealFailed)
        }
    }

    private func publishError(_ key: LocalizedKey) {
        actionNotice = nil
        actionErrorContent = .keys([key])
        announcer.announce(L10n.text(key))
    }

    private func mutate(_ id: DeviceID, _ body: (inout DeviceSetting) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        body(&devices[index])
    }
}

@MainActor
final class NativeDirectorySelector: DirectorySelecting {
    func chooseDirectory(current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text(.receiveDirectoryChoose)
        panel.prompt = L10n.text(.commonChoose)
        panel.message = L10n.text(.receiveDirectoryPickerMessage)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = current
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
final class NativeDirectoryRevealer: DirectoryRevealing {
    static let shared = NativeDirectoryRevealer()

    func revealDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

struct SettingsView: View {
    @EnvironmentObject private var localization: LocalizationController
    @ObservedObject var model: SettingsSurfaceModel
    let service: any DeviceSettingsServicing
    let directorySelector: any DirectorySelecting
    let directoryRevealer: any DirectoryRevealing
    let updateService: any SoftwareUpdateServicing
    @ObservedObject var localNetworkModel: LocalNetworkPermissionModel
    let loginItems: any LoginItemRegistering
    let onRetryRuntime: () -> Void
    let onRetryPresence: () -> Void
    let onRetryTrustSave: () -> Void
    let onDismiss: () -> Void
    @State private var draftLocalName: String

    init(
        model: SettingsSurfaceModel,
        service: any DeviceSettingsServicing,
        directorySelector: any DirectorySelecting,
        directoryRevealer: any DirectoryRevealing = NativeDirectoryRevealer.shared,
        updateService: any SoftwareUpdateServicing,
        localNetworkModel: LocalNetworkPermissionModel = LocalNetworkPermissionModel(),
        loginItems: any LoginItemRegistering = LoginItemController.shared,
        onRetryRuntime: @escaping () -> Void = {},
        onRetryPresence: @escaping () -> Void = {},
        onRetryTrustSave: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.service = service
        self.directorySelector = directorySelector
        self.directoryRevealer = directoryRevealer
        self.updateService = updateService
        self.localNetworkModel = localNetworkModel
        self.loginItems = loginItems
        self.onRetryRuntime = onRetryRuntime
        self.onRetryPresence = onRetryPresence
        self.onRetryTrustSave = onRetryTrustSave
        self.onDismiss = onDismiss
        _draftLocalName = State(initialValue: model.localDisplayName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            statusMessages
            Divider()
            Form {
                Section(L10n.text(.settingsLanguage)) {
                    Picker(L10n.text(.settingsLanguage), selection: Binding(
                        get: { localization.language },
                        set: { localization.setLanguage($0) }
                    )) {
                        Text(L10n.text(.languageSystem)).tag(AppLanguage.system)
                        Text(L10n.text(.languageChinese)).tag(AppLanguage.simplifiedChinese)
                        Text(L10n.text(.languageEnglish)).tag(AppLanguage.english)
                    }
                }
                Group {
                    Section(L10n.text(.settingsThisMac)) {
                        HStack {
                            TextField(L10n.text(.settingsLocalName), text: $draftLocalName)
                                .frame(minHeight: 40)
                                .onSubmit(saveLocalName)
                                .accessibilityLabel(L10n.text(.settingsLocalName))
                            Button(L10n.text(.commonSave), action: saveLocalName)
                                .disabled(
                                    draftLocalName.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .isEmpty
                                )
                                .frame(minHeight: 40)
                        }
                    }

                    Section(L10n.text(.settingsReceiveFiles)) {
                        Toggle(L10n.text(.settingsAutoReceive), isOn: autoReceiveBinding)
                            .frame(minHeight: 40)
                        HStack {
                            Label(defaultDirectoryText, systemImage: "folder")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityLabel(L10n.text(.receiveDirectoryAccessibility, String(defaultDirectoryText)))
                            Spacer()
                            Button(L10n.text(.commonChooseEllipsis), action: chooseDefaultDirectory)
                                .frame(minHeight: 40)
                            Button(L10n.text(.receiveReveal)) {
                                model.revealDefaultDirectory(using: directoryRevealer)
                            }
                            .frame(minHeight: 40)
                        }
                        Text(SettingsReceiveDirectoryPresentation.guidance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section(L10n.text(.settingsPairedMacs)) {
                        if model.devices.isEmpty {
                            Label(L10n.text(.settingsNoMacs), systemImage: "desktopcomputer")
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 60)
                        } else {
                            ForEach(model.devices) { device in
                                DeviceSettingRow(device: device, model: model, service: service)
                            }
                        }
                    }

                    Section(L10n.text(.settingsStartup)) {
                        Toggle(L10n.text(.settingsLaunchAtLogin), isOn: launchAtLoginBinding)
                            .frame(minHeight: 40)
                    }
                }
                .disabled(!service.isAvailable)

                ReceiveNotificationSettingsRow(
                    snapshot: model.receiveNotificationSnapshot,
                    openSystemSettings: model.openNotificationSettings
                )

                if localNetworkModel.capability == .unavailable {
                    Section(L10n.text(.settingsLocalNetwork)) {
                        Text(localNetworkModel.guidanceText ?? "")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(localNetworkModel.guidanceText ?? "")
                        HStack {
                            Button(L10n.text(.commonSystemSettings), action: localNetworkModel.openSystemSettings)
                            Button(L10n.text(.settingsRetryLocalNetwork), action: localNetworkModel.retry)
                        }
                    }
                }

                SoftwareUpdateSection(
                    snapshot: model.updateSnapshot,
                    serviceAvailable: updateService.isAvailable,
                    performAction: { model.performUpdateAction(using: updateService) }
                )

                DisclosureGroup(L10n.text(.settingsDiagnostics)) {
                    Label(L10n.text(.settingsSecureService), systemImage: "lock.shield")
                    Text(L10n.text(.settingsEncryptionExplanation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!service.isAvailable)
            }
            .formStyle(.grouped)
        }
        .frame(width: 540, height: 650)
        .onExitCommand(perform: onDismiss)
        .onChange(of: model.localDisplayName) { _, updated in draftLocalName = updated }
    }

    private var header: some View {
        HStack {
            Label(L10n.text(.settingsTitle), systemImage: "gearshape")
                .font(.title2.weight(.semibold))
            Spacer()
            Button(L10n.text(.commonClose), systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityLabel(L10n.text(.settingsClose))
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusMessages: some View {
        if service.isAvailable {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text(model.runtimePresence.authenticated ? .statusServiceConnected : .statusServiceRecovering))
                Text(L10n.text(.presenceServiceExplanation)).font(.caption).foregroundStyle(.secondary)
                if model.runtimePresence.trustSync == .needsAttention {
                    Label(L10n.text(.presenceSyncAttention), systemImage: "exclamationmark.triangle")
                } else if model.runtimePresence.trustSync == .pendingPersistence {
                    Text(L10n.text(.presencePendingSave))
                } else if model.runtimePresence.authenticated && model.runtimePresence.trustSync != .synchronized {
                    Text(L10n.text(.presenceSyncing))
                }
                if model.runtimePresence.trustSaveFailed {
                    Text(L10n.text(.statusTrustSaveFailed))
                    Button(L10n.text(.presenceRetrySave), action: onRetryTrustSave)
                }
                if !model.runtimePresence.authenticated || model.runtimePresence.trustSync == .needsAttention {
                    Button(L10n.text(.presenceRetryService), action: onRetryPresence)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        if !service.isAvailable {
            switch model.runtimeStatus {
            case .loading:
                Label(L10n.text(.statusStartingApp), systemImage: "hourglass")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            case let .startupError(message, canRetry):
                HStack(alignment: .center, spacing: 12) {
                    Label(message, systemImage: "key")
                        .foregroundStyle(.orange)
                    if canRetry {
                        Spacer()
                        Button(L10n.text(.statusRetryStartup), action: onRetryRuntime)
                            .frame(minHeight: 40)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            case let .error(message), let .offline(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            case let .startupFailure(_, canRetry):
                HStack {
                    Label(model.runtimeStatus.localizedText, systemImage: "key")
                        .foregroundStyle(.orange)
                    if canRetry {
                        Button(L10n.text(.statusRetryStartup), action: onRetryRuntime)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            case .serviceError, .serviceOffline:
                Label(model.runtimeStatus.localizedText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            case .ready:
                Label(L10n.text(.settingsPreparing), systemImage: "hourglass")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        if let error = model.actionError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .accessibilityLabel(error)
        }
    }

    private var autoReceiveBinding: Binding<Bool> {
        Binding(
            get: { model.autoReceive },
            set: { enabled in
                Task { await model.updateAutoReceive(enabled, using: service) }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { enabled in
                Task {
                    await model.updateLaunchAtLogin(
                        enabled,
                        loginItems: loginItems,
                        using: service
                    )
                }
            }
        )
    }

    private var defaultDirectoryText: String {
        SettingsReceiveDirectoryPresentation.path(defaultDirectory: model.defaultDirectory)
    }

    private func saveLocalName() {
        Task { await model.updateLocalDisplayName(draftLocalName, using: service) }
    }

    private func chooseDefaultDirectory() {
        guard let selected = directorySelector.chooseDirectory(current: model.defaultDirectory)
        else { return }
        Task { await model.updateDefaultDirectory(selected, using: service) }
    }
}

struct ReceiveNotificationSettingsRow: View {
    @EnvironmentObject private var localization: LocalizationController
    let snapshot: ReceiveNotificationSnapshot
    let openSystemSettings: () -> Void

    var body: some View {
        Section(L10n.text(.settingsNotifications)) {
            HStack {
                Label(L10n.text(.settingsNotifications), systemImage: "bell")
                Spacer()
                Text(snapshot.authorizationState.canDeliverNotifications ? L10n.text(.permissionAllowed) : L10n.text(.permissionNotAllowed))
                    .foregroundStyle(.secondary)
                if snapshot.authorizationState == .denied {
                    Button(L10n.text(.commonSystemSettings), action: openSystemSettings)
                        .buttonStyle(.bordered)
                }
            }
            .frame(minHeight: 40)
        }
    }
}

struct SoftwareUpdateSectionPresentation: Equatable {
    let statusText: String?
    let guidanceText: String
    let lastCheckedText: String
    let actionTitle: String

    init(snapshot: SoftwareUpdateSnapshot, timeZone: TimeZone = .current) {
        if snapshot.phase == .managedByAppStore {
            statusText = nil
            guidanceText = snapshot.phase.statusText
            actionTitle = L10n.text(.updateViewStore)
        } else {
            statusText = snapshot.phase == .idle ? nil : snapshot.phase.statusText
            guidanceText = SoftwareUpdatePhase.idle.statusText
            actionTitle = snapshot.phase.hasAvailableUpdate ? L10n.text(.updateView) : L10n.text(.updateCheck)
        }
        lastCheckedText = snapshot.lastCheckedText(timeZone: timeZone)
    }
}

struct SoftwareUpdateSection: View {
    @EnvironmentObject private var localization: LocalizationController
    let snapshot: SoftwareUpdateSnapshot
    let serviceAvailable: Bool
    let performAction: () -> Void

    var body: some View {
        Section(L10n.text(.updateTitle)) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.installedVersion.localizedText)
                        .font(.body.weight(.medium))
                    if let statusText = presentation.statusText {
                        if isFailure {
                            Text(statusText)
                                .foregroundStyle(.orange)
                        } else {
                            Text(statusText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(L10n.text(.updateLastChecked, String(presentation.lastCheckedText)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(presentation.guidanceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if snapshot.phase.hasAvailableUpdate && !snapshot.canShowUpdate {
                        Text(L10n.text(.updateWindowUnavailable))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Button(actionTitle, action: performAction)
                    .frame(minHeight: 40)
                    .disabled(!actionAvailable)
                    .accessibilityLabel(actionAccessibilityLabel)
                    .accessibilityHint(actionHint)
            }
        }
    }

    private var actionTitle: String {
        presentation.actionTitle
    }

    private var presentation: SoftwareUpdateSectionPresentation {
        SoftwareUpdateSectionPresentation(snapshot: snapshot)
    }

    private var actionAvailable: Bool {
        guard serviceAvailable else { return false }
        return snapshot.phase.hasAvailableUpdate ? snapshot.canShowUpdate : snapshot.canCheck
    }

    private var actionHint: String {
        snapshot.phase.hasAvailableUpdate
            ? L10n.text(.updateViewHint)
            : L10n.text(.updateCheckHint)
    }

    private var actionAccessibilityLabel: String {
        if snapshot.phase.hasAvailableUpdate && !snapshot.canShowUpdate {
            return L10n.text(.updateViewUnavailable)
        }
        return actionTitle
    }

    private var isFailure: Bool {
        switch snapshot.phase {
        case .failed, .securityFailure: true
        case .idle, .checking, .upToDate, .available, .downloading, .installDeferred,
             .managedByAppStore: false
        }
    }
}

struct DeviceSettingRow: View {
    @EnvironmentObject private var localization: LocalizationController
    let device: DeviceSetting
    let model: SettingsSurfaceModel
    let service: any DeviceSettingsServicing
    @State private var draftName: String

    init(
        device: DeviceSetting,
        model: SettingsSurfaceModel,
        service: any DeviceSettingsServicing
    ) {
        self.device = device
        self.model = model
        self.service = service
        _draftName = State(initialValue: device.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if device.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(PeerConnectionPresentation.displayName(device.displayName, unnamed: L10n.text(.presenceUnnamed)))
            }
            HStack {
                Label(statusText, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(
                        presentation == .online || presentation == .onlineNearby ? Color.green : Color.secondary
                    )
                Spacer()
                Button(L10n.text(.commonRemove), systemImage: "trash", role: .destructive) {
                    Task { await model.revoke(device.id, using: service) }
                }
                .frame(minHeight: 40)
                .accessibilityHint(L10n.text(.settingsRemoveHint))
            }
            HStack {
                TextField(L10n.text(.settingsDeviceName), text: $draftName)
                    .frame(minHeight: 40)
                    .onSubmit(saveName)
                Button(L10n.text(.settingsRename), action: saveName)
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 40)
            }
            Text(device.id.rawValue.uuidString.prefix(8))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .onChange(of: device) { _, updated in draftName = updated.displayName }
    }

    private var statusText: String {
        L10n.text(LocalizedKey(rawValue: presentation.rawValue)!)
    }

    private var presentation: PeerConnectionPresentation {
        .resolve(authenticated: model.runtimePresence.authenticated,
                 sync: model.runtimePresence.trustSync, availability: device.availability)
    }

    private var statusSymbol: String {
        switch presentation {
        case .onlineNearby: "wifi"
        case .online: "network"
        case .syncingDevices: "arrow.triangle.2.circlepath"
        case .statusPending, .currentlyUnreachable: "questionmark.circle"
        }
    }

    private func saveName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            await model.rename(device.id, to: name, using: service)
            if model.actionError != nil { draftName = device.displayName }
        }
    }
}

@MainActor
final class UnavailableDeviceSettingsService: DeviceSettingsServicing {
    let isAvailable = false
    func rename(_ id: DeviceID, to displayName: String) async throws {
        throw SettingsSurfaceError.unavailable
    }
    func revoke(_ id: DeviceID) async throws -> SurfaceActionResult {
        throw SettingsSurfaceError.unavailable
    }
    func updateReceivePolicy(
        _ id: DeviceID,
        autoAccept: Bool,
        maximumBytes: UInt64?
    ) async throws { throw SettingsSurfaceError.unavailable }
    func updateDefaultDirectory(_ directory: URL) async throws {
        throw SettingsSurfaceError.unavailable
    }
    func updateDirectory(_ directory: URL?, for id: DeviceID) async throws {
        throw SettingsSurfaceError.unavailable
    }
}

private enum SettingsSurfaceError: Error { case unavailable }
