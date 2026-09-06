import AppKit
import SwiftUI

enum OnboardingConcept: CaseIterable, Equatable {
    case menuBarLocation
    case defaultReceiveDestination
    case justInTimePermissions
    case pairingApproval
    case distributionRepairing
}

struct OnboardingItem: Equatable, Identifiable {
    let concept: OnboardingConcept
    let symbol: String
    let text: String

    var id: OnboardingConcept { concept }
}

enum OnboardingContent {
    static let items: [OnboardingItem] = [
        OnboardingItem(
            concept: .menuBarLocation,
            symbol: "menubar.rectangle",
            text: "DropMesh 位于菜单栏，随时可以发送文件或打开设置。"
        ),
        OnboardingItem(
            concept: .defaultReceiveDestination,
            symbol: "folder",
            text: "收到的文件默认保存到 Downloads/DropMesh。"
        ),
        OnboardingItem(
            concept: .justInTimePermissions,
            symbol: "hand.raised",
            text: "首次使用局域网、通知或自定义目录时，macOS 才会请求相应权限。"
        ),
        OnboardingItem(
            concept: .pairingApproval,
            symbol: "number",
            text: "与另一台 Mac 配对需要六位码，并在另一台 Mac 上允许一次。"
        ),
        OnboardingItem(
            concept: .distributionRepairing,
            symbol: "arrow.triangle.2.circlepath",
            text: "从官网版切换到 Mac App Store 版需要重新配对。"
        ),
    ]
}

@MainActor
final class OnboardingCompletionStore {
    static let key = "appStoreOnboardingCompleted"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isCompleted: Bool { defaults.bool(forKey: Self.key) }

    func complete() {
        defaults.set(true, forKey: Self.key)
    }
}

struct OnboardingView: View {
    let onOpenSettings: () -> Void
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("欢迎使用 DropMesh")
                .font(.title2.weight(.semibold))
            Text("在两台 Mac 之间快速、安全地传送文件。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(OnboardingContent.items) { item in
                    Label(item.text, systemImage: item.symbol)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(item.text)
                }
            }

            HStack {
                Button("打开设置", action: onOpenSettings)
                    .accessibilityHint("打开 DropMesh 设置，不关闭此说明")
                Spacer()
                Button("完成", action: onComplete)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("关闭首次使用说明")
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let completionStore: OnboardingCompletionStore

    init(
        completionStore: OnboardingCompletionStore = OnboardingCompletionStore(),
        onOpenSettings: @escaping () -> Void
    ) {
        self.completionStore = completionStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "欢迎使用 DropMesh"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: OnboardingView(
            onOpenSettings: onOpenSettings,
            onComplete: { [weak self] in self?.complete() }
        ))
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard !completionStore.isCompleted else { return }
        window?.center()
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    private func complete() {
        completionStore.complete()
        close()
    }

    func windowWillClose(_ notification: Notification) {
        completionStore.complete()
    }
}
