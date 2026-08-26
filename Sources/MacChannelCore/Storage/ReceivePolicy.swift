import Foundation

public struct DeviceReceivePolicy: Equatable, Sendable {
    public let autoAccept: Bool
    public let maximumBytes: UInt64?

    public init(autoAccept: Bool = true, maximumBytes: UInt64? = nil) {
        self.autoAccept = autoAccept
        self.maximumBytes = maximumBytes
    }
}

public struct ReceivePolicy: Sendable {
    private let trustedSources: Set<DeviceID>
    private let defaultAutoAccept: Bool
    private let defaultMaximumBytes: UInt64?
    private let perDevice: [DeviceID: DeviceReceivePolicy]

    public init(
        trustedSources: Set<DeviceID>,
        defaultAutoAccept: Bool = true,
        defaultMaximumBytes: UInt64? = nil,
        perDevice: [DeviceID: DeviceReceivePolicy] = [:]
    ) {
        self.trustedSources = trustedSources
        self.defaultAutoAccept = defaultAutoAccept
        self.defaultMaximumBytes = defaultMaximumBytes
        self.perDevice = perDevice
    }

    func authorize(source: DeviceID, aggregateBytes: UInt64) throws {
        guard trustedSources.contains(source) else { throw ReceiveStoreError.untrustedSource }
        let device = perDevice[source]
        guard device?.autoAccept ?? defaultAutoAccept else {
            throw ReceiveStoreError.automaticReceiveDisabled
        }
        if let maximum = device?.maximumBytes ?? defaultMaximumBytes,
            aggregateBytes > maximum
        {
            throw ReceiveStoreError.exceedsMaximumSize(
                limit: maximum,
                actual: aggregateBytes
            )
        }
    }
}
