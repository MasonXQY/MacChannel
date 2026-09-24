import MacChannelCore
import DropMeshMobileRuntime
import SwiftUI

struct MobileHistoryView: View {
    let model: MobileHistoryModel
    var isVisible = true
    @State private var filter = 0
    @State private var selection: Set<TransferID> = []
    @State private var deleteRequest: DeleteRequest?
    @State private var editMode: EditMode = .inactive

    private enum DeleteRequest: Identifiable {
        case records(Set<TransferID>)
        case all
        var id: String {
            switch self {
            case let .records(ids): "records-" + ids.map { $0.rawValue.uuidString }.sorted().joined(separator: "-")
            case .all: "all"
            }
        }
    }

    var body: some View {
        List {
            Picker("history.filter", selection: $filter) {
                Text("history.all").tag(0)
                Text("history.direction.inbound").tag(1)
                Text("history.direction.outbound").tag(2)
            }.pickerStyle(.segmented)
            if editMode.isEditing {
                Button("history.delete.selected", role: .destructive) {
                    deleteRequest = .records(selection)
                }
                .disabled(selection.isEmpty || model.deleting)
                .accessibilityIdentifier("history-delete-selected")
            }
            MobileHistorySection(model: model, latestOnly: false, filter: filter, isVisible: isVisible,
                editing: editMode.isEditing, selectedIDs: selection,
                toggleSelection: { id in
                    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                }, requestDelete: { id in deleteRequest = .records([id]) })
            if model.deleting { ProgressView("history.delete.progress") }
            if model.deleteFailed {
                Text("history.delete.failed").foregroundStyle(.secondary)
                    .accessibilityIdentifier("history-delete-error")
            }
        }
            .navigationTitle("history.title")
            .task { await model.refresh() }
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                            if !editMode.isEditing { selection.removeAll() }
                        }
                    } label: {
                        Text(editMode.isEditing ? LocalizedStringKey("action.done") : LocalizedStringKey("history.edit"))
                    }
                    .disabled(model.deleting)
                    .accessibilityIdentifier("history-edit")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("history.clear.all", role: .destructive) { deleteRequest = .all }
                            .disabled(!model.entries.contains(where: \.canDelete) || model.deleting)
                            .accessibilityIdentifier("history-clear-all")
                    } label: { Label("history.actions", systemImage: "ellipsis.circle") }
                        .accessibilityIdentifier("history-actions")
                }
            }
            .onChange(of: model.entries.map(\.id)) { _, ids in selection.formIntersection(ids) }
            .alert(deleteTitle, isPresented: Binding(get: { deleteRequest != nil }, set: { if !$0 { deleteRequest = nil } })) {
                Button("action.cancel", role: .cancel) { deleteRequest = nil }
                    .accessibilityIdentifier("history-delete-cancel")
                Button(deleteButtonTitle, role: .destructive) {
                    guard let request = deleteRequest else { return }
                    deleteRequest = nil
                    Task {
                        let success: Bool
                        switch request {
                        case let .records(ids): success = await model.deleteRecords(ids: ids)
                        case .all: success = await model.deleteRecords(ids: nil)
                        }
                        if success { selection.removeAll() }
                    }
                }
                .accessibilityIdentifier("history-delete-confirm")
            } message: { Text(deleteMessage) }
    }

    private var deleteTitle: LocalizedStringKey {
        if case .some(.all) = deleteRequest { return "history.clear.confirm.title" }
        if case let .some(.records(ids)) = deleteRequest, ids.count > 1 {
            return "history.delete.selected.confirm.title"
        }
        return "history.delete.confirm.title"
    }
    private var deleteButtonTitle: LocalizedStringKey {
        if case .some(.all) = deleteRequest { return "history.clear.all" }
        return "history.delete"
    }
    private var deleteMessage: LocalizedStringKey {
        if case .some(.all) = deleteRequest { return "history.clear.confirm.message" }
        if case let .some(.records(ids)) = deleteRequest, ids.count > 1 {
            return "history.delete.selected.confirm.message \(ids.count)"
        }
        return "history.delete.confirm.message"
    }
}

struct MobileHistorySection: View {
    let model: MobileHistoryModel
    let latestOnly: Bool
    var filter = 0
    var isVisible = true
    var editing = false
    var selectedIDs: Set<TransferID> = []
    var toggleSelection: ((TransferID) -> Void)? = nil
    var requestDelete: ((TransferID) -> Void)? = nil
    private var rows: [MobileHistoryEntry] {
        (latestOnly ? model.latestReceived : model.entries).filter {
            filter == 0 || (filter == 1 ? $0.direction == .inbound : $0.direction == .outbound)
        }
    }

