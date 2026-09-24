import Darwin

@main
enum PreflightTests {
    static func check(_ condition: Bool) {
        guard condition else {
            print("audit preflight assertion FAIL")
            exit(1)
        }
    }

    static func main() {
        let invalidArguments: [[String]] = [
            [], ["sign"], ["enroll"], ["production"], ["--help"],
            ["PREFLIGHT"], ["preflight "], ["preflight", ""],
            ["preflight", "SENSITIVE_SENTINEL"], ["preflight", "preflight"]
        ]
        for args in invalidArguments {
            var probes = 0
            let result = AuditPreflight.run(args, enclave: {
                probes += 1
                return true
            }, ownerAuthentication: {
                probes += 1
                return true
            })
            check(result == PreflightResult(status: 2, line: "AUDIT_PREFLIGHT_BLOCKED:usage"))
            check(probes == 0)
        }
        for hardware in [true, false] {
            for authentication in [true, false] {
                var calls: [String] = []
                let result = AuditPreflight.run(["preflight"], enclave: {
                    calls.append("hardware")
                    return hardware
                }, ownerAuthentication: {
                    calls.append("authentication")
                    return authentication
                })
                if !hardware {
                    check(result == PreflightResult(status: 2, line: "AUDIT_PREFLIGHT_BLOCKED:secure-enclave"))
                    check(calls == ["hardware"])
                } else if !authentication {
                    check(result == PreflightResult(status: 2, line: "AUDIT_PREFLIGHT_BLOCKED:owner-authentication"))
                    check(calls == ["hardware", "authentication"])
                } else {
                    check(result == PreflightResult(status: 0, line: "AUDIT_PREFLIGHT_CAPABLE_NOT_ENROLLED"))
                    check(calls == ["hardware", "authentication"])
                }
            }
        }
        print("audit preflight tests PASS: 14 cases")
    }
}
