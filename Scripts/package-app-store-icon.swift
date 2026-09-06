#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct Representation {
    let filename: String
    let pixels: Int
}

private let representations = [
    Representation(filename: "icon_16x16.png", pixels: 16),
    Representation(filename: "icon_16x16@2x.png", pixels: 32),
    Representation(filename: "icon_128x128.png", pixels: 128),
    Representation(filename: "icon_128x128@2x.png", pixels: 256),
    Representation(filename: "icon_256x256.png", pixels: 256),
    Representation(filename: "icon_256x256@2x.png", pixels: 512),
    Representation(filename: "icon_512x512.png", pixels: 512),
    Representation(filename: "icon_512x512@2x.png", pixels: 1024),
]

private enum PackagingError: LocalizedError {
    case usage
    case invalidSource
    case invalidFormat
    case cannotRender(Int)
    case iconutilFailed(Int32)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .usage: "usage: package-app-store-icon.swift <source-1024.png> <output.icns>"
        case .invalidSource: "source PNG must be a decodable 1024x1024 image"
        case .invalidFormat: "source image format must be PNG"
        case let .cannotRender(pixels): "could not render Store icon at \(pixels)x\(pixels)"
        case let .iconutilFailed(status): "iconutil failed with exit status \(status)"
        case .emptyOutput: "iconutil did not create a non-empty Store icon"
        }
    }
}

private func packageIcon() throws {
    guard CommandLine.arguments.count == 3 else { throw PackagingError.usage }
    let manager = FileManager.default
    let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          (try source.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
    else {
        fputs("package-app-store-icon: source PNG must be a regular file\n", stderr)
        exit(1)
    }
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil)
    else { throw PackagingError.invalidSource }
    guard let sourceType = CGImageSourceGetType(imageSource) as String?
    else { throw PackagingError.invalidSource }
    guard sourceType == UTType.png.identifier
    else { throw PackagingError.invalidFormat }
    guard let image = NSImage(contentsOf: source),
          let sourceRep = image.representations.first,
          sourceRep.pixelsWide == 1024,
          sourceRep.pixelsHigh == 1024
    else { throw PackagingError.invalidSource }

    let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
    try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent("dropmesh-store-icon-\(UUID().uuidString)")
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: temporaryRoot) }
    let iconset = temporaryRoot.appendingPathComponent("DropMesh.iconset")
    try manager.createDirectory(at: iconset, withIntermediateDirectories: false)

    for representation in representations {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: representation.pixels,
            pixelsHigh: representation.pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw PackagingError.cannotRender(representation.pixels) }
        bitmap.size = NSSize(width: representation.pixels, height: representation.pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: representation.pixels, height: representation.pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PackagingError.cannotRender(representation.pixels)
        }
        try png.write(to: iconset.appendingPathComponent(representation.filename), options: .atomic)
    }

    if manager.fileExists(atPath: output.path) { try manager.removeItem(at: output) }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw PackagingError.iconutilFailed(iconutil.terminationStatus) }
    guard (try manager.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
        throw PackagingError.emptyOutput
    }
}

do {
    try packageIcon()
} catch {
    fputs("package-app-store-icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
