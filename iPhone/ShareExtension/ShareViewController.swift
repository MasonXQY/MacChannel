import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor final class ShareViewController: UIViewController {
    private let model = ShareExtensionModel()
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareExtensionView(model: model,
            finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            cancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }))
        addChild(host); view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty, providers.count <= ShareBatchStore.maximumItems,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.data.identifier) })
        else { model.reject(); return }
        let starts: [ShareImportService.Start] = providers.map { provider in
            { completion in provider.loadTransferable(type: ShareReceivedFile.self, completionHandler: completion) }
        }
        model.save(starts)
    }
}
