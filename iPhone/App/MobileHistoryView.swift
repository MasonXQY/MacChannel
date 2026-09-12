import MacChannelCore
import SwiftUI

struct MobileHistoryView: View {
    let model: MobileHistoryModel
    var body: some View {
        List {
            MobileHistorySection(model: model, latestOnly: false)
        }
        .navigationTitle("history.title")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }
}

struct MobileHistorySection: View {
    let model: MobileHistoryModel
    let latestOnly: Bool
    private var rows: [MobileHistoryEntry] { latestOnly ? model.latestReceived : model.entries }
    var body: some View {
        Section(latestOnly ? "received.latest" : "history.title") {
            if model.loading { ProgressView("history.loading") }
            if model.loadFailed {
                Text("history.load.error").accessibilityIdentifier("history-load-error")
                Button("action.retry") { Task { await model.refresh() } }
            }
            if model.availabilityWarning {
                Text("history.availability.warning").foregroundStyle(.secondary)
                    .accessibilityIdentifier("history-availability-warning")
            }
            if let message = model.actionMessage {
                Text(message == .unavailable ? "received.unavailable" : "received.unsupported")
                    .accessibilityIdentifier("history-action-message")
                Text("received.location.instructions").foregroundStyle(.secondary)
            }
            if rows.isEmpty && !model.loading && !model.loadFailed {
                Text("history.empty").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in MobileHistoryRow(entry: row, model: model) }
            if latestOnly {
                NavigationLink { MobileHistoryView(model: model) } label: {
                    Label("history.title", systemImage: "clock")
                }
                .accessibilityIdentifier("history-open-button")
            }
        }
    }
}

private struct MobileHistoryRow: View {
    let entry: MobileHistoryEntry
    let model: MobileHistoryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.displayName.isEmpty ? String(localized: "history.unnamed") : entry.displayName)
                .font(.headline).accessibilityIdentifier("history-entry-name")
            Text(LocalizedStringKey("transfer.phase." + entry.phase.rawValue))
            Text(LocalizedStringKey("history.direction." + entry.direction.rawValue))
                .foregroundStyle(.secondary)
            Text(entry.updatedAt, format: .dateTime.year().month().day().hour().minute())
                .font(.subheadline).foregroundStyle(.secondary)
            Text("\(entry.completedBytes.formatted()) / \(entry.aggregateSize.formatted()) " + String(localized: "history.bytes"))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(LocalizedStringKey("history.route." + entry.route.rawValue))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(String(localized: "history.peer") + " " + entry.peer.rawValue.uuidString.prefix(8))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if entry.isReceivedCompletion {
                if !entry.isAvailable { Text("received.unavailable.short").foregroundStyle(.secondary) }
                Button("received.preview") { Task { await model.perform(.preview, for: entry.id) } }
                    .accessibilityIdentifier("received-preview-button")
                    .buttonStyle(.borderless).disabled(model.resolving)
                Button("received.share") { Task { await model.perform(.share, for: entry.id) } }
                    .accessibilityIdentifier("received-share-button")
                    .buttonStyle(.borderless).disabled(model.resolving)
            }
        }
    }
}
