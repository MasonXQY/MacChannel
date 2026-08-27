import Foundation
import MacChannelCore

@MainActor
final class AppContainer {
    let deviceDirectory: DeviceDirectory
    let transferCoordinator: any TransferCoordinating
    let pairingSurfaceService: any PairingSurfaceServicing
    let settingsSurfaceService: any DeviceSettingsServicing
    let directorySelector: any DirectorySelecting
    let transferSnapshots: (@Sendable () async -> AsyncStream<[TransferSnapshot]>)?
    let pairingStates: AsyncStream<PairingState>?
    let settingsSnapshots: (@Sendable () async -> AsyncStream<SettingsSurfaceSnapshot>)?
    let transferHistory: (@Sendable () async -> AsyncStream<[TransferSurfaceItem]>)?

    init(
        deviceDirectory: DeviceDirectory,
        transferCoordinator: any TransferCoordinating,
        pairingSurfaceService: any PairingSurfaceServicing = UnavailablePairingSurfaceService(),
        settingsSurfaceService: any DeviceSettingsServicing = UnavailableDeviceSettingsService(),
        directorySelector: any DirectorySelecting = NativeDirectorySelector(),
        transferSnapshots: (@Sendable () async -> AsyncStream<[TransferSnapshot]>)? = nil,
        pairingStates: AsyncStream<PairingState>? = nil,
        settingsSnapshots: (@Sendable () async -> AsyncStream<SettingsSurfaceSnapshot>)? = nil,
        transferHistory: (@Sendable () async -> AsyncStream<[TransferSurfaceItem]>)? = nil
    ) {
        self.deviceDirectory = deviceDirectory
        self.transferCoordinator = transferCoordinator
        self.pairingSurfaceService = pairingSurfaceService
        self.settingsSurfaceService = settingsSurfaceService
        self.directorySelector = directorySelector
        self.transferSnapshots = transferSnapshots
        self.pairingStates = pairingStates
        self.settingsSnapshots = settingsSnapshots
        self.transferHistory = transferHistory
    }

    static func localShell() -> AppContainer {
        AppContainer(
            deviceDirectory: DeviceDirectory(trust: DeviceTrust(trustedIDs: [])),
            transferCoordinator: UnavailableTransferCoordinator()
        )
    }

    static func loadingShell() -> AppContainer {
        AppContainer(
            deviceDirectory: DeviceDirectory(trust: DeviceTrust(trustedIDs: [])),
            transferCoordinator: UnavailableTransferCoordinator()
        )
    }
}

enum AppContainerError: Error {
    case transferServicesUnavailable
}

actor UnavailableTransferCoordinator: TransferCoordinating {
    func send(items: [URL], to device: DeviceID) async throws -> TransferID {
        throw AppContainerError.transferServicesUnavailable
    }

    func pause(_ id: TransferID) async {}

    func resume(_ id: TransferID) async throws {
        throw AppContainerError.transferServicesUnavailable
    }

    func cancel(_ id: TransferID) async -> TransferCancellationResult {
        .tooLate
    }
}
