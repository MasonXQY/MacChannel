import Foundation
import MacChannelCore

@MainActor
final class AppContainer {
    let deviceDirectory: DeviceDirectory
    let transferCoordinator: any TransferCoordinating

    init(
        deviceDirectory: DeviceDirectory,
        transferCoordinator: any TransferCoordinating
    ) {
        self.deviceDirectory = deviceDirectory
        self.transferCoordinator = transferCoordinator
    }

    static func localShell() -> AppContainer {
        AppContainer(
            deviceDirectory: DeviceDirectory(trust: DeviceTrust(trustedIDs: [])),
            transferCoordinator: UnavailableTransferCoordinator()
        )
    }
}

private enum AppContainerError: Error {
    case transferServicesUnavailable
}

private actor UnavailableTransferCoordinator: TransferCoordinating {
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
