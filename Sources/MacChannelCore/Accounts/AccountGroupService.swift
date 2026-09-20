import Foundation

public protocol AccountGroupService: Sendable {
    func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent]
}

public enum AccountGroupServiceError: Error, Equatable, Sendable { case changedHead }

extension AccountServiceClient: AccountGroupService {
    public func groupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] {
        guard Self.validToken(accessToken), AccountGroupPage.validGroupID(groupID) else {
            throw AccountServiceError.invalidRequest
        }
        for attempt in 0..<3 {
            do { return try await collectGroupHistory(accessToken: accessToken, groupID: groupID) }
            catch AccountGroupServiceError.changedHead {
                try Task.checkCancellation()
                if attempt == 2 { throw AccountGroupServiceError.changedHead }
            }
        }
        throw AccountGroupServiceError.changedHead
    }

    private func collectGroupHistory(accessToken: String, groupID: String) async throws -> [AccountGroupEvent] {
        var history: [AccountGroupEvent] = []
        var header: AccountGroupPage?
        var previous = Data()
        for _ in 0..<512 {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try await send(path: "/v1/account/group/events", fields: [
                    "purpose": "dropmesh.account.group.events.v1", "audience": audience,
                    "accessToken": accessToken, "groupID": groupID,
                    "afterSequence": String(history.count),
                    "expectedHeadHash": header?.headHash.base64EncodedString() ?? "",
                ], requestDate: requestDate())
            } catch { try Task.checkCancellation(); throw error }
            try Task.checkCancellation()
            let page = try AccountGroupPage(data: data)
            guard page.groupID == groupID, page.afterSequence == UInt64(history.count),
                  page.nextSequence == page.afterSequence + UInt64(page.events.count),
                  page.nextSequence <= page.headSequence,
                  page.hasMore == (page.nextSequence < page.headSequence), !page.events.isEmpty else {
                throw AccountServiceError.invalidResponse
            }
            if let header {
                guard page.generation == header.generation, page.headSequence == header.headSequence,
                      page.headHash == header.headHash else { throw AccountServiceError.invalidResponse }
            } else { header = page }
            for event in page.events {
                guard event.groupID == groupID, event.generation == page.generation,
                      event.sequence == UInt64(history.count + 1), event.previousHash == previous,
                      history.first.map({ $0.accountID == event.accountID }) ?? true else {
                    throw AccountServiceError.invalidResponse
                }
                do { previous = try event.digest() }
                catch { throw AccountServiceError.invalidResponse }
                history.append(event)
            }
            if !page.hasMore {
                guard previous == page.headHash, UInt64(history.count) == page.headSequence else {
                    throw AccountServiceError.invalidResponse
                }
                try Task.checkCancellation()
                return history
            }
        }
        throw AccountServiceError.invalidResponse
    }
}
