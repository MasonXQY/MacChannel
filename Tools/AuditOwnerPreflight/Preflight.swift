struct PreflightResult: Equatable {
    let status: Int32
    let line: String
}

enum AuditPreflight {
    static func run(_ args: [String], enclave: () -> Bool,
                    ownerAuthentication: () -> Bool) -> PreflightResult {
        guard args == ["preflight"] else {
            return PreflightResult(status: 2, line: "AUDIT_PREFLIGHT_BLOCKED:usage")
        }
        guard enclave() else {
            return PreflightResult(status: 2, line: "AUDIT_PREFLIGHT_BLOCKED:secure-enclave")
        }
        guard ownerAuthentication() else {
            return PreflightResult(status: 2, line: "AUDIT_PREFLIGHT_BLOCKED:owner-authentication")
        }
        return PreflightResult(status: 0, line: "AUDIT_PREFLIGHT_CAPABLE_NOT_ENROLLED")
    }
}
