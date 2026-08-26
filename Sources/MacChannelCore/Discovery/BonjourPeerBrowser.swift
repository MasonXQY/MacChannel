import CryptoKit
import Foundation
import Network

public enum BonjourPeerAdvertiserError: Error, Equatable, Sendable {
    case invalidPort
}

/// Owns the Network.framework listener that publishes the MacChannel Bonjour
/// service. The caller supplies the authenticated connection handler; discovery
/// never accepts or interprets transfer data itself.
public final class BonjourPeerAdvertiser: @unchecked Sendable {
    public let service: NWListener.Service

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.mason.macchannel.bonjour-advertiser")

    public init(
        device: DeviceID,
        port: UInt16,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw BonjourPeerAdvertiserError.invalidPort
        }
        service = BonjourPeerBrowser.service(for: device)
        listener = try NWListener(using: .tcp, on: endpointPort)
        listener.service = service
        listener.newConnectionHandler = onConnection
    }

    public func start() {
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }
}

/// Browses the privacy-limited MacChannel Bonjour service. The service instance
/// and TXT record contain a one-way device identifier hash and a protocol version;
/// no display name or transfer metadata is advertised.
public final class BonjourPeerBrowser: @unchecked Sendable {
    public static let serviceType = "_macchannel._tcp"
    public static let protocolVersion = "1"

    private let directory: DeviceDirectory
    private let trust: DeviceTrust
    private let queue = DispatchQueue(label: "com.mason.macchannel.bonjour-browser")
    private var browser: NWBrowser?

    public init(directory: DeviceDirectory, trust: DeviceTrust) {
        self.directory = directory
        self.trust = trust
    }

    public static func txtRecord(for device: DeviceID) -> [String: String] {
        [
            "id": deviceIDHash(for: device),
            "version": protocolVersion,
        ]
    }

    public static func service(for device: DeviceID) -> NWListener.Service {
        NWListener.Service(
            name: deviceIDHash(for: device),
            type: serviceType,
            txtRecord: NWTXTRecord(txtRecord(for: device))
        )
    }

    public static func deviceIDHash(for device: DeviceID) -> String {
        SHA256.hash(data: Data(device.rawValue.uuidString.lowercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.consume(results)
        }
        browser.stateUpdateHandler = { _ in }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private func consume(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint,
                  type == Self.serviceType,
                  case let .bonjour(record) = result.metadata,
                  record.dictionary["version"] == Self.protocolVersion,
                  let deviceHash = record.dictionary["id"],
                  let device = trust.device(matchingBonjourHash: deviceHash)
            else { continue }

            Task {
                await directory.apply(.bonjour(
                    device,
                    serviceName: name,
                    type: type,
                    domain: domain
                ))
            }
        }
    }
}
