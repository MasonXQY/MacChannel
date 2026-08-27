import Darwin
import Foundation
import MacChannelCore

actor RuntimeOutputLocator {
    private let url: URL
    private var paths: [UUID: String]

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            paths = try JSONDecoder().decode(
                [UUID: String].self,
                from: Data(contentsOf: url)
            )
        } else {
            paths = [:]
        }
    }

    func record(_ result: TransferReceiveResult) throws {
        guard let output = result.receivedURLs.first?.standardizedFileURL,
              output.isFileURL,
              output.path.hasPrefix("/")
        else { return }
        var candidate = paths
        candidate[result.transferID.rawValue] = output.path
        try persist(candidate)
        paths = candidate
    }

    func outputURL(for transfer: TransferID) -> URL? {
        paths[transfer.rawValue].map(URL.init(fileURLWithPath:))
    }

    func retain(_ transferIDs: Set<TransferID>) throws {
        let retained = Set(transferIDs.map(\.rawValue))
        let candidate = paths.filter { retained.contains($0.key) }
        guard candidate.count != paths.count else { return }
        try persist(candidate)
        paths = candidate
    }

    private func persist(_ candidate: [UUID: String]) throws {
        let data = try JSONEncoder().encode(candidate)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw RuntimeOutputLocatorError.persistence
        }
    }
}

private enum RuntimeOutputLocatorError: Error {
    case persistence
}
