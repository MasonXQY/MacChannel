import Foundation
@main struct RecoveryCheck {
 static func main() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  var calls = 0
  try OwnerApprovedReinstallRecovery.run(directory: root, approved: false) { calls += 1 }
  precondition(calls == 0)
  let trust = root.appendingPathComponent("trust.json")
  try Data("preserve".utf8).write(to: trust)
  do { try OwnerApprovedReinstallRecovery.run(directory: root, approved: true) { calls += 1 }; fatalError("Must refuse existing trust") } catch {}
  precondition(calls == 0 && FileManager.default.fileExists(atPath: trust.path))
  try FileManager.default.removeItem(at: trust)
  let received = root.appendingPathComponent("received.txt")
  try Data("keep".utf8).write(to: received)
  try OwnerApprovedReinstallRecovery.run(directory: root, approved: true) { calls += 1 }
  try OwnerApprovedReinstallRecovery.run(directory: root, approved: true) { calls += 1 }
  precondition(calls == 1)
  let remaining = try String(contentsOf: received, encoding: .utf8)
  precondition(remaining == "keep")
  print("PASS recovery approval, existing-trust refusal, once-only and file preservation")
 }
}
