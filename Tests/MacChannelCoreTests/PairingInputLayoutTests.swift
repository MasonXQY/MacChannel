import AppKit
import SwiftUI
import XCTest
@testable import MacChannelAppKit
@testable import MacChannelCore

final class PairingInputLayoutTests: XCTestCase {
    @MainActor
    func testPairingInputFitsPlaceholderAndDigitsInBothLanguages() async throws {
        _ = NSApplication.shared
        let suite = "pairing-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            L10n.select(.system)
        }
        let localization = LocalizationController(defaults: defaults)
        for language in [AppLanguage.english, .simplifiedChinese] {
            localization.setLanguage(language)
            for code in ["", "123456"] {
                let model = PairingSurfaceModel(entryCode: code)
                let host = NSHostingView(rootView: PairingView(
                    model: model, service: LayoutPairingService(), onDismiss: {}
                ).environmentObject(localization).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 280),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: 420, height: 280)
                host.appearance = NSAppearance(named: .aqua)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let field = try XCTUnwrap(textFields(in: host).first { $0.isEditable })
                let font = try XCTUnwrap(field.font)
                let cell = try XCTUnwrap(field.cell)
                let textRect = cell.drawingRect(forBounds: field.bounds)
                // Use AppKit's own text-cell measurement, not rounded font
                // leading (which can differ from its native layout by a pixel).
                let reference = NSTextField(labelWithString: code.isEmpty ? L10n.text(.pairingSixDigitCode) : code)
                reference.font = font
                let lineHeight = reference.cell!.cellSize.height
                XCTAssertGreaterThanOrEqual(textRect.height, lineHeight,
                    "\(language) \(code): native text area must fit the full font line")
                XCTAssertEqual(field.stringValue, code)
                if code.isEmpty {
                    XCTAssertLessThanOrEqual(reference.cell!.cellSize.width, textRect.width,
                        "Localized placeholder must fit without truncation")
                }
                if let path = ProcessInfo.processInfo.environment["DROPMESH_PAIRING_RENDER_DIR"] {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                        to: directory.appendingPathComponent("pairing-\(language.localeIdentifier())-\(code.isEmpty ? "empty" : "digits").png"))
                }
                window.close()
            }
        }
    }

    @MainActor
    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }
}

@MainActor
private final class LayoutPairingService: PairingSurfaceServicing {
    var isAvailable: Bool { true }
    func createCode() async throws -> String { "123456" }
    func join(code: String) async throws -> PairingJoinResult { throw CocoaError(.featureUnsupported) }
    func cancel() async throws {}
}
