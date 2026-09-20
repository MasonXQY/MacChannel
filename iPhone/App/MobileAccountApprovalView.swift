import SwiftUI

struct MobileAccountApprovalView: View {
    let model: MobileAccountApprovalModel
    let canRequest: Bool
    @State private var route: RequestRoute?
    @State private var owner = UUID()
    @Environment(\.scenePhase) private var scenePhase
    private struct RequestRoute: Identifiable, Hashable { let id: String; let requestID: String? }

    var body: some View {
        List {
            if model.phase == .loading { ProgressView("approval.loading").frame(minHeight: 44) }
            if let key = model.messageKey {
                Section { Text(LocalizedStringKey(key)); retry }
            } else if model.phase == .disabled {
                Text("approval.unavailable")
            } else {
                if canRequest {
                    Button("approval.request.title") { route = .init(id: "new", requestID: nil) }
                        .frame(minHeight: 44).accessibilityIdentifier("approval-new")
                }
                if model.requests.isEmpty, model.recoveryRequestIDs.isEmpty, model.phase == .ready {
                    Text("approval.empty").foregroundStyle(.secondary).accessibilityIdentifier("approval-empty")
                }
                ForEach(model.requests, id: \.requestID) { request in
                    Button { route = .init(id: request.requestID, requestID: request.requestID) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("approval.device.unverified")
                            Text(request.deviceID).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Date(timeIntervalSince1970: Double(request.expiresAtMilliseconds) / 1000), style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("approval-request-row")
                }
                if !model.recoveryRequestIDs.isEmpty {
                    Section("approval.previous") {
                        ForEach(model.recoveryRequestIDs, id: \.self) { id in
                            Button { route = .init(id: id, requestID: id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("approval.previous.open")
                                    Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.frame(minHeight: 44, alignment: .leading)
                            }.accessibilityIdentifier("approval-recovery-row")
                        }
                        Text("approval.previous.help").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("approval.title")
        .navigationDestination(item: $route) { route in
            MobileAccountApprovalDetailView(model: model, requestID: route.requestID)
        }
        .task { model.beginPresentation(owner: owner); await model.open(requestID: nil) }
        .refreshable { await model.refresh() }
        .onChange(of: scenePhase) { _, value in
            if value == .active, route == nil { Task { await model.refresh() } }
        }
        // The child owns the same operation while it is pushed. Returning from
        // the child clears its delivery; leaving the list ends observation.
        .onDisappear { if route == nil { model.leave(owner: owner) } }
    }
    private var retry: some View {
        Button("account.retry") { Task { await model.refresh() } }
            .frame(minHeight: 44).disabled(model.isBusy).accessibilityIdentifier("approval-retry")
    }
}
