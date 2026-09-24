import Darwin
import Foundation
import LocalAuthentication
import Security

private struct CheckFailure: Error {}
private final class FakeKeychain: AuditKeychainOperations {
    var queries: [[String: Any]] = []
    var readStatus = errSecItemNotFound
    var readBytes: Data?
    var addStatus = errSecSuccess
    var noInteraction = false
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        noInteraction = (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        queries.append(query); return (readStatus, readBytes)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        noInteraction = (attributes[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        queries.append(attributes); return addStatus
    }
}
@main
enum NativeAuditVaultTests {
    static func check(_ condition: Bool, line: UInt = #line) throws {
        if !condition { print("native vault assertion line \(line)"); throw CheckFailure() }
    }
    static func main() throws {
        var count = 0
        func test(_ label: String, _ body: () throws -> Void) {
            do { try body(); count += 1 } catch {
                print("native vault test FAIL: \(label)")
                exit(1)
            }
        }
        for slot in [AuditVaultSlot.identity, .revoked] {
            test("scoped read with no interaction") {
                let fake = FakeKeychain()
                let value = try NativeAuditVaultStore(operations: fake).read(slot)
                try check(value == nil && fake.queries.count == 1)
                let query = fake.queries[0]
                try check(query[kSecAttrService as String] as? String == "com.zensystech.dropmesh.audit-owner.v1")
                try check(query[kSecAttrAccount as String] as? String == slot.rawValue)
                try check(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
                try check(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
                try check(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
                try check(query[kSecAttrSynchronizable as String] as? Bool == false)
                try check(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                try check(fake.noInteraction)
            }
        }
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecParam] {
            test("read errors are unavailable not absence") {
                let fake = FakeKeychain(); fake.readStatus = status
                do { _ = try NativeAuditVaultStore(operations: fake).read(.identity); throw CheckFailure() }
                catch AuditVaultFailure.unavailable {}
            }
        }
        test("missing returned data is unavailable") {
            let fake = FakeKeychain(); fake.readStatus = errSecSuccess
            do { _ = try NativeAuditVaultStore(operations: fake).read(.identity); throw CheckFailure() }
            catch AuditVaultFailure.unavailable {}
        }
        test("add tombstone scoped and non-synchronizing") {
            let fake = FakeKeychain()
            try NativeAuditVaultStore(operations: fake).add(.revoked, bytes: Data("DMAUDIT-REVOKED-1".utf8))
            let query = fake.queries[0]
            try check(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            try check(query[kSecAttrSynchronizable as String] as? Bool == false)
            try check(query[kSecAttrAccount as String] as? String == "revoked")
            try check(query[kSecValueData as String] as? Data == Data("DMAUDIT-REVOKED-1".utf8))
        }
        test("duplicate add is never an update") {
            let fake = FakeKeychain(); fake.addStatus = errSecDuplicateItem
            do { try NativeAuditVaultStore(operations: fake).add(.revoked, bytes: Data("DMAUDIT-REVOKED-1".utf8)); throw CheckFailure() }
            catch AuditVaultFailure.alreadyExists {}
            try check(fake.queries.count == 1)
        }
        test("invalid tombstone never calls system") {
            let fake = FakeKeychain()
            do { try NativeAuditVaultStore(operations: fake).add(.revoked, bytes: Data([0])); throw CheckFailure() }
            catch AuditVaultFailure.invalidRecord {}
            try check(fake.queries.isEmpty)
        }
        test("access control object can be constructed without keys") { _ = try AuditNativeKeyGenerator.makeAccessControl() }
        print("native vault parameter tests PASS: \(count) cases (no Keychain operations)")
    }
}
