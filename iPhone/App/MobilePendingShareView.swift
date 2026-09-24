import SwiftUI

struct MobilePendingShareView: View {
    @Bindable var model: MobilePendingShareModel
    let sender: MobileSendModel
    let showSender: () -> Void

    var body: some View {
        if !model.batches.isEmpty || model.failureKey != nil {
            Section("share.pending.title") {
                if let key = model.failureKey {
                    Text(LocalizedStringKey(key)).foregroundStyle(.secondary)
                    Button("action.retry") { Task { await model.refresh() } }
                }
                if !model.batches.isEmpty {
                    Text("share.pending.explanation").foregroundStyle(.secondary)
                    ForEach(model.batches, id: \.self) { id in
                        Button("share.pending.prepare") {
                            Task { if await model.prepare(id, using: sender) { showSender() } }
                        }
                        .disabled(model.busy || !sender.canSelect)
                        .accessibilityIdentifier("share-prepare-button")
                    }
                    if !sender.canSelect { Text("share.pending.busy").foregroundStyle(.secondary) }
                }
            }
        }
    }
}
