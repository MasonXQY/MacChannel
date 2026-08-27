import CryptoKit
import Darwin
import Foundation

/// A lightweight reference to immutable, restart-safe outbound input. The
/// package owns APFS copy-on-write clones but never retains open descriptors;
/// descriptors are opened only after a transport connection succeeds.
struct OutgoingTransferPackage: Sendable {
    struct Metadata: Codable, Equatable, Sendable {
        let version: Int
        let transferID: String
        let peerID: String
        let displayFilename: String
        let rootRelativePath: String
        let totalBytes: Int64
        let manifestFingerprint: String
        let createdAt: Date
    }

    static let containerDisplayName = "MacChannel Transfer"

    let directory: URL
    let metadata: Metadata

    var id: TransferID {
        TransferID(rawValue: UUID(uuidString: metadata.transferID)!)
    }

    var peer: DeviceID {
        DeviceID(rawValue: UUID(uuidString: metadata.peerID)!)
    }

    var displayFilename: String { metadata.displayFilename }
    var totalBytes: Int64 { metadata.totalBytes }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacChannel/Outgoing", isDirectory: true)
    }

    static func create(
        items: [URL],
        peer: DeviceID,
        in outgoingDirectory: URL,
        id: TransferID = TransferID(rawValue: UUID()),
        now: Date = Date(),
        afterRename: (() throws -> Void)? = nil
    ) throws -> OutgoingTransferPackage {
        guard !items.isEmpty else {
            throw MacChannelError.invalidConfiguration(
                "Select at least one file or folder to transfer."
            )
        }
        let outgoing = outgoingDirectory.standardizedFileURL
        try preparePrivateDirectory(outgoing)
        let authenticationKey = try authenticationKey(in: outgoing)
        let caseSensitive = try destinationVolumeSupportsCaseSensitiveNames(outgoing)
        let normalizedItems = items.map { $0.standardizedFileURL }
        var selectedNames: Set<String> = []
        for item in normalizedItems {
            guard !pathsOverlap(item, outgoing) else {
                throw TransferProtocolError.unsupportedSource
            }
            let normalizedName = item.lastPathComponent.precomposedStringWithCanonicalMapping
            guard !normalizedName.isEmpty else { throw TransferProtocolError.unsupportedSource }
            let key = destinationFilesystemKey([normalizedName], caseSensitive: caseSensitive)
            guard selectedNames.insert(key).inserted else {
                throw TransferProtocolError.destinationPathCollision
            }
        }

        let identifier = id.rawValue.uuidString.lowercased()
        let finalDirectory = outgoing.appendingPathComponent(identifier, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: finalDirectory.path) else {
            throw TransferProtocolError.destinationExists
        }
        let temporary = outgoing.appendingPathComponent(
            ".\(identifier).creating.\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard Darwin.mkdir(temporary.path, S_IRWXU) == 0 else {
            throw TransferProtocolError.unsupportedSource
        }
        var renamed = false
        do {
            let payload = temporary.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
            guard chmod(payload.path, S_IRWXU) == 0 else {
                throw TransferProtocolError.unsupportedSource
            }
            let root: URL
            let displayFilename: String
            if normalizedItems.count == 1, let item = normalizedItems.first {
                displayFilename = item.lastPathComponent.precomposedStringWithCanonicalMapping
                root = payload.appendingPathComponent(displayFilename, isDirectory: true)
                var count = 0
                try cloneSelectedRoot(from: item, to: root, entryCount: &count)
            } else {
                displayFilename = containerDisplayName
                root = payload.appendingPathComponent(displayFilename, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                var count = 1
                for item in normalizedItems.sorted(by: stableItemOrder) {
                    let name = item.lastPathComponent.precomposedStringWithCanonicalMapping
                    try cloneSelectedRoot(
                        from: item,
                        to: root.appendingPathComponent(name),
                        entryCount: &count
                    )
                }
                guard chmod(root.path, S_IRUSR | S_IXUSR) == 0 else {
                    throw TransferProtocolError.unsupportedSource
                }
            }
            guard chmod(payload.path, S_IRUSR | S_IXUSR) == 0 else {
                throw TransferProtocolError.unsupportedSource
            }

            let manifest = try TransferManifest.build(
                from: root,
                transferID: id,
                immutablePackageSource: true
            )
            let totalBytes = try aggregateBytes(manifest)
            let fingerprint = try manifestFingerprint(manifest)
            let relativeRoot = "payload/\(displayFilename)"
            let metadata = Metadata(
                version: 2,
                transferID: identifier,
                peerID: peer.rawValue.uuidString.lowercased(),
                displayFilename: displayFilename,
                rootRelativePath: relativeRoot,
                totalBytes: totalBytes,
                manifestFingerprint: fingerprint.base64EncodedString(),
                createdAt: now
            )
            let encoded = try encodedMetadata(metadata)
            let metadataURL = temporary.appendingPathComponent("metadata.json")
            let authenticationURL = temporary.appendingPathComponent("metadata.hmac")
            try encoded.write(to: metadataURL, options: .withoutOverwriting)
            try Data(
                HMAC<SHA256>.authenticationCode(
                    for: encoded,
                    using: authenticationKey
                )
            ).write(
                to: authenticationURL,
                options: .withoutOverwriting
            )
            guard chmod(metadataURL.path, S_IRUSR) == 0,
                chmod(authenticationURL.path, S_IRUSR) == 0
            else { throw TransferProtocolError.unsupportedSource }
            // The immutable package must reach stable storage before its
            // preparing row can be committed by TransferCoordinator.
            try synchronizeTree(temporary)
            let temporaryPackage = OutgoingTransferPackage(
                directory: temporary,
                metadata: metadata
            )
            _ = try temporaryPackage.openManifest()
            try FileManager.default.moveItem(at: temporary, to: finalDirectory)
            renamed = true
            try afterRename?()
            try synchronize(outgoing, isDirectory: true)
            return OutgoingTransferPackage(directory: finalDirectory, metadata: metadata)
        } catch {
            let cleanup = renamed ? finalDirectory : temporary
            try? makeTreeRemovable(cleanup)
            try? FileManager.default.removeItem(at: cleanup)
            if renamed { try? synchronize(outgoing, isDirectory: true) }
            throw error
        }
    }

    static func loadAll(from outgoingDirectory: URL) throws -> [OutgoingTransferPackage] {
        let outgoing = outgoingDirectory.standardizedFileURL
        try preparePrivateDirectory(outgoing)
        try reclaimAuthenticationKeyTemps(in: outgoing)
        let children = try FileManager.default.contentsOfDirectory(
            at: outgoing,
            includingPropertiesForKeys: nil,
            options: []
        )
        var packages: [URL] = []
        var removedTemporary = false
        for child in children {
            if isCreatingDirectoryName(child.lastPathComponent) {
                try validateReclaimablePrivateDirectory(child)
                try makeTreeRemovable(child)
                try FileManager.default.removeItem(at: child)
                removedTemporary = true
            } else if !child.lastPathComponent.hasPrefix(".") {
                packages.append(child)
            }
        }
        if removedTemporary { try synchronize(outgoing, isDirectory: true) }
        return try packages.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(load)
    }

    static func load(_ directory: URL) throws -> OutgoingTransferPackage {
        let packageDirectory = directory.standardizedFileURL
        try validatePrivateDirectory(packageDirectory, exactMode: S_IRWXU)
        let metadataURL = packageDirectory.appendingPathComponent("metadata.json")
        let authenticationURL = packageDirectory.appendingPathComponent("metadata.hmac")
        let encoded = try Data(contentsOf: metadataURL, options: .mappedIfSafe)
        let storedAuthentication = try Data(
            contentsOf: authenticationURL,
            options: .mappedIfSafe
        )
        let key = try authenticationKey(in: packageDirectory.deletingLastPathComponent())
        guard HMAC<SHA256>.isValidAuthenticationCode(
            storedAuthentication,
            authenticating: encoded,
            using: key
        ) else {
            throw TransferProtocolError.sourceChanged
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let metadata = try decoder.decode(Metadata.self, from: encoded)
        guard metadata.version == 2,
            let transferUUID = UUID(uuidString: metadata.transferID),
            let peerUUID = UUID(uuidString: metadata.peerID),
            metadata.transferID == transferUUID.uuidString.lowercased(),
            metadata.peerID == peerUUID.uuidString.lowercased(),
            metadata.totalBytes >= 0,
            Data(base64Encoded: metadata.manifestFingerprint)?.count == 32,
            metadata.rootRelativePath == "payload/\(metadata.displayFilename)",
            packageDirectory.lastPathComponent == metadata.transferID
        else { throw TransferProtocolError.sourceChanged }
        let package = OutgoingTransferPackage(directory: packageDirectory, metadata: metadata)
        _ = try package.openManifest()
        return package
    }

    func openManifest() throws -> TransferManifest {
        let root = try rootURL()
        let manifest = try TransferManifest.build(
            from: root,
            transferID: id,
            immutablePackageSource: true
        )
        guard try manifestFingerprint(manifest).base64EncodedString()
            == metadata.manifestFingerprint,
            try Self.aggregateBytes(manifest) == metadata.totalBytes
        else { throw TransferProtocolError.sourceChanged }
        return manifest
    }

    func remove() throws {
        let outgoing = directory.deletingLastPathComponent()
        var status = stat()
        if lstat(directory.path, &status) == 0 {
            try Self.makeTreeRemovable(directory)
            try FileManager.default.removeItem(at: directory)
        } else if errno != ENOENT {
            throw TransferProtocolError.unsupportedSource
        }
        try Self.synchronize(outgoing, isDirectory: true)
    }

    private func rootURL() throws -> URL {
        let root = directory.appendingPathComponent(metadata.rootRelativePath).standardizedFileURL
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard root.path.hasPrefix(prefix) else { throw TransferProtocolError.sourceChanged }
        return root
    }

    private static func stableItemOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.precomposedStringWithCanonicalMapping
            < rhs.lastPathComponent.precomposedStringWithCanonicalMapping
    }

    private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.pathComponents
        let right = rhs.pathComponents
        let shared = min(left.count, right.count)
        return Array(left.prefix(shared)) == Array(right.prefix(shared))
    }

    private static func cloneSelectedRoot(
        from source: URL,
        to destination: URL,
        entryCount: inout Int
    ) throws {
        let sourceManifest = try TransferManifest.build(from: source)
        guard entryCount
            <= TransferProtocolLimits.maximumManifestEntries - sourceManifest.entries.count
        else {
            throw TransferProtocolError.manifestTooLarge
        }
        entryCount += sourceManifest.entries.count
        guard let sourceRoot = sourceManifest.entries.first?.relativePath.components.first else {
            throw TransferProtocolError.unsupportedSource
        }
        var directories: [(URL, Date)] = []
        for entry in sourceManifest.entries {
            guard entry.relativePath.components.first == sourceRoot else {
                throw TransferProtocolError.sourceChanged
            }
            let suffix = entry.relativePath.components.dropFirst()
            let target = suffix.reduce(destination) { partial, component in
                partial.appendingPathComponent(component)
            }
            switch entry.kind {
            case .directory:
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: false
                )
                guard chmod(target.path, S_IRWXU) == 0 else {
                    throw TransferProtocolError.unsupportedSource
                }
                directories.append((target, entry.modificationDate))
            case .file:
                guard let pinnedSource = entry.pinnedSource else {
                    throw TransferProtocolError.sourceChanged
                }
                try pinnedSource.clonePersistently(to: target)
                try FileManager.default.setAttributes(
                    [.modificationDate: entry.modificationDate],
                    ofItemAtPath: target.path
                )
            }
        }
        for (directory, modificationDate) in directories.reversed() {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: directory.path
            )
            guard chmod(directory.path, S_IRUSR | S_IXUSR) == 0 else {
                throw TransferProtocolError.unsupportedSource
            }
        }
    }

    private static func aggregateBytes(_ manifest: TransferManifest) throws -> Int64 {
        var total: UInt64 = 0
        for entry in manifest.entries {
            guard entry.size <= UInt64(Int64.max),
                total <= UInt64(Int64.max) - entry.size
            else { throw TransferProtocolError.manifestTooLarge }
            total += entry.size
        }
        return Int64(total)
    }

    private static func encodedMetadata(_ metadata: Metadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(metadata)
    }

    private static func authenticationKey(in outgoingDirectory: URL) throws -> SymmetricKey {
        let keyURL = outgoingDirectory.appendingPathComponent(".package-authentication-key")
        try reclaimAuthenticationKeyTemps(in: outgoingDirectory)
        if !FileManager.default.fileExists(atPath: keyURL.path) {
            let generated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let directoryDescriptor = Darwin.open(
                outgoingDirectory.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard directoryDescriptor >= 0 else {
                throw TransferProtocolError.unsupportedSource
            }
            defer { Darwin.close(directoryDescriptor) }
            let temporaryName =
                ".package-authentication-key.creating.\(UUID().uuidString.lowercased())"
            let descriptor = Darwin.openat(
                directoryDescriptor,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { throw TransferProtocolError.unsupportedSource }
            var published = false
            defer {
                Darwin.close(descriptor)
                if !published { _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0) }
            }
            let wrote = generated.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return false }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count <= 0 { return false }
                    offset += count
                }
                return true
            }
            guard wrote,
                fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                fcntl(descriptor, F_FULLFSYNC) == 0 || Darwin.fsync(descriptor) == 0
            else { throw TransferProtocolError.unsupportedSource }
            let renameResult = Darwin.renameatx_np(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                ".package-authentication-key",
                UInt32(RENAME_EXCL)
            )
            if renameResult == 0 {
                published = true
                try synchronize(outgoingDirectory, isDirectory: true)
            } else if errno == EEXIST {
                // A concurrent atomic publisher won. The deferred unlink removes
                // only our exact private temporary file.
            } else {
                throw TransferProtocolError.unsupportedSource
            }
        }
        var before = stat()
        guard lstat(keyURL.path, &before) == 0,
            before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == geteuid(),
            before.st_nlink == 1,
            before.st_mode & 0o777 == (S_IRUSR | S_IWUSR),
            before.st_size == 32
        else { throw TransferProtocolError.sourceChanged }
        let descriptor = Darwin.open(keyURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw TransferProtocolError.sourceChanged }
        defer { Darwin.close(descriptor) }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            after.st_dev == before.st_dev,
            after.st_ino == before.st_ino,
            after.st_uid == before.st_uid,
            after.st_nlink == 1,
            after.st_size == 32,
            after.st_mode & 0o777 == (S_IRUSR | S_IWUSR)
        else { throw TransferProtocolError.sourceChanged }
        var bytes = Data(count: 32)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard readCount == 32 else { throw TransferProtocolError.sourceChanged }
        return SymmetricKey(data: bytes)
    }

    private static func preparePrivateDirectory(_ directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try synchronize(parent, isDirectory: true)
        let grandparent = parent.deletingLastPathComponent()
        if grandparent.path != parent.path {
            try synchronize(grandparent, isDirectory: true)
        }
        var status = stat()
        var created = false
        if lstat(directory.path, &status) != 0 {
            guard errno == ENOENT, Darwin.mkdir(directory.path, S_IRWXU) == 0 else {
                throw TransferProtocolError.unsupportedSource
            }
            created = true
        }
        try validatePrivateDirectory(directory, exactMode: S_IRWXU)
        if created {
            try synchronize(directory, isDirectory: true)
            try synchronize(parent, isDirectory: true)
        }
    }

    private static func validatePrivateDirectory(_ directory: URL, exactMode: mode_t) throws {
        var status = stat()
        guard lstat(directory.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == geteuid(),
            status.st_nlink >= 2,
            status.st_mode & 0o777 == exactMode
        else { throw TransferProtocolError.unsupportedSource }
    }

    private static func validateReclaimablePrivateDirectory(_ directory: URL) throws {
        var status = stat()
        guard lstat(directory.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == geteuid(),
            status.st_nlink >= 2,
            status.st_mode & 0o077 == 0,
            status.st_mode & 0o7000 == 0
        else { throw TransferProtocolError.unsupportedSource }
    }

    private static func makeTreeRemovable(_ root: URL) throws {
        var status = stat()
        guard lstat(root.path, &status) == 0 else {
            if errno == ENOENT { return }
            throw TransferProtocolError.unsupportedSource
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { return }
        guard chmod(root.path, S_IRWXU) == 0 else {
            throw TransferProtocolError.unsupportedSource
        }
        for child in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            try makeTreeRemovable(child)
        }
    }

    private static func isCreatingDirectoryName(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: true)
        guard name.hasPrefix("."), components.count == 3, components[1] == "creating"
        else { return false }
        return UUID(uuidString: String(components[0])) != nil
            && UUID(uuidString: String(components[2])) != nil
    }

    private static func reclaimAuthenticationKeyTemps(in outgoing: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: outgoing,
            includingPropertiesForKeys: nil,
            options: []
        )
        let temporaryKeys = children.filter {
            isAuthenticationKeyTemporaryName($0.lastPathComponent)
        }
        guard !temporaryKeys.isEmpty else { return }
        let finalKey = outgoing.appendingPathComponent(".package-authentication-key")
        var finalStatus = stat()
        let finalKeyExists = lstat(finalKey.path, &finalStatus) == 0
        let eligiblePackagesExist = children.contains {
            !$0.lastPathComponent.hasPrefix(".")
        }
        guard finalKeyExists || !eligiblePackagesExist else {
            throw TransferProtocolError.sourceChanged
        }
        for temporary in temporaryKeys {
            var status = stat()
            guard lstat(temporary.path, &status) == 0,
                status.st_mode & S_IFMT == S_IFREG,
                status.st_uid == geteuid(),
                status.st_mode & 0o077 == 0,
                status.st_mode & 0o111 == 0,
                status.st_mode & 0o7000 == 0
            else { throw TransferProtocolError.sourceChanged }
            if status.st_nlink != 1 {
                // Versions that used linkat could crash after publishing the
                // final name but before removing the private temporary link.
                // Reclaim only that exact same-inode two-link state.
                guard status.st_nlink == 2,
                    finalKeyExists,
                    finalStatus.st_mode & S_IFMT == S_IFREG,
                    finalStatus.st_uid == geteuid(),
                    finalStatus.st_nlink == 2,
                    finalStatus.st_mode & 0o777 == (S_IRUSR | S_IWUSR),
                    finalStatus.st_size == 32,
                    finalStatus.st_dev == status.st_dev,
                    finalStatus.st_ino == status.st_ino
                else { throw TransferProtocolError.sourceChanged }
            }
            try FileManager.default.removeItem(at: temporary)
        }
        try synchronize(outgoing, isDirectory: true)
    }

    private static func isAuthenticationKeyTemporaryName(_ name: String) -> Bool {
        let prefix = ".package-authentication-key.creating."
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private static func synchronizeTree(_ root: URL) throws {
        var status = stat()
        guard lstat(root.path, &status) == 0 else {
            throw TransferProtocolError.unsupportedSource
        }
        if status.st_mode & S_IFMT == S_IFDIR {
            for child in try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                try synchronizeTree(child)
            }
            try synchronize(root, isDirectory: true)
        } else if status.st_mode & S_IFMT == S_IFREG {
            try synchronize(root, isDirectory: false)
        } else {
            throw TransferProtocolError.unsupportedSource
        }
    }

    private static func synchronize(_ url: URL, isDirectory: Bool) throws {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isDirectory ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else { throw TransferProtocolError.unsupportedSource }
        defer { Darwin.close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, Darwin.fsync(descriptor) != 0 {
            throw TransferProtocolError.unsupportedSource
        }
    }
}
