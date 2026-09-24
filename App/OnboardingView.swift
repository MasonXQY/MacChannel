import AppKit
import Combine
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
    static var items: [OnboardingItem] { [
        OnboardingItem(
            concept: .menuBarLocation,
            symbol: "menubar.rectangle",
            text: L10n.text(.onboardingMenuBar)
        ),
        OnboardingItem(
            concept: .defaultReceiveDestination,
            symbol: "folder",
            text: L10n.text(.onboardingDestination)
        ),
        OnboardingItem(
            concept: .justInTimePermissions,
            symbol: "hand.raised",
            text: L10n.text(.onboardingPermissions)
        ),
        OnboardingItem(
            concept: .pairingApproval,
            symbol: "number",
            text: L10n.text(.onboardingPairing)
        ),
        OnboardingItem(
            concept: .distributionRepairing,
            symbol: "arrow.triangle.2.circlepath",
            text: L10n.text(.onboardingChannelSwitch)
        ),
    ] }
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
    @EnvironmentObject private var localization: LocalizationController
    let onOpenSettings: () -> Void
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(.onboardingWelcome))
                .font(.title2.weight(.semibold))
            Text(L10n.text(.onboardingTagline))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(OnboardingContent.items) { item in
                    Label(item.text, systemImage: item.symbol)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(item.text)
                }
            }

            HStack {
                Button(L10n.text(.commonOpenSettings), action: onOpenSettings)
                    .accessibilityHint(L10n.text(.onboardingSettingsHint))
                Spacer()
                Button(L10n.text(.commonDone), action: onComplete)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(L10n.text(.onboardingCloseHint))
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let completionStore: OnboardingCompletionStore
    private var languageSubscription: AnyCancellable?

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
        window.title = L10n.text(.onboardingWelcome)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: OnboardingView(
            onOpenSettings: onOpenSettings,
            onComplete: { [weak self] in self?.complete() }
        ).environmentObject(LocalizationController.shared))
        languageSubscription = LocalizationController.shared.$language.dropFirst().sink { [weak window] _ in
            window?.title = L10n.text(.onboardingWelcome)
        }
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
