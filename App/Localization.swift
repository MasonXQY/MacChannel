import Combine
import Foundation

enum LocalizedContent: Equatable, Sendable {
    case verbatim(String)
    case keys([LocalizedKey])

    var text: String {
        switch self {
        case let .verbatim(value): value
        case let .keys(keys): keys.map { L10n.text($0) }.joined(separator: " ")
        }
    }
}

package enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case simplifiedChinese
    case english

    func localeIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .simplifiedChinese: "zh-Hans"
        case .english: "en"
        case .system: preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
        }
    }
}

package enum LocalizedKey: String, CaseIterable, Sendable {
    case transferPreparing = "transfer.preparing"
    case transferConnecting = "transfer.connecting"
    case transferTransferring = "transfer.transferring"
    case transferPaused = "transfer.paused"
    case transferVerifying = "transfer.verifying"
    case transferCancelling = "transfer.cancelling"
    case transferCompleted = "transfer.completed"
    case transferFailed = "transfer.failed"
    case transferCancelled = "transfer.cancelled"
    case transferRouteLan = "transfer.route.lan"
    case transferRouteDirectInternet = "transfer.route.directInternet"
    case transferRouteRelay = "transfer.route.relay"
    case transferFailureHelp = "transfer.failureHelp"
    case transferSpeedCalculating = "transfer.speed.calculating"
    case transferSpeedValue = "transfer.speed.value"
    case transferEtaCalculating = "transfer.eta.calculating"
    case transferEtaMinutes = "transfer.eta.minutes"
    case transferEtaSeconds = "transfer.eta.seconds"
    case transferPauseFailed = "transfer.pauseFailed"
    case transferResumeFailed = "transfer.resumeFailed"
    case transferCancelFailed = "transfer.cancelFailed"
    case transferSectionActive = "transfer.section.active"
    case transferSectionHistory = "transfer.section.history"
    case transferTitle = "transfer.title"
    case commonClose = "common.close"
    case transferClose = "transfer.close"
    case transferContent = "transfer.content"
    case transferEmptyActive = "transfer.empty.active"
    case transferEmptyHistory = "transfer.empty.history"
    case transferProgress = "transfer.progress"
    case commonPause = "common.pause"
    case commonResume = "common.resume"
    case commonCancel = "common.cancel"
    case receiveReveal = "receive.reveal"
    case receiveRevealHint = "receive.revealHint"
    case sendFilePickerMessage = "send.filePicker.message"
    case commonChoose = "common.choose"
    case sendChooseDevice = "send.chooseDevice"
    case sendDeviceAccessibility = "send.deviceAccessibility"
    case deviceLan = "device.lan"
    case deviceInternet = "device.internet"
    case deviceOffline = "device.offline"
    case statusLocalTest = "status.localTest"
    case deviceOther = "device.other"
    case sendNoOnlineDevice = "send.noOnlineDevice"
    case clipboardEmpty = "clipboard.empty"
    case clipboardPrepareFailed = "clipboard.prepareFailed"
    case sendInvalidSelection = "send.invalidSelection"
    case sendNoDevices = "send.noDevices"
    case sendTransferInProgress = "send.transferInProgress"
    case receiveNotFound = "receive.notFound"
    case updateWindowUnavailable = "update.windowUnavailable"
    case updateOpenWindow = "update.openWindow"
    case sendDeviceOffline = "send.deviceOffline"
    case sendStartFailed = "send.startFailed"
    case statusRetryStartup = "status.retryStartup"
    case receiveRecent = "receive.recent"
    case receiveAllHistory = "receive.allHistory"
    case sendFiles = "send.files"
    case sendClipboard = "send.clipboard"
    case pairingTitle = "pairing.title"
    case settingsTitle = "settings.title"
    case updateAvailable = "update.available"
    case appQuit = "app.quit"
    case appAccessibilityLabel = "app.accessibilityLabel"
    case appAccessibilityHelp = "app.accessibilityHelp"
    case updateAvailableUnavailable = "update.availableUnavailable"
    case receiveUnread = "receive.unread"
    case receiveItemAccessibility = "receive.itemAccessibility"
    case receiveOverflow = "receive.overflow"
    case receiveDirectoryGuidance = "receive.directory.guidance"
    case receiveDirectoryLegacy = "receive.directory.legacy"
    case settingsSaveNameFailed = "settings.saveNameFailed"
    case settingsAutoReceiveFailed = "settings.autoReceiveFailed"
    case settingsLoginPermissionFailed = "settings.loginPermissionFailed"
    case settingsLoginSaveFailed = "settings.loginSaveFailed"
    case settingsDeviceNameFailed = "settings.deviceNameFailed"
    case settingsRevokeFailed = "settings.revokeFailed"
    case settingsReceivePolicyFailed = "settings.receivePolicyFailed"
    case receiveDirectoryDefaultSaveFailed = "receive.directory.defaultSaveFailed"
    case receiveDirectorySaveFailed = "receive.directory.saveFailed"
    case receiveDirectoryRevealFailed = "receive.directory.revealFailed"
    case receiveDirectoryChoose = "receive.directory.choose"
    case receiveDirectoryPickerMessage = "receive.directory.pickerMessage"
    case settingsThisMac = "settings.thisMac"
    case settingsLocalName = "settings.localName"
    case commonSave = "common.save"
    case settingsReceiveFiles = "settings.receiveFiles"
    case settingsAutoReceive = "settings.autoReceive"
    case receiveDirectoryAccessibility = "receive.directory.accessibility"
    case commonChooseEllipsis = "common.chooseEllipsis"
    case settingsPairedMacs = "settings.pairedMacs"
    case settingsNoMacs = "settings.noMacs"
    case settingsStartup = "settings.startup"
    case settingsLaunchAtLogin = "settings.launchAtLogin"
    case settingsLocalNetwork = "settings.localNetwork"
    case commonSystemSettings = "common.systemSettings"
    case settingsRetryLocalNetwork = "settings.retryLocalNetwork"
    case settingsDiagnostics = "settings.diagnostics"
    case settingsSecureService = "settings.secureService"
    case settingsEncryptionExplanation = "settings.encryptionExplanation"
    case settingsClose = "settings.close"
    case statusStartingApp = "status.startingApp"
    case settingsPreparing = "settings.preparing"
    case settingsNotifications = "settings.notifications"
    case permissionAllowed = "permission.allowed"
    case permissionNotAllowed = "permission.notAllowed"
    case updateViewStore = "update.viewStore"
    case updateView = "update.view"
    case updateCheck = "update.check"
    case updateTitle = "update.title"
    case updateLastChecked = "update.lastChecked"
    case updateViewHint = "update.viewHint"
    case updateCheckHint = "update.checkHint"
    case updateViewUnavailable = "update.viewUnavailable"
    case commonRemove = "common.remove"
    case settingsRemoveHint = "settings.removeHint"
    case settingsDeviceName = "settings.deviceName"
    case settingsRename = "settings.rename"
    case deviceNearby = "device.nearby"
    case deviceOnline = "device.online"
    case receiveFileCount = "receive.fileCount"
    case statusTrustSaveFailed = "status.trustSaveFailed"
    case statusServiceRecovering = "status.service.recovering"
    case statusServiceRetrying = "status.service.retrying"
    case statusServiceOffline = "status.service.offline"
    case statusServiceConnecting = "status.service.connecting"
    case devicePaired = "device.paired"
    case trustRevokePartial = "trust.revokePartial"
    case trustPeerApprovalIncomplete = "trust.peerApprovalIncomplete"
    case trustRecordsSaveFailed = "trust.recordsSaveFailed"
    case trustSettingsSaveFailed = "trust.settingsSaveFailed"
    case deviceUnknown = "device.unknown"
    case deviceMore = "device.more"
    case deviceHiddenCount = "device.hiddenCount"
    case deviceSendAccessibility = "device.sendAccessibility"
    case sendRelease = "send.release"
    case deviceExpandAll = "device.expandAll"
    case pairingGenerateFailed = "pairing.generateFailed"
    case pairingCompleteFailed = "pairing.completeFailed"
    case pairingVerifyFailed = "pairing.verifyFailed"
    case pairingAllowFailed = "pairing.allowFailed"
    case pairingRejectFailed = "pairing.rejectFailed"
    case pairingCancelFailed = "pairing.cancelFailed"
    case pairingClose = "pairing.close"
    case pairingUnavailable = "pairing.unavailable"
    case pairingUnavailableHelp = "pairing.unavailableHelp"
    case pairingVerifying = "pairing.verifying"
    case pairingVerifyingAccessibility = "pairing.verifyingAccessibility"
    case pairingWaitingApproval = "pairing.waitingApproval"
    case pairingConnecting = "pairing.connecting"
    case pairingRefreshing = "pairing.refreshing"
    case pairingTrusted = "pairing.trusted"
    case pairingConfirmOtherMac = "pairing.confirmOtherMac"
    case pairingEnterInstructions = "pairing.enterInstructions"
    case pairingSixDigitCode = "pairing.sixDigitCode"
    case pairingEnterCode = "pairing.enterCode"
    case pairingGenerateCode = "pairing.generateCode"
    case pairingEnterOnOtherMac = "pairing.enterOnOtherMac"
    case pairingLocalCode = "pairing.localCode"
    case pairingExpires = "pairing.expires"
    case pairingJoinRequest = "pairing.joinRequest"
    case pairingApprovalInstructions = "pairing.approvalInstructions"
    case commonReject = "common.reject"
    case commonAllow = "common.allow"
    case commonBack = "common.back"
    case pairingInvalidCode = "pairing.invalidCode"
    case pairingExpiredCode = "pairing.expiredCode"
    case pairingUsedCode = "pairing.usedCode"
    case pairingRateLimited = "pairing.rateLimited"
    case pairingRejected = "pairing.rejected"
    case pairingFingerprintMismatch = "pairing.fingerprintMismatch"
    case pairingSessionExpired = "pairing.sessionExpired"
    case pairingFailed = "pairing.failed"
    case sendKeyboardRequired = "send.keyboardRequired"
    case sendDragChanged = "send.dragChanged"
    case devicePairedWithSuffix = "device.pairedWithSuffix"
    case statusIdle = "status.idle"
    case statusTransferring = "status.transferring"
    case transferFallbackName = "transfer.fallbackName"
    case statusDistributionConflict = "status.distributionConflict"
    case clipboardImage = "clipboard.image"
    case clipboardText = "clipboard.text"
    case clipboardFileName = "clipboard.fileName"
    case receiveNotificationTitle = "receive.notification.title"
    case receiveNotificationSingle = "receive.notification.single"
    case receiveNotificationMultiple = "receive.notification.multiple"
    case updateVersionUnknown = "update.versionUnknown"
    case updateAutomaticExplanation = "update.automaticExplanation"
    case updateChecking = "update.checking"
    case updateUpToDate = "update.upToDate"
    case updateVersionAvailable = "update.versionAvailable"
    case updateDownloading = "update.downloading"
    case updateDeferred = "update.deferred"
    case updateStoreManaged = "update.storeManaged"
    case updateCheckFailed = "update.checkFailed"
    case updateSecurityFailure = "update.securityFailure"
    case updateNeverChecked = "update.neverChecked"
    case receiveDirectoryReauthorize = "receive.directory.reauthorize"
    case statusServiceStarting = "status.service.starting"
    case statusServiceConnected = "status.service.connected"
    case statusStartupKeychain = "status.startup.keychain"
    case statusStartupIdentity = "status.startup.identity"
    case statusStartupStorage = "status.startup.storage"
    case onboardingMenuBar = "onboarding.menuBar"
    case onboardingDestination = "onboarding.destination"
    case onboardingPermissions = "onboarding.permissions"
    case onboardingPairing = "onboarding.pairing"
    case onboardingChannelSwitch = "onboarding.channelSwitch"
    case onboardingWelcome = "onboarding.welcome"
    case onboardingTagline = "onboarding.tagline"
    case commonOpenSettings = "common.openSettings"
    case onboardingSettingsHint = "onboarding.settingsHint"
    case commonDone = "common.done"
    case onboardingCloseHint = "onboarding.closeHint"
    case permissionLocalNetworkDenied = "permission.localNetworkDenied"
    case settingsLanguage = "settings.language"
    case languageSystem = "language.system"
    case languageChinese = "language.chinese"
    case languageEnglish = "language.english"
    case updateVersion = "update.version"
    case receiveMenuFallback = "receive.menuFallback"
    case presentationListSeparator = "presentation.listSeparator"
    case sendReady = "send.ready"
    case sendReadyAccessibility = "send.readyAccessibility"

    enum ArgumentType: Equatable { case string, integer }
    var argumentTypes: [ArgumentType] {
        switch self {
        case .transferSpeedValue: [.string]
        case .transferEtaMinutes: [.integer, .integer]
        case .transferEtaSeconds: [.integer]
        case .sendDeviceAccessibility: [.string, .string]
        case .receiveItemAccessibility: [.string, .string]
        case .receiveOverflow: [.integer]
        case .receiveDirectoryAccessibility: [.string]
        case .updateLastChecked: [.string]
        case .receiveFileCount: [.integer]
        case .deviceHiddenCount: [.integer]
        case .deviceSendAccessibility: [.string, .string]
        case .pairingWaitingApproval: [.string]
        case .pairingConnecting: [.string]
        case .pairingTrusted: [.string]
        case .pairingExpires: [.integer]
        case .pairingJoinRequest: [.string]
        case .devicePairedWithSuffix: [.string]
        case .statusTransferring: [.string]
        case .clipboardFileName: [.string, .string]
        case .receiveNotificationSingle: [.string]
        case .receiveNotificationMultiple: [.integer]
        case .updateVersionAvailable: [.string]
        case .updateVersion, .receiveMenuFallback: [.string, .string]
        default: []
        }
    }
}

