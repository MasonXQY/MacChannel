#!/usr/bin/env swift

import AppKit
import Foundation

private enum DropMeshIcon {
    static let graphite = NSColor(
        deviceRed: 0x1D / 255,
        green: 0x1F / 255,
        blue: 0x23 / 255,
        alpha: 1
    )
    static let warmWhite = NSColor(
        deviceRed: 0xF5 / 255,
        green: 0xF2 / 255,
        blue: 0xEA / 255,
        alpha: 1
    )
    static let green = NSColor(
        deviceRed: 0x45 / 255,
        green: 0xE0 / 255,
        blue: 0x7C / 255,
        alpha: 1
    )

    static let representations: [(filename: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    static func render(pixels: Int, to destination: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw IconError.cannotCreateBitmap(pixels)
        }

        bitmap.size = NSSize(width: pixels, height: pixels)
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw IconError.cannotCreateGraphicsContext(pixels)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()

        let size = CGFloat(pixels)
        let backgroundInset = size * 0.07
        let backgroundRect = NSRect(
            x: backgroundInset,
            y: backgroundInset,
            width: size - (2 * backgroundInset),
            height: size - (2 * backgroundInset)
        )
        graphite.setFill()
        NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: size * 0.22,
            yRadius: size * 0.22
        ).fill()

        let connectionY = size * 0.48
        let leftEndpoint = NSPoint(x: size * 0.24, y: connectionY)
        let rightEndpoint = NSPoint(x: size * 0.76, y: connectionY)
        let connection = NSBezierPath()
        connection.move(to: leftEndpoint)
        connection.curve(
            to: rightEndpoint,
            controlPoint1: NSPoint(x: size * 0.39, y: size * 0.36),
            controlPoint2: NSPoint(x: size * 0.61, y: size * 0.60)
        )
        connection.lineWidth = max(1.5, size * 0.055)
        connection.lineCapStyle = .round
        green.setStroke()
        connection.stroke()

        let endpointDiameter = max(2.25, size * 0.13)
        green.setFill()
        for endpoint in [leftEndpoint, rightEndpoint] {
            NSBezierPath(
                ovalIn: NSRect(
                    x: endpoint.x - endpointDiameter / 2,
                    y: endpoint.y - endpointDiameter / 2,
                    width: endpointDiameter,
                    height: endpointDiameter
                )
            ).fill()
        }

        let fileLeft = size * 0.33
        let fileRight = size * 0.67
        let fileBottom = size * 0.23
        let fileTop = size * 0.77
        let foldSize = max(2, size * 0.12)
        let file = NSBezierPath()
        file.move(to: NSPoint(x: fileLeft, y: fileBottom))
        file.line(to: NSPoint(x: fileRight, y: fileBottom))
        file.line(to: NSPoint(x: fileRight, y: fileTop - foldSize))
        file.line(to: NSPoint(x: fileRight - foldSize, y: fileTop))
        file.line(to: NSPoint(x: fileLeft, y: fileTop))
        file.close()
        warmWhite.setFill()
        file.fill()

        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: fileRight - foldSize, y: fileTop))
        fold.line(to: NSPoint(x: fileRight - foldSize, y: fileTop - foldSize))
        fold.line(to: NSPoint(x: fileRight, y: fileTop - foldSize))
        fold.lineWidth = max(1, size * 0.027)
        fold.lineJoinStyle = .round
        graphite.withAlphaComponent(0.65).setStroke()
        fold.stroke()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw IconError.cannotEncodePNG(pixels)
        }
        try png.write(to: destination, options: .atomic)
    }
}

private enum IconError: LocalizedError {
    case usage
    case cannotCreateBitmap(Int)
    case cannotCreateGraphicsContext(Int)
    case cannotEncodePNG(Int)
    case iconutilFailed(Int32)
    case emptyOutput(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: generate-dropmesh-icon.swift <output.icns>"
        case let .cannotCreateBitmap(pixels):
            return "could not create a \(pixels)px bitmap"
        case let .cannotCreateGraphicsContext(pixels):
            return "could not create a \(pixels)px graphics context"
        case let .cannotEncodePNG(pixels):
            return "could not encode the \(pixels)px PNG"
        case let .iconutilFailed(status):
            return "iconutil failed with exit status \(status)"
        case let .emptyOutput(path):
            return "iconutil did not create a non-empty icon at \(path)"
        }
    }
}

func generateIcon() throws {
    guard CommandLine.arguments.count == 2 else {
        throw IconError.usage
    }

    let fileManager = FileManager.default
    let output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    try fileManager.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("dropmesh-icon-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
        at: temporaryRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let iconset = temporaryRoot.appendingPathComponent("DropMesh.iconset", isDirectory: true)
    try fileManager.createDirectory(
        at: iconset,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    for representation in DropMeshIcon.representations {
        try DropMeshIcon.render(
            pixels: representation.pixels,
            to: iconset.appendingPathComponent(representation.filename)
        )
    }

    if fileManager.fileExists(atPath: output.path) {
        try fileManager.removeItem(at: output)
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw IconError.iconutilFailed(iconutil.terminationStatus)
    }

    let attributes = try fileManager.attributesOfItem(atPath: output.path)
    guard let fileSize = attributes[.size] as? NSNumber, fileSize.intValue > 0 else {
        throw IconError.emptyOutput(output.path)
    }
}

do {
    try generateIcon()
} catch {
    fputs("generate-dropmesh-icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
