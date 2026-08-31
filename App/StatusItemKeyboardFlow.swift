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
        panel.message = "选择要发送的文件或文件夹。"
        panel.prompt = "选择"
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
        let menu = NSMenu(title: "选择接收设备")
        let heading = NSMenuItem(title: "选择接收设备", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        heading.setAccessibilityLabel("选择接收设备")
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
                "发送到\(displayName)，\(availabilityLabel(device.availability))"
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
        case .lan: "局域网在线"
        case .internet: "互联网在线"
        case .offline: "离线"
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
