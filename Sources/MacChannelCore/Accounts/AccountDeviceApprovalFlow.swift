import Foundation

/// Captured values only. The session actor owns credentials, admission and ticket installation.
/// Every dependency is fenced synchronously; no callback can look up a newer session.
struct AccountDeviceApprovalFlow: Sendable {
    typealias Intent = AccountGroupApprovalIntent
    struct Candidate: Sendable {
        enum Value: Sendable {
            case request(Intent)
            case proposal(AccountGroupPendingRequest, AccountGroupEvent, Data)
            case countersign(Intent, Intent.Proof)
            case committed(AccountGroupPendingRequest, Intent.Proof)
        }
        let ticket: AccountDeviceApprovalTicket
        let value: Value
    }
    let configuration: AccountDeviceApproval
    let pending: any AccountGroupPendingService
    let enrollment: any AccountGroupEnrollmentService
    let historyService: any AccountGroupService
    let verifier: AccountGroupHistoryVerifier
    let session: AccountStoredSession
    let authorization: AccountGroupVerificationAuthorization
    let now: @Sendable () -> Date
    var binding: AccountSessionBinding { session.binding }
    var account: String { session.tokens.identity.accountID.uuidString.lowercased() }
    var device: String { binding.deviceID.uuidString.lowercased() }
    var key: Data { configuration.identity.publicKey.rawRepresentation }
    var token: String { session.tokens.accessToken }

