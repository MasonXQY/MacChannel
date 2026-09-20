import CryptoKit
import Foundation

public enum AccountDeviceApprovalValueError: Error, Equatable { case invalidValue, verificationMismatch, invalidTransition, conflict, capacity, secureStorage }

/// Exact create tuple; no acknowledgment, trust, or consent is implied.
public struct AccountDeviceApprovalRequestContext: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let origin: URL
    public let requestID, accountID, groupID, subjectDeviceID: String
    public let generation: UInt64
    public let subjectPublicKey: Data

    public init(origin: URL, requestID: String, accountID: String, groupID: String, generation: UInt64,
                subjectDeviceID: String, subjectPublicKey: Data) throws {
        guard [requestID, accountID, groupID, subjectDeviceID].allSatisfy(AccountGroupCheckpoint.canonicalUUID),
              generation > 0, generation <= UInt64(Int64.max),
              (try? AccountGroupEvent.deviceID(publicKey: subjectPublicKey)) == subjectDeviceID else {
            throw AccountDeviceApprovalValueError.invalidValue
        }
        self.origin = try AccountSessionBinding(deviceID: UUID(uuidString: subjectDeviceID)!, audience: "approval.context", origin: origin).origin
        self.requestID = requestID; self.accountID = accountID; self.groupID = groupID
        self.generation = generation; self.subjectDeviceID = subjectDeviceID; self.subjectPublicKey = Data(Array(subjectPublicKey))
    }

    public init(origin: URL, summary: AccountGroupPendingSummary) throws {
        try self.init(origin: origin, requestID: summary.requestID, accountID: summary.accountID, groupID: summary.groupID,
            generation: summary.generation, subjectDeviceID: summary.deviceID, subjectPublicKey: summary.publicKey)
    }

    public var requestDigest: Data {
        approvalDigest("dropmesh.account.group.join.request-compare.v1", [Data(origin.absoluteString.utf8), Data(requestID.utf8),
            Data(accountID.utf8), Data(groupID.utf8), Data(String(generation).utf8), Data(subjectDeviceID.utf8), subjectPublicKey])
    }
    public var requestCode: String { "DMJR1-" + approvalHex(requestDigest) }
    public func matchesRequestCode(_ code: String) -> Bool {
        guard code.utf8.count <= 512, code.hasPrefix("DMJR1-") else { return false }
        let body = code.dropFirst(6).utf8.filter { $0 != 32 && $0 != 45 }
        guard body.count == 64, body.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return false }
        return String(decoding: body, as: UTF8.self).uppercased() == approvalHex(requestDigest).replacingOccurrences(of: "-", with: "")
    }
    func matches(_ event: AccountGroupEvent) -> Bool {
        event.action == "approve" && accountID == event.accountID && groupID == event.groupID && generation == event.generation &&
        subjectDeviceID == event.subjectDeviceID && subjectPublicKey == event.subjectPublicKey
    }
    public var description: String { "AccountDeviceApprovalRequestContext(<redacted>)" }
    public var debugDescription: String { description }
}

/// Independent public evidence only. Construction does not attest anchor trust;
/// import does not consent, pin, sign, contact a service, or grant membership.
public struct AccountDeviceApprovalCapsule: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let origin: URL
    public let requestID: String
    public let anchorHash, canonicalPayload: Data
    public let code: String
    public var comparisonDigest: Data {
        approvalDigest("dropmesh.account.group.join.full-compare.v1", [Data(origin.absoluteString.utf8), Data(requestID.utf8), anchorHash, canonicalPayload])
    }
    public var fingerprint: String { approvalHex(comparisonDigest) }

    public init(origin: URL, requestID: String, draft: AccountGroupApprovalDraft, expectedAnchorHash: Data) throws {
        let context = try AccountDeviceApprovalRequestContext(origin: origin, requestID: requestID,
            accountID: draft.event.accountID, groupID: draft.event.groupID, generation: draft.event.generation,
            subjectDeviceID: draft.event.subjectDeviceID, subjectPublicKey: draft.event.subjectPublicKey)
        _ = try AccountGroupApprovalDraft(event: draft.event)
        let payload = try draft.event.canonicalPayload()
        guard expectedAnchorHash.count == 32, payload.count + 32 <= 4096 else { throw AccountDeviceApprovalValueError.invalidValue }
        self.origin = context.origin; self.requestID = requestID
        anchorHash = Data(Array(expectedAnchorHash)); canonicalPayload = payload
        let object = ["purpose": "dropmesh.account.group.join.member-verify.v1", "origin": context.origin.absoluteString,
            "requestID": requestID, "context": (expectedAnchorHash + payload).base64EncodedString()]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 8192 else { throw AccountDeviceApprovalValueError.invalidValue }
        code = "DMJA1:" + data.base64EncodedString()
    }

    public static func parse(_ code: String, expectedRequest: AccountDeviceApprovalRequestContext,
                             expectedDraft: AccountGroupApprovalDraft) throws -> Self {
        do {
            guard code.hasPrefix("DMJA1:"), code.utf8.count <= 6 + 10924 else { throw AccountDeviceApprovalValueError.verificationMismatch }
            let data = try AccountGroupEvent.wireBase64(String(code.dropFirst(6)), bound: 10924)
            let fields = try AccountGroupWireJSON.fields(data, keys: ["purpose", "origin", "requestID", "context"])
            guard fields["purpose"] == "dropmesh.account.group.join.member-verify.v1",
                  fields["origin"] == expectedRequest.origin.absoluteString, fields["requestID"] == expectedRequest.requestID,
                  expectedRequest.matches(expectedDraft.event), let encoded = fields["context"] else { throw AccountDeviceApprovalValueError.verificationMismatch }
            let context = try AccountGroupEvent.wireBase64(encoded, bound: 5464)
            guard context.count > 32, context.count <= 4096,
                  context.dropFirst(32) == (try expectedDraft.event.canonicalPayload()) else { throw AccountDeviceApprovalValueError.verificationMismatch }
            let validated = try Self(origin: expectedRequest.origin, requestID: expectedRequest.requestID, draft: expectedDraft, expectedAnchorHash: Data(context.prefix(32)))
            return Self(validated: validated, importedCode: code)
        } catch { throw AccountDeviceApprovalValueError.verificationMismatch }
    }
    private init(validated: Self, importedCode: String) {
        origin = validated.origin; requestID = validated.requestID
        anchorHash = validated.anchorHash; canonicalPayload = validated.canonicalPayload; code = importedCode
    }
    public var description: String { "AccountDeviceApprovalCapsule(<redacted>)" }
    public var debugDescription: String { description }
}

func approvalDigest(_ domain: String, _ fields: [Data]) -> Data {
    var data = Data(domain.utf8)
    for field in fields {
        var length = UInt64(field.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(field)
    }
    return Data(SHA256.hash(data: data))
}
private func approvalHex(_ data: Data) -> String {
    let hex = data.map { String(format: "%02X", $0) }.joined()
    return stride(from: 0, to: hex.count, by: 4).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return String(hex[start..<hex.index(start, offsetBy: 4)])
    }.joined(separator: "-")
}
