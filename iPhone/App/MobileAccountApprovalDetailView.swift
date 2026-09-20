import MacChannelCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MobileAccountApprovalDetailView: View {
    let model: MobileAccountApprovalModel
    let requestID: String?
    var readScope: MobileAccountApprovalReadScope = .ownRequests
    @State private var independentCode = ""
    @State private var owner = UUID()
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollViewReader { scroll in
        Form {
            if model.isBusy { ProgressView("approval.loading").frame(minHeight: 44) }
            if let key = model.messageKey {
                Section { Text(LocalizedStringKey(key)).accessibilityIdentifier("approval-error").id("approval-error")
                    action("account.retry", id: "approval-retry") { await model.refresh() }
                    if model.detail == nil, model.selectedRequestID != nil {
                        action("approval.resume", id: "approval-resume") { await model.resume() }
                    }
                }
            }
            if let detail = model.detail {
                Section {
                    Text(LocalizedStringKey(detail.phase.mobileMessageKey)).accessibilityIdentifier("approval-state").id("approval-state")
                    if detail.phase == .joined { Text("approval.not-transfer").foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("approval.expires").font(.subheadline).foregroundStyle(.secondary)
                        Text(Date(timeIntervalSince1970: Double(detail.summary.expiresAtMilliseconds) / 1000), format: .dateTime)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if detail.role == .subject, let code = detail.requestCode {
                    codeSection(code, title: "approval.request-code", instructions: "approval.request-code.help")
                }
                if detail.role != .subject, let code = detail.memberCode {
                    codeSection(code, title: "approval.member-code", instructions: "approval.member-code.help")
                }
                nextAction(detail)
                Section {
                    action("approval.refresh", id: "approval-refresh") { await model.refresh() }
                    if [.waitingForMember, .waitingForSubject, .waitingForActor, .retryableFailure, .verifyingHistory].contains(detail.phase) {
                        action("approval.resume", id: "approval-resume") { await model.resume() }
                    }
                    if [.waitingForMember, .needsMemberVerification, .waitingForSubject, .needsSubjectConfirmation, .waitingForActor, .retryableFailure].contains(detail.phase) {
                        if detail.role == .subject {
                            Button("approval.cancel.title", role: .destructive) { model.prepareCancellation() }
                                .frame(minHeight: 44).disabled(model.isBusy).accessibilityIdentifier("approval-cancel-request")
                        } else {
                            Button("approval.reject.title", role: .destructive) { model.prepareRejection() }
                                .frame(minHeight: 44).disabled(model.isBusy).accessibilityIdentifier("approval-reject-request")
                        }
                    }
                }
                Section("approval.technical") {
                    Text("approval.device.unverified").font(.caption)
                    Text(detail.summary.deviceID).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if requestID == nil, model.phase == .ready {
                Section {
                    Text("approval.request.help")
                    action("approval.request.title", id: "approval-prepare-request") { await model.prepareJoin() }
                }
            }
        }
        .navigationTitle("approval.detail.title")
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .task { model.beginPresentation(owner: owner, readScope: readScope); await model.open(requestID: requestID) }
        .refreshable { await model.refresh() }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await model.refresh() } }
            else if let choice = model.confirmation { model.dismiss(id: choice.id) }
        }
        .onDisappear { model.leave(owner: owner); independentCode = "" }
        .sheet(item: confirmationBinding) { choice in ApprovalConfirmationSheet(model: model, choice: choice) }
        .onChange(of: model.actionPresentationID) { _, id in
            if id != nil { scroll.scrollTo(model.messageKey == nil ? "approval-state" : "approval-error", anchor: .top) }
        }
        }
    }

    private var confirmationBinding: Binding<MobileAccountApprovalConfirmation?> {
        let id = model.confirmation?.id
        return Binding(get: { model.confirmation }, set: { value in
            if value == nil, let id {
                Task { @MainActor in await Task.yield(); model.dismiss(id: id) }
            }
        })
    }
    @ViewBuilder private func nextAction(_ detail: AccountDeviceApprovalView) -> some View {
        if detail.phase == .needsMemberVerification {
            input(title: "approval.enter-request-code")
            action("approval.review", id: "approval-prepare-member") {
                inputFocused = false
                await model.prepareApproval(code: independentCode)
            }
                .disabled(independentCode.isEmpty)
        } else if detail.role == .subject, [.needsSubjectConfirmation, .verifyingHistory].contains(detail.phase) {
            input(title: "approval.enter-member-code")
            action(detail.phase == .verifyingHistory ? "approval.verify.title" : "approval.review", id: "approval-prepare-subject") {
                inputFocused = false
                await model.prepareSubject(code: independentCode)
            }.disabled(independentCode.isEmpty)
        }
    }
    private func input(title: String) -> some View {
        Section(LocalizedStringKey(title)) {
            Text("approval.independent.help").foregroundStyle(.secondary)
            TextField(LocalizedStringKey(title), text: $independentCode, axis: .vertical)
                .focused($inputFocused)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .lineLimit(3...10).accessibilityIdentifier("approval-code-input")
            PasteButton(payloadType: String.self) { values in
                if let value = values.first { independentCode = value }
            }.frame(minHeight: 44).accessibilityIdentifier("approval-paste")
        }
    }
    func codeSection(_ code: String, title: String, instructions: String) -> some View {
        Section(LocalizedStringKey(title)) {
            Text(LocalizedStringKey(instructions)).foregroundStyle(.secondary)
            if code.count > 160 {
                ScrollView {
                    Text(code).font(.body.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("approval-comparison-code")
                }.frame(height: 220).accessibilityLabel(Text(LocalizedStringKey(title)))
            } else {
                Text(code).font(.body.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("approval-comparison-code")
            }
            Button("approval.copy") { UIPasteboard.general.string = code }
                .frame(minHeight: 44).accessibilityIdentifier("approval-copy")
        }
    }
    private func action(_ title: String, id: String, perform: @escaping @MainActor () async -> Void) -> some View {
        Button(LocalizedStringKey(title)) { Task { await perform() } }
            .frame(minHeight: 44).disabled(model.isBusy).accessibilityIdentifier(id)
    }
}

private struct ApprovalConfirmationSheet: View {
    let model: MobileAccountApprovalModel
    let choice: MobileAccountApprovalConfirmation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(LocalizedStringKey(choice.titleKey + ".help")) }
                if case .ticket(let ticket, _) = choice.action {
                    if let fingerprint = ticket.presentation.fingerprint {
                        Section("approval.fingerprint") {
                            Text(fingerprint).font(.body.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(ticket.expiresAt, format: .dateTime).foregroundStyle(.secondary)
                }
                Section {
                    Button(LocalizedStringKey(choice.titleKey)) { model.accept(id: choice.id); dismiss() }
                        .frame(minHeight: 44).accessibilityIdentifier("approval-confirm")
                    Button("account.cancel", role: .cancel) { model.dismiss(id: choice.id); dismiss() }
                        .frame(minHeight: 44).accessibilityIdentifier("approval-dismiss")
                }
            }.navigationTitle(LocalizedStringKey(choice.titleKey)).navigationBarTitleDisplayMode(.inline)
        }
        .onDisappear { model.dismiss(id: choice.id) }
    }
}