/// Immutable catalogs can also be read from background runtime/notification tasks.
/// Mutable language state is protected independently from the transfer runtime.
package enum L10n {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: LocalizationController.preferenceKey) ?? "") ?? .system
    }
    private static let state = State()

    package static var language: AppLanguage {
        state.lock.withLock { state.language }
    }

    static func select(_ language: AppLanguage) {
        state.lock.withLock { state.language = language }
    }

    static func bundle(for language: AppLanguage) -> Bundle {
        let locale = language.localeIdentifier()
        guard let url = Bundle.module.url(forResource: locale, withExtension: "lproj", subdirectory: "Resources"),
              let bundle = Bundle(url: url) else {
            preconditionFailure("Missing localization bundle: \(locale)")
        }
        return bundle
    }

    package static func text(_ key: LocalizedKey, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments, language: language)
    }

    static func format(_ key: LocalizedKey, arguments: [CVarArg], language: AppLanguage) -> String {
        precondition(arguments.count == key.argumentTypes.count, "Localization argument count: \(key.rawValue)")
        let format = bundle(for: language).localizedString(forKey: key.rawValue, value: nil, table: nil)
        return String(format: format, locale: Locale(identifier: language.localeIdentifier()), arguments: arguments)
    }
}

@MainActor
package final class LocalizationController: ObservableObject {
    nonisolated static let preferenceKey = "appLanguage"
    static let shared = LocalizationController()
    @Published package private(set) var language: AppLanguage
    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
    }

    package func text(_ key: LocalizedKey, _ arguments: CVarArg...) -> String {
        L10n.format(key, arguments: arguments, language: language)
    }

    package func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        L10n.select(language)
        defaults.set(language.rawValue, forKey: Self.preferenceKey)
        self.language = language
    }
}
