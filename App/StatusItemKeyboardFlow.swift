import AppKit
import MacChannelCore

@MainActor
protocol StatusItemFilePicking: AnyObject {
    func chooseFiles() -> [URL]?
}

@MainActor
protocol StatusItemDeviceMenuPresenting: AnyObject {
    func present(
        devices: [DeviceSummary],
        anchor: NSView,
        select: @escaping (DeviceID) -> Bool,
        cancel: @escaping () -> Void
    )
}

@MainActor
final class NativeStatusItemFilePicker: StatusItemFilePicking {
    func chooseFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.message = L10n.text(.sendFilePickerMessage)
        panel.prompt = L10n.text(.commonChoose)
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

@MainActor
final class NativeStatusItemDeviceMenuPresenter: StatusItemDeviceMenuPresenting {
    func present(
        devices: [DeviceSummary],
        anchor: NSView,
        select: @escaping (DeviceID) -> Bool,
        cancel: @escaping () -> Void
    ) {
        let menu = NSMenu(title: L10n.text(.sendChooseDevice))
        let heading = NSMenuItem(title: L10n.text(.sendChooseDevice), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        heading.setAccessibilityLabel(L10n.text(.sendChooseDevice))
        menu.addItem(heading)
        menu.addItem(.separator())

        var admitted = false
        var actionTargets: [DeviceMenuActionTarget] = []
        for device in devices {
            let displayName = device.userFacingDisplayName
            let target = DeviceMenuActionTarget {
                admitted = select(device.id)
            }
            actionTargets.append(target)

            let item = NSMenuItem(
                title: displayName,
                action: #selector(DeviceMenuActionTarget.choose(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.setAccessibilityLabel(
                L10n.text(.sendDeviceAccessibility, String(displayName), String(availabilityLabel(device.availability)))
            )
            menu.addItem(item)
        }

        _ = withExtendedLifetime(actionTargets) {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: anchor.bounds.maxY + 2),
                in: anchor
            )
        }
        if !admitted {
            cancel()
        }
    }

    private func availabilityLabel(_ availability: DeviceAvailability) -> String {
        switch availability {
        case .lan: L10n.text(.deviceLan)
        case .internet: L10n.text(.deviceInternet)
        case .offline: L10n.text(.deviceOffline)
        }
    }
}

@MainActor
private final class DeviceMenuActionTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func choose(_ sender: NSMenuItem) {
        action()
    }
}
