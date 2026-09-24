import CryptoKit
import Darwin
import LocalAuthentication

@main
enum AuditOwnerPreflightMain {
    static func main() {
        let result = AuditPreflight.run(
            Array(CommandLine.arguments.dropFirst()),
            enclave: { SecureEnclave.isAvailable },
            ownerAuthentication: {
                let context = LAContext()
                defer { context.invalidate() }
                return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
            }
        )
        print(result.line)
        exit(result.status)
    }
}
