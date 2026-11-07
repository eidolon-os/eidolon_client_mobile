// Scratch experiment: which SecTrust policies reject a 99-year leaf.
import Foundation
import Security
import CryptoKit

let dir = CommandLine.arguments[1]
func cert(_ name: String) -> SecCertificate {
    let data = try! Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name).der"))
    return SecCertificateCreateWithData(nil, data as CFData)!
}

func evaluate(_ label: String, _ chain: [SecCertificate], _ policy: SecPolicy, anchors: [SecCertificate]) {
    var trust: SecTrust?
    precondition(SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess)
    SecTrustSetAnchorCertificates(trust!, anchors as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust!, true)
    var error: CFError?
    let ok = SecTrustEvaluateWithError(trust!, &error)
    var details = ""
    if let result = SecTrustCopyResult(trust!) as? [String: Any],
       let d = result["TrustResultDetails"] as? [[String: Any]] {
        details = d.map { $0.keys.sorted().joined(separator: ",") }.filter { !$0.isEmpty }.joined(separator: " | ")
    }
    print("\(label): \(ok ? "TRUSTED" : "REJECTED")" + (ok ? "" : "  code=\(CFErrorGetCode(error!)) failed-checks=[\(details)]"))
    if !ok { print("    \(CFErrorCopyDescription(error!)!)") }
}

let root = cert("root")
let ssl = SecPolicyCreateSSL(true, "eidolon-hub-test.local" as CFString)
let sslNoName = SecPolicyCreateSSL(true, nil)
let basic = SecPolicyCreateBasicX509()

print("== Hub leaf chained to private root (anchor = root only) ==")
for leaf in ["hub825", "hub826", "hub99"] {
    evaluate("SSL(host)    \(leaf)", [cert(leaf), root], ssl, anchors: [root])
    evaluate("SSL(nil)     \(leaf)", [cert(leaf), root], sslNoName, anchors: [root])
    evaluate("BasicX509    \(leaf)", [cert(leaf), root], basic, anchors: [root])
}

print("== Local API self-signed 99y (anchor = the cert itself) ==")
let local = cert("local")
evaluate("SSL(nil)     local", [local], sslNoName, anchors: [local])
evaluate("SSL(ip)      local", [local], SecPolicyCreateSSL(true, "192.168.1.10" as CFString), anchors: [local])
evaluate("BasicX509    local", [local], basic, anchors: [local])

print("== SPKI pin of Local API cert ==")
let key = SecCertificateCopyKey(local)!
let x963 = SecKeyCopyExternalRepresentation(key, nil)! as Data
let spki = try! P256.Signing.PublicKey(x963Representation: x963).derRepresentation
let pin = Data(SHA256.hash(data: spki)).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
let expected = try! String(contentsOfFile: "\(dir)/local.spki", encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
print("x963 bytes=\(x963.count) spki bytes=\(spki.count) pin=sha256:\(pin) matches-openssl=\(pin == expected)")
