#!/usr/bin/env swift
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: verify-apple-provisioning-profile.swift input output")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let message: Data
do {
    message = try Data(contentsOf: inputURL, options: .mappedIfSafe)
} catch {
    fail("unable to read provisioning profile")
}

var decoder: CMSDecoder?
guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
    fail("unable to create CMS decoder")
}
let updateStatus = message.withUnsafeBytes { bytes in
    CMSDecoderUpdateMessage(decoder, bytes.baseAddress!, message.count)
}
guard updateStatus == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
    fail("provisioning profile is not valid CMS")
}

let policy = SecPolicyCreateBasicX509()
var signerStatus = CMSSignerStatus.unsigned
var trust: SecTrust?
var trustResult = OSStatus(errSecSuccess)
guard CMSDecoderCopySignerStatus(decoder, 0, policy, true, &signerStatus, &trust, &trustResult) == errSecSuccess,
      signerStatus == .valid,
      trustResult == errSecSuccess,
      let trust else {
    fail("CMS signature or signer trust is invalid")
}

var signerCertificate: SecCertificate?
guard CMSDecoderCopySignerCert(decoder, 0, &signerCertificate) == errSecSuccess,
      let signerCertificate,
      let signerSummary = SecCertificateCopySubjectSummary(signerCertificate) as String?,
      signerSummary.contains("Provisioning Profile Signing") else {
    fail("CMS signer is not an Apple provisioning-profile signer")
}

guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let root = chain.last else {
    fail("CMS signer trust chain is unavailable")
}
var systemAnchorsReference: CFArray?
guard SecTrustCopyAnchorCertificates(&systemAnchorsReference) == errSecSuccess,
      let systemAnchors = systemAnchorsReference as? [SecCertificate] else {
    fail("system trust anchors are unavailable")
}
let rootData = SecCertificateCopyData(root) as Data
let isSystemAppleRoot = systemAnchors.contains { anchor in
    guard SecCertificateCopyData(anchor) as Data == rootData,
          let summary = SecCertificateCopySubjectSummary(anchor) as String? else { return false }
    return summary == "Apple Root CA" || summary.hasPrefix("Apple Root CA - ")
}
guard isSystemAppleRoot else {
    fail("CMS signer is not anchored to an Apple system root")
}

var contentReference: CFData?
guard CMSDecoderCopyContent(decoder, &contentReference) == errSecSuccess,
      let content = contentReference as Data? else {
    fail("verified CMS payload is unavailable")
}
do {
    try content.write(to: outputURL, options: .atomic)
} catch {
    fail("unable to write verified provisioning-profile payload")
}