    var body: some View {
        Section {
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
            }
            if rows.isEmpty && !model.loading && !model.loadFailed {
                Text("history.empty").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                MobileHistoryRow(entry: row, model: model, isVisible: isVisible,
                    editing: editing, selected: selectedIDs.contains(row.id),
                    toggleSelection: toggleSelection, requestDelete: requestDelete)
            }
            if latestOnly {
                NavigationLink { MobileHistoryView(model: model) } label: {
                    Label("history.title", systemImage: "clock")
                }
                .accessibilityIdentifier("history-open-button")
            }
            if filter != 2 { MobileReceivedFolderButton(model: model) }
        } header: {
            if latestOnly { Text("received.latest") }
        }
    }
}

private struct MobileHistoryRow: View {
    let entry: MobileHistoryEntry
    let model: MobileHistoryModel
    var isVisible = true
    var editing = false
    var selected = false
    var toggleSelection: ((TransferID) -> Void)?
    var requestDelete: ((TransferID) -> Void)?
    @State private var highlighted = false
    @State private var thumbnail: MobileHistoryThumbnail?
    @State private var showingDetails = false
    @State private var showingFiles = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 10) {
            if editing, entry.canDelete {
                Button { toggleSelection?(entry.id) } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(selected
                    ? LocalizedStringKey("history.deselect.record")
                    : LocalizedStringKey("history.select.record")))
                .accessibilityIdentifier("history-select-\(entry.id.rawValue.uuidString)")
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) { thumbnailView; primaryContent }
                        detailsButton
                    }
                } else {
                    HStack(spacing: 12) { thumbnailView; primaryContent; detailsButton }
                }
            }
            .allowsHitTesting(!editing)
        }
        .listRowBackground(highlighted ? Color.accentColor.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground))
        .swipeActions(allowsFullSwipe: false) {
            if !editing, entry.canDelete, let requestDelete {
                Button("history.delete", role: .destructive) { requestDelete(entry.id) }
                    .accessibilityIdentifier("history-delete-\(entry.id.rawValue.uuidString)")
            }
        }
        .onAppear { noteViewed() }
        .onChange(of: isVisible) { _, visible in if visible { noteViewed() } }
        .onChange(of: entry.isReceivedCompletion) { _, completed in if completed { noteViewed() } }
        .navigationDestination(isPresented: $showingDetails) {
            MobileHistoryDetailView(entry: entry, model: model)
        }
        .navigationDestination(isPresented: $showingFiles) {
            MobileHistoryFilesView(entry: entry, model: model)
        }
        .task(id: "\(entry.id.rawValue.uuidString)-\(entry.isAvailable)-\(entry.updatedAt)-\(entry.files.map { $0.id.rawValue.uuidString }.joined())") {
            thumbnail = nil
            let loaded = await model.thumbnail(for: entry.id)
            guard !Task.isCancelled else { return }
            thumbnail = loaded
        }
    }

    private func noteViewed() {
        guard isVisible else { return }
        highlighted = highlighted || model.isUnread(entry)
        model.markRead(entry)
    }

    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail.image).resizable().scaledToFill()
                    .accessibilityLabel(Text(entry.displayName))
                    .accessibilityIdentifier("history-thumbnail-\(entry.id.rawValue.uuidString)")
            } else {
                Image(systemName: fileIcon).resizable().scaledToFit().padding(10).foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background {
            if entry.files.count > 1 {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .frame(width: 46, height: 46).rotationEffect(.degrees(8)).offset(x: 3, y: -3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if entry.files.count > 1 {
                Text("\(entry.files.count)").font(.caption2.bold()).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: Capsule())
                    .accessibilityIdentifier("history-file-count-\(entry.id.rawValue.uuidString)")
            }
        }
    }

    @ViewBuilder private var primaryContent: some View {
        if !entry.files.isEmpty {
            Button {
                if entry.files.count == 1, let file = entry.files.first, file.isAvailable {
                    Task { await model.perform(.preview, for: entry.id, itemID: file.id) }
                } else { showingFiles = true }
            } label: { summary }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history-entry-\(entry.id.rawValue.uuidString)")
        } else if entry.isReceivedCompletion {
            Button { Task { await model.perform(.preview, for: entry.id) } } label: { summary }
                .buttonStyle(.plain)
                .disabled(model.resolving || !entry.isAvailable)
                .accessibilityIdentifier("history-entry-\(entry.id.rawValue.uuidString)")
        } else {
            Button { showingDetails = true } label: { summary }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history-entry-\(entry.id.rawValue.uuidString)")
        }
    }

    private var detailsButton: some View {
        Button { showingDetails = true } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Label("history.details", systemImage: "info.circle").frame(minHeight: 44)
            } else {
                Image(systemName: "info.circle").frame(minWidth: 44, minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "history.details") + ", " +
            (entry.displayName.isEmpty ? String(localized: "history.unnamed") : entry.displayName))
        .accessibilityIdentifier("history-info-\(entry.id.rawValue.uuidString)")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.displayName.isEmpty ? String(localized: "history.unnamed") : entry.displayName)
                .font(.headline).lineLimit(2).accessibilityIdentifier("history-entry-name")
            Text(model.peerName(for: entry.peer)).font(.subheadline).foregroundStyle(.secondary)
            if entry.files.count > 1 {
                Text("history.files.count \(entry.files.count)").font(.caption).foregroundStyle(.secondary)
            }
            metadata
                .font(.caption).foregroundStyle(.secondary)
            if entry.isReceivedCompletion && !entry.isAvailable {
                Text("received.unavailable.short").font(.caption).foregroundStyle(.secondary)
            }
            if entry.direction == .outbound && !entry.files.contains(where: { $0.isAvailable }) {
                Text("history.sent.unavailable.short").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var metadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(LocalizedStringKey("history.direction." + entry.direction.rawValue))
             + Text(" · ")
             + Text(LocalizedStringKey("transfer.phase." + entry.phase.rawValue)))
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.updatedAt, format: .relative(presentation: .named))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fileIcon: String {
        let ext = (entry.displayName as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "gif", "tiff", "webp"].contains(ext) { return "photo" }
        if ext == "pdf" { return "doc.richtext" }
        return "doc"
    }
}