    func check(deadline: Date? = nil) throws {
        try Task.checkCancellation(); try authorization.requireCurrent()
        if let deadline, deadline <= now() { throw AccountDeviceApprovalError.requestExpired }
    }
    func call<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try check()
        do { let value = try await body(); try check(); return value }
        catch { try check(); throw error }
    }
    func storage<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await call(body) }
        catch let error as AccountDeviceApprovalValueError { throw error }
        catch { try check(); throw AccountDeviceApprovalError.secureStorage }
    }
    func scope(_ request: String, _ role: Intent.Role) throws -> Intent.Scope {
        try .init(binding: binding, accountID: account, requestID: request, role: role)
    }
    func load(_ request: String, _ role: Intent.Role) async throws -> Intent? {
        let scope = try scope(request, role)
        let value = try await storage { try await configuration.intentStorage.load(scope: scope) }
        if let value { try validate(value); guard value.scope == scope else { throw AccountDeviceApprovalError.secureStorage } }
        return value
    }
    func validate(_ intent: Intent) throws {
        guard intent.scope.binding == binding, intent.scope.accountID == account, intent.localPublicKey == key else {
            throw AccountDeviceApprovalError.secureStorage
        }
        _ = try Intent(scope: intent.scope, intentID: intent.intentID, originalSessionIdentity: intent.originalSessionIdentity,
            localPublicKey: intent.localPublicKey, request: intent.request, preparedAtMilliseconds: intent.preparedAtMilliseconds,
            originalAccessExpiresAtMilliseconds: intent.originalAccessExpiresAtMilliseconds, acknowledgment: intent.acknowledgment, phase: intent.phase)
    }
    func live(_ intent: Intent) throws {
        try validate(intent); try check(deadline: intent.confirmationDeadline)
        guard intent.originalSessionIdentity == session.tokens.identity else { throw AccountDeviceApprovalError.sessionChanged }
        guard case .active = intent.phase else { throw AccountDeviceApprovalError.requestConflict }
        authorization.restrict(to: intent.confirmationDeadline)
        try check()
    }
    func replace(_ old: Intent, _ next: Intent) async throws -> Intent {
        guard old.canReplace(with: next) else { throw AccountDeviceApprovalError.requestConflict }
        try await storage { try await configuration.intentStorage.replace(scope: old.scope, expected: old, with: next) }
        return next
    }
    func context(_ summary: AccountGroupPendingSummary) throws -> AccountDeviceApprovalRequestContext {
        guard summary.accountID == account else { throw AccountServiceError.invalidResponse }
        return try .init(origin: binding.origin, summary: summary)
    }
    func validated(_ value: AccountGroupPendingRequest, request: String,
                   expected: AccountDeviceApprovalRequestContext? = nil, proof: Intent.Proof? = nil,
                   operation: String = "get") throws -> AccountGroupPendingRequest {
        let s = try validated(value.summary)
        guard s.requestID == request else { throw AccountServiceError.invalidResponse }
        let result = try AccountGroupPendingRequest(summary: s, draft: value.draft, event: value.event, eventHash: value.eventHash)
        if let expected { guard try context(s) == expected else { throw AccountDeviceApprovalError.requestConflict } }
        if let proof, let draft = result.draft { guard draft == proof.draft else { throw AccountDeviceApprovalError.requestConflict } }
        guard !(operation == "propose" && s.status == .requested),
              !(operation == "countersign" && (s.status == .requested || s.status == .proposed)),
              !(["commit", "cancel", "reject"].contains(operation) && s.status.active) else { throw AccountServiceError.invalidResponse }
        return result
    }
    func validated(_ s: AccountGroupPendingSummary) throws -> AccountGroupPendingSummary {
        guard s.accountID == account else { throw AccountServiceError.invalidResponse }
        return try .init(requestID: s.requestID, accountID: s.accountID, groupID: s.groupID, generation: s.generation,
            deviceID: s.deviceID, publicKey: s.publicKey, status: s.status,
            createdAtMilliseconds: s.createdAtMilliseconds, expiresAtMilliseconds: s.expiresAtMilliseconds)
    }
    func get(_ id: String) async throws -> AccountGroupPendingRequest {
        guard AccountGroupPage.validGroupID(id) else { throw AccountDeviceApprovalError.requestConflict }
        return try validated(await call { try await pending.groupJoin(accessToken: token, accountID: account, requestID: id) }, request: id)
    }
    func list() async throws -> [AccountGroupPendingSummary] {
        let values = try await call { try await pending.groupJoins(accessToken: token, accountID: account) }
        guard values.count <= 32, Set(values.map(\.requestID)).count == values.count,
              values.allSatisfy({ $0.status.active }) else { throw AccountServiceError.invalidResponse }
        return try values.map(validated)
    }
    func retainedRequestIDs() async throws -> [String] {
        let records = try await storage { try await configuration.intentStorage.list(binding: binding, accountID: account) }
        guard records.count <= 32 else { throw AccountDeviceApprovalError.secureStorage }
        var scopes = Set<String>()
        for record in records {
            do { try validate(record) } catch { throw AccountDeviceApprovalError.secureStorage }
            guard scopes.insert(record.scope.requestID + ":" + record.scope.role.rawValue).inserted else {
                throw AccountDeviceApprovalError.secureStorage
            }
        }
        // Original-session mutation consent is deliberately not resumed. Historical
        // requests remain discoverable under this account's current session.
        return Array(Set(records.map { $0.scope.requestID })).sorted()
    }
    func history(_ group: String) async throws -> [AccountGroupEvent] {
        try await call { try await historyService.groupHistory(accessToken: token, groupID: group) }
    }
    func inspect(_ events: [AccountGroupEvent], _ request: AccountDeviceApprovalRequestContext, _ anchor: Data) async throws -> AccountGroupSnapshot {
        try await call { try await verifier.inspect(history: events, binding: binding, accountID: account,
            groupID: request.groupID, expectedGeneration: request.generation, expectedAnchorHash: anchor, authorization: authorization) }
    }
    func member(_ snapshot: AccountGroupSnapshot, device: String, key: Data) -> Bool {
        snapshot.members.contains { $0.deviceID == device && $0.publicKey == key }
    }
    func predecessor(_ snapshot: AccountGroupSnapshot, _ event: AccountGroupEvent) throws {
        guard snapshot.sequence + 1 == event.sequence, snapshot.headHash == event.previousHash,
              snapshot.generation == event.generation, snapshot.groupID == event.groupID,
              member(snapshot, device: event.actorDeviceID, key: event.actorPublicKey),
              !snapshot.members.contains(where: { $0.deviceID == event.subjectDeviceID }) else {
            throw AccountDeviceApprovalError.invalidHistory
        }
    }
    func ticket(_ operation: AccountDeviceApprovalTicket.Operation, request: AccountDeviceApprovalRequestContext,
                deadline: Date? = nil, fingerprint: String? = nil, value: Candidate.Value) throws -> Candidate {
        try check(deadline: deadline)
        let expires = min(now().addingTimeInterval(300), session.tokens.accessExpiresAt, deadline ?? .distantFuture)
        return Candidate(ticket: .init(id: UUID(), operation: operation, expiresAt: expires,
            presentation: .init(requestID: request.requestID, groupID: request.groupID,
                requestCode: operation == .requestJoin ? request.requestCode : nil, fingerprint: fingerprint)), value: value)
    }
    func freshIntent(_ request: AccountDeviceApprovalRequestContext, role: Intent.Role, phase: Intent.Phase,
                     acknowledgment: Intent.Acknowledgment? = nil) throws -> Intent {
        guard let prepared = AccountServiceClient.validEpochMilliseconds(now()),
              let expires = AccountServiceClient.validEpochMilliseconds(session.tokens.accessExpiresAt) else { throw AccountDeviceApprovalError.unavailable }
        return try Intent(scope: scope(request.requestID, role), intentID: UUID(), originalSessionIdentity: session.tokens.identity,
            localPublicKey: key, request: request, preparedAtMilliseconds: UInt64(prepared),
            originalAccessExpiresAtMilliseconds: UInt64(expires), acknowledgment: acknowledgment, phase: phase)
    }
    func acknowledgment(_ request: AccountGroupPendingRequest) throws -> Intent.Acknowledgment {
        try .init(createdAtMilliseconds: request.summary.createdAtMilliseconds, expiresAtMilliseconds: request.summary.expiresAtMilliseconds)
    }
    func prepareJoin() async throws -> Candidate {
        let retained = try await storage { try await configuration.intentStorage.list(binding: binding, accountID: account) }
        for value in retained { try validate(value) }
        guard !retained.contains(where: { $0.scope.role == .subject && !$0.isAcknowledgedTerminal }) else { throw AccountDeviceApprovalError.requestConflict }
        let found = try await call { try await enrollment.discoverGroup(accessToken: token, accountID: account) }
        guard case .present(let metadata) = found else { throw AccountDeviceApprovalError.unavailable }
        try metadata.anchor.validate()
        guard metadata.anchor.accountID == account, metadata.anchor.groupID == metadata.groupID,
              metadata.anchor.action == "bootstrap", metadata.anchor.generation == metadata.generation,
              try metadata.anchor.digest() == metadata.anchorHash, (1...8192).contains(metadata.headSequence),
              metadata.headHash.count == 32, metadata.headSequence != 1 || metadata.headHash == metadata.anchorHash else { throw AccountServiceError.invalidResponse }
        let request = try AccountDeviceApprovalRequestContext(origin: binding.origin, requestID: UUID().uuidString.lowercased(),
            accountID: account, groupID: metadata.groupID, generation: metadata.generation, subjectDeviceID: device, subjectPublicKey: key)
        let intent = try freshIntent(request, role: .subject, phase: .active(.subjectRequested))
        return try ticket(.requestJoin, request: request, deadline: intent.confirmationDeadline, value: .request(intent))
    }
    func confirmJoin(_ intent: Intent) async throws -> AccountDeviceApprovalView {
        try live(intent)
        // Recheck uncertainty at confirmation; preparation itself owns no durable consent.
        let records = try await storage { try await configuration.intentStorage.list(binding: binding, accountID: account) }
        for value in records { try validate(value) }
        guard !records.contains(where: { $0.scope.role == .subject && !$0.isAcknowledgedTerminal }) else { throw AccountDeviceApprovalError.requestConflict }
        try live(intent)
        try await storage { try await configuration.intentStorage.insert(intent) }
        return try await sendCreate(intent)
    }
    func sendCreate(_ intent: Intent) async throws -> AccountDeviceApprovalView {
        try live(intent)
        let request = try validated(await call { try await pending.createGroupJoin(accessToken: token, accountID: account,
            requestID: intent.scope.requestID, groupID: intent.groupID, generation: intent.generation) },
            request: intent.scope.requestID, expected: intent.request)
        try match(request, intent: intent, mutation: true)
        try live(intent)
        let retained = try await replace(intent, intent.replacing(phase: intent.phase, acknowledgment: acknowledgment(request)))
        return try await reconcile(request, intent: retained, mayPin: false)
    }
    func prepareApproval(_ id: String) async throws -> Candidate {
        let request = try await get(id), context = try context(request.summary)
        try check(deadline: request.summary.expiresAt)
        guard request.summary.status == .requested, request.summary.deviceID != device,
              try await load(id, .actor) == nil else { throw AccountDeviceApprovalError.requestConflict }
        let events = try await history(context.groupID)
        let snapshot = try await call { try await verifier.accept(history: events, binding: binding, accountID: account,
            groupID: context.groupID, authorization: authorization) }
        guard snapshot.generation == context.generation, member(snapshot, device: device, key: key),
              !snapshot.members.contains(where: { $0.deviceID == context.subjectDeviceID }), snapshot.sequence < 8192,
              let timestamp = AccountServiceClient.validEpochMilliseconds(now()) else { throw AccountDeviceApprovalError.invalidHistory }
        let unsigned = try AccountGroupEvent(accountID: account, groupID: context.groupID, generation: context.generation,
            sequence: snapshot.sequence + 1, previousHash: snapshot.headHash, action: "approve", actorDeviceID: device,
            actorPublicKey: key, subjectDeviceID: context.subjectDeviceID, subjectPublicKey: context.subjectPublicKey, epochMilliseconds: timestamp)
        return try ticket(.approveJoin, request: context, deadline: request.summary.expiresAt,
            value: .proposal(request, unsigned, events[0].digest()))
    }
    func confirmApproval(_ request: AccountGroupPendingRequest, _ unsigned: AccountGroupEvent, _ anchor: Data,
                         code: String) async throws -> AccountDeviceApprovalView {
        let context = try context(request.summary)
        guard context.matchesRequestCode(code) else { throw AccountDeviceApprovalError.verificationMismatch }
        let fresh = try await get(context.requestID)
        guard fresh == request else { throw AccountDeviceApprovalError.requestConflict }
        let events = try await history(context.groupID)
        let snapshot = try await inspect(events, context, anchor)
        try predecessor(snapshot, unsigned); try check(deadline: request.summary.expiresAt)
        let payload = try unsigned.canonicalPayload()
        try check()
        let draft = try AccountGroupApprovalDraft(event: .init(canonicalPayload: payload,
            signature: configuration.identity.sign(payload).derRepresentation, subjectSignature: Data()))
        let capsule = try AccountDeviceApprovalCapsule(origin: binding.origin, requestID: context.requestID, draft: draft, expectedAnchorHash: anchor)
        let proof = try Intent.Proof(request: context, draft: draft, capsule: capsule)
        let intent = try freshIntent(context, role: .actor, phase: .active(.actorProposed(proof)), acknowledgment: acknowledgment(request))
        try live(intent)
        try await storage { try await configuration.intentStorage.insert(intent) }
        return try await sendProposal(intent, proof)
    }
    func sendProposal(_ intent: Intent, _ proof: Intent.Proof) async throws -> AccountDeviceApprovalView {
        try live(intent)
        let request = try validated(await call { try await pending.proposeGroupJoin(accessToken: token, accountID: account,
            requestID: intent.scope.requestID, draft: proof.draft) }, request: intent.scope.requestID,
            expected: intent.request, proof: proof, operation: "propose")
        if request.summary.status == .countersigned { return try await commit(intent, proof, request) }
        return try await reconcile(request, intent: intent, mayPin: true)
    }
    func prepareConfirmation(_ id: String, code: String) async throws -> Candidate {
        let request = try await get(id), context = try context(request.summary)
        guard context.subjectDeviceID == device, context.subjectPublicKey == key, let draft = request.draft else { throw AccountDeviceApprovalError.requestConflict }
        let capsule: AccountDeviceApprovalCapsule
        do { capsule = try .parse(code, expectedRequest: context, expectedDraft: draft) }
        catch { throw AccountDeviceApprovalError.verificationMismatch }
        let proof = try Intent.Proof(request: context, draft: draft, capsule: capsule)
        let events = try await history(context.groupID)
        let snapshot = try await inspect(events, context, capsule.anchorHash)
        if request.summary.status == .committed {
            try exactCommitted(request, events)
            return try ticket(.verifyCommitted, request: context, fingerprint: capsule.fingerprint, value: .committed(request, proof))
        }
        guard request.summary.status == .proposed, let intent = try await load(id, .subject), intent.request == context,
              case .active(.subjectRequested) = intent.phase else { throw AccountDeviceApprovalError.requestConflict }
        try match(request, intent: intent)
        try live(intent); try predecessor(snapshot, draft.event)
        return try ticket(.confirmJoin, request: context, deadline: min(intent.confirmationDeadline, request.summary.expiresAt),
            fingerprint: capsule.fingerprint, value: .countersign(intent, proof))
    }
    func confirmSubject(_ intent: Intent, _ proof: Intent.Proof) async throws -> AccountDeviceApprovalView {
        try live(intent)
        guard try await load(intent.scope.requestID, .subject) == intent else { throw AccountDeviceApprovalError.requestConflict }
        let request = try validated(await get(intent.scope.requestID), request: intent.scope.requestID, expected: intent.request, proof: proof)
        guard request.summary.status == .proposed, request.draft == proof.draft else { throw AccountDeviceApprovalError.requestConflict }
        try match(request, intent: intent, mutation: true)
        let events = try await history(intent.groupID)
        let snapshot = try await inspect(events, intent.request, proof.capsule.anchorHash)
        try predecessor(snapshot, proof.draft.event); try live(intent)
        let signature = try configuration.identity.sign(proof.draft.event.canonicalPayload()).derRepresentation
        let event = try proof.draft.finalize(subjectSignature: signature)
        try live(intent)
        let signed = try await replace(intent, intent.replacing(phase: .active(.subjectCountersigned(proof, event)),
            acknowledgment: acknowledgment(request)))
        return try await sendCountersign(signed, proof, event)
    }
    func sendCountersign(_ intent: Intent, _ proof: Intent.Proof, _ event: AccountGroupEvent) async throws -> AccountDeviceApprovalView {
        try live(intent)
        let request = try validated(await call { try await pending.countersignGroupJoin(accessToken: token, accountID: account,
            requestID: intent.scope.requestID, draftHash: proof.canonicalPayloadDigest, subjectSignature: event.subjectSignature) },
            request: intent.scope.requestID, expected: intent.request, proof: proof, operation: "countersign")
        if let received = request.event, received != event { throw AccountDeviceApprovalError.requestConflict }
        return try await reconcile(request, intent: intent, mayPin: true)
    }
    func commit(_ intent: Intent, _ proof: Intent.Proof, _ receipt: AccountGroupPendingRequest) async throws -> AccountDeviceApprovalView {
        try live(intent)
        try match(receipt, intent: intent, mutation: true)
        guard intent.scope.role == .actor, receipt.draft == proof.draft, receipt.event != nil else { throw AccountDeviceApprovalError.requestConflict }
        let request = try validated(await call { try await pending.commitGroupJoin(accessToken: token, accountID: account,
            requestID: intent.scope.requestID, draftHash: proof.canonicalPayloadDigest) }, request: intent.scope.requestID,
            expected: intent.request, proof: proof, operation: "commit")
        if request.summary.status == .committed, request.event != receipt.event { throw AccountDeviceApprovalError.requestConflict }
        return try await reconcile(request, intent: intent, mayPin: true)
    }
    func exactCommitted(_ request: AccountGroupPendingRequest, _ events: [AccountGroupEvent]) throws {
        guard request.summary.status == .committed, let event = request.event, event.sequence > 1,
              event.sequence <= UInt64(events.count), events[Int(event.sequence - 1)] == event else { throw AccountDeviceApprovalError.invalidHistory }
    }
    func verifiedCommitted(_ request: AccountGroupPendingRequest, _ proof: Intent.Proof, mayPin: Bool) async throws -> AccountGroupSnapshot {
        guard request.draft == proof.draft else { throw AccountDeviceApprovalError.requestConflict }
        let context = try context(request.summary), events = try await history(context.groupID)
        _ = try await inspect(events, context, proof.capsule.anchorHash)
        try exactCommitted(request, events)
        do {
            return try await call { try await verifier.accept(history: events, binding: binding, accountID: account,
                groupID: context.groupID, authorization: authorization) }
        } catch AccountGroupCheckpointError.missingCheckpoint {
            guard mayPin else { throw AccountGroupCheckpointError.missingCheckpoint }
            _ = try await call { try await verifier.confirm(anchor: events[0], expectedAccountID: account,
                expectedGroupID: context.groupID, expectedGeneration: context.generation,
                expectedAnchorHash: proof.capsule.anchorHash, binding: binding, authorization: authorization) }
            return try await call { try await verifier.accept(history: events, binding: binding, accountID: account,
                groupID: context.groupID, authorization: authorization) }
        }
    }
    func confirmCommitted(_ expected: AccountGroupPendingRequest, _ proof: Intent.Proof) async throws -> AccountDeviceApprovalView {
        let request = try await get(expected.summary.requestID)
        guard request == expected else { throw AccountDeviceApprovalError.requestConflict }
        let snapshot = try await verifiedCommitted(request, proof, mayPin: true)
        return view(request, intent: nil, snapshot: snapshot)
    }
    func retainedProof(_ intent: Intent?) -> Intent.Proof? {
        switch intent?.activePredecessor {
        case .actorProposed(let proof), .subjectCountersigned(let proof, _): return proof
        default: return nil
        }
    }
    func match(_ request: AccountGroupPendingRequest, intent: Intent, mutation: Bool = false) throws {
        _ = try validated(request, request: intent.scope.requestID, expected: intent.request, proof: retainedProof(intent))
        // Server acknowledgment is immutable once learned. Neither earlier nor
        // later timestamps may replace an already confirmed pair.
        if let known = intent.acknowledgment, try known != acknowledgment(request) {
            throw AccountDeviceApprovalError.requestConflict
        }
        if case .subjectCountersigned(_, let retained) = intent.activePredecessor,
           let received = request.event, received != retained { throw AccountDeviceApprovalError.requestConflict }
        if mutation {
            // A lost Create response can leave no durable acknowledgment. Bound
            // this operation immediately to the newly fetched expiry, before
            // signatures, proof writes or HTTP, and across all following awaits.
            try live(intent)
            authorization.restrict(to: request.summary.expiresAt)
            try check()
        }
    }
    func read(_ id: String, publishMembership: Bool = false) async throws -> AccountDeviceApprovalView {
        let request = try await get(id)
        let intent = try await load(id, request.summary.deviceID == device ? .subject : .actor)
        if let intent { try match(request, intent: intent) }
        // A read never accepts/advances a checkpoint. It may inspect independently retained evidence.
        var snapshot: AccountGroupSnapshot?
        if request.summary.status == .committed, let proof = retainedProof(intent) {
            let events = try await history(request.summary.groupID)
            snapshot = try await inspect(events, context(request.summary), proof.capsule.anchorHash)
            try exactCommitted(request, events)
        }
        // Code-less status observation never publishes membership. Explicit resume
        // may return independently inspected history, without adopting a missing pin.
        return view(request, intent: intent, snapshot: publishMembership ? snapshot : nil)
    }
    func resume(_ id: String) async throws -> AccountDeviceApprovalView {
        // Load before HTTP: lost Create acknowledgment may have left no server record.
        let subject = try await load(id, .subject)
        let retained = try await (subject == nil ? load(id, .actor) : subject)
        guard let intent = retained else { throw AccountDeviceApprovalError.requestConflict }
        // Historical receipts can be read under a newer session, but never revive consent.
        if intent.originalSessionIdentity != session.tokens.identity || intent.confirmationDeadline <= now() {
            return try await read(id, publishMembership: true)
        }
        if case .terminal = intent.phase { return try await reconcile(await get(id), intent: intent, mayPin: false) }
        try live(intent)
        switch intent.activePredecessor {
        case .subjectRequested: return try await sendCreate(intent)
        case .actorProposed(let proof):
            let request = try validated(await get(id), request: id, expected: intent.request, proof: proof)
            try match(request, intent: intent, mutation: request.summary.status.active)
            if request.summary.status == .countersigned { return try await commit(intent, proof, request) }
            if request.summary.status == .requested || request.summary.status == .proposed { return try await sendProposal(intent, proof) }
            return try await reconcile(request, intent: intent, mayPin: true)
        case .subjectCountersigned(let proof, let event): return try await sendCountersign(intent, proof, event)
        }
    }
    func reconcile(_ request: AccountGroupPendingRequest, intent: Intent, mayPin: Bool) async throws -> AccountDeviceApprovalView {
        try match(request, intent: intent)
        var snapshot: AccountGroupSnapshot?
        if request.summary.status == .committed, let proof = retainedProof(intent) {
            let allowed = mayPin && intent.originalSessionIdentity == session.tokens.identity && intent.confirmationDeadline > now()
            do { snapshot = try await verifiedCommitted(request, proof, mayPin: allowed) }
            catch AccountGroupCheckpointError.missingCheckpoint { return view(request, intent: intent, snapshot: nil) }
        }
        if !request.summary.status.active, !intent.isAcknowledgedTerminal {
            // An unsigned abandoned Create cannot be relabelled committed.
            if request.summary.status != .committed || retainedProof(intent) != nil {
                let terminal = try intent.replacing(phase: .terminal(intent.activePredecessor, .acknowledged(request.summary.status)),
                    acknowledgment: acknowledgment(request))
                _ = try await replace(intent, terminal)
                // Exact-value pruning occurs only after acknowledged terminal reconciliation.
                if request.summary.status != .committed {
                    try await storage { try await configuration.intentStorage.pruneTerminal(scope: terminal.scope, expected: terminal) }
                }
            }
        }
        return view(request, intent: intent, snapshot: snapshot)
    }
    func cancel(_ id: String) async throws -> AccountDeviceApprovalView {
        guard let intent = try await load(id, .subject) else { throw AccountDeviceApprovalError.requestConflict }
        guard intent.originalSessionIdentity == session.tokens.identity else { throw AccountDeviceApprovalError.sessionChanged }
        let abandoned: Intent
        if case .active = intent.phase {
            abandoned = try await replace(intent, intent.replacing(phase: .terminal(intent.activePredecessor, .locallyAbandoned)))
        } else { abandoned = intent }
        let result = try validated(await call { try await pending.cancelGroupJoin(accessToken: token, accountID: account, requestID: id) },
            request: id, expected: intent.request, proof: retainedProof(intent), operation: "cancel")
        return try await reconcile(result, intent: abandoned, mayPin: false)
    }
    func reject(_ id: String) async throws -> AccountDeviceApprovalView {
        let request = try await get(id), events = try await history(request.summary.groupID)
        let snapshot = try await call { try await verifier.accept(history: events, binding: binding, accountID: account,
            groupID: request.summary.groupID, authorization: authorization) }
        guard snapshot.generation == request.summary.generation, member(snapshot, device: device, key: key),
              request.summary.deviceID != device else { throw AccountDeviceApprovalError.invalidHistory }
        let result = try validated(await call { try await pending.rejectGroupJoin(accessToken: token, accountID: account, requestID: id) },
            request: id, expected: context(request.summary), operation: "reject")
        if let intent = try await load(id, .actor) { return try await reconcile(result, intent: intent, mayPin: false) }
        return view(result, intent: nil, snapshot: nil)
    }
    func view(_ request: AccountGroupPendingRequest, intent: Intent?, snapshot: AccountGroupSnapshot?) -> AccountDeviceApprovalView {
        let role: AccountDeviceApprovalView.Role = request.summary.deviceID == device ? .subject :
            (request.draft?.event.actorDeviceID == device ? .actor : .otherMember)
        let phase: AccountDeviceApprovalView.Phase
        switch request.summary.status {
        case .requested: phase = role == .subject ? .waitingForMember : .needsMemberVerification
        case .proposed: phase = role == .subject ? .needsSubjectConfirmation : .waitingForSubject
        case .countersigned: phase = .waitingForActor
        case .committed: phase = snapshot.map { member($0, device: device, key: key) ? .joined : .removed } ?? .verifyingHistory
        case .rejected: phase = .rejected
        case .cancelled: phase = .cancelled
        case .expired: phase = .expired
        case .invalidated: phase = .invalidated
        }
        let proof = retainedProof(intent)
        return .init(summary: request.summary, role: role, phase: phase,
            requestCode: role == .subject ? intent?.request.requestCode : nil,
            memberCode: role == .actor ? proof?.capsule.code : nil, fingerprint: proof?.capsule.fingerprint, snapshot: snapshot)
    }
}