private struct MobileHistoryFilesView: View {
    let entry: MobileHistoryEntry
    let model: MobileHistoryModel
    var body: some View {
        List {
            if let message = model.actionMessage {
                Text(message == .unavailable
                    ? (entry.direction == .outbound ? "history.source.unavailable" : "received.unavailable")
                    : "received.unsupported")
                    .accessibilityIdentifier("history-file-action-message")
            }
            ForEach(entry.files, id: \.id) { file in
                Section {
                    Button {
                        Task { await model.perform(.preview, for: entry.id, itemID: file.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).foregroundStyle(.primary)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!file.isAvailable || model.resolving)
                    if file.isAvailable {
                        Button("received.share") {
                            Task { await model.perform(.share, for: entry.id, itemID: file.id) }
                        }.disabled(model.resolving)
                    } else {
                        Text(entry.direction == .outbound ? "history.sent.unavailable.short" : "received.unavailable.short")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("history.files.title")
    }
}

private struct MobileHistoryDetailView: View {
    let entry: MobileHistoryEntry
    let model: MobileHistoryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !entry.files.isEmpty {
                NavigationLink("history.files.title") { MobileHistoryFilesView(entry: entry, model: model) }
            } else if entry.isLegacy {
                Text("history.legacy.files").foregroundStyle(.secondary)
            }
            Section("history.details") {
                LabeledContent("history.peer", value: model.peerName(for: entry.peer))
                LabeledContent("history.direction") { Text(LocalizedStringKey("history.direction." + entry.direction.rawValue)) }
                LabeledContent("history.time") { Text(entry.updatedAt, format: .dateTime.year().month().day().hour().minute().second()) }
                LabeledContent("history.size", value: ByteCountFormatter.string(
                    fromByteCount: entry.aggregateSize > UInt64(Int64.max) ? Int64.max : Int64(entry.aggregateSize), countStyle: .file))
                LabeledContent("history.progress", value: "\(entry.completedBytes.formatted()) / \(entry.aggregateSize.formatted())")
            }
            Section("history.diagnostics") {
                LabeledContent("history.route") { Text(LocalizedStringKey("history.route." + entry.route.rawValue)) }
                LabeledContent("history.transfer.id") { Text(entry.id.rawValue.uuidString).font(.caption.monospaced()).textSelection(.enabled) }
                LabeledContent("devices.id") { Text(entry.peer.rawValue.uuidString).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if entry.isReceivedCompletion {
                Section("settings.receiving.title") {
                    if model.availabilityWarning {
                        Text("history.availability.warning").foregroundStyle(.secondary)
                    }
                    if let message = model.actionMessage {
                        Text(message == .unavailable ? "received.unavailable" : "received.unsupported")
                            .accessibilityIdentifier("history-detail-action-message")
                    }
                    Button("received.preview") { Task { await model.perform(.preview, for: entry.id) } }
                        .disabled(!currentAvailability || model.resolving)
                    Button("received.share") { Task { await model.perform(.share, for: entry.id) } }
                        .disabled(!currentAvailability || model.resolving)
                        .accessibilityIdentifier("history-share-\(entry.id.rawValue.uuidString)")
                }
            }
        }
        .navigationTitle(entry.displayName.isEmpty ? String(localized: "history.unnamed") : entry.displayName)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("action.done") { dismiss() } } }
    }

    private var currentAvailability: Bool {
        model.entries.first(where: { $0.id == entry.id })?.isAvailable ?? entry.isAvailable
    }
}
