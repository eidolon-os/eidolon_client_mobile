// Scratch experiment: does URLSession / Network.framework accept a 99-year
// cert once the app's own evaluation (BasicX509 + anchor, or SPKI pin) passes?
import Foundation
import Security
import CryptoKit
import Network

let dir = CommandLine.arguments[1]
func cert(_ name: String) -> SecCertificate {
    let data = try! Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name).der"))
    return SecCertificateCreateWithData(nil, data as CFData)!
}
let root = cert("root")
let expectedPin = try! String(contentsOfFile: "\(dir)/local.spki", encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)

func spkiPin(_ certificate: SecCertificate) -> String {
    let x963 = SecKeyCopyExternalRepresentation(SecCertificateCopyKey(certificate)!, nil)! as Data
    let spki = try! P256.Signing.PublicKey(x963Representation: x963).derRepresentation
    return Data(SHA256.hash(data: spki)).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

enum Mode { case none, ownerRootModifyTrust, ownerRootSeparateTrust, spkiPin }

final class Delegate: NSObject, URLSessionDelegate {
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        switch mode {
        case .none:
            completionHandler(.performDefaultHandling, nil)
        case .ownerRootModifyTrust:
            SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(trust, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            let ok = SecTrustEvaluateWithError(trust, nil)
            completionHandler(ok ? .useCredential : .cancelAuthenticationChallenge, ok ? URLCredential(trust: trust) : nil)
        case .ownerRootSeparateTrust:
            // Evaluate a copy; hand back the untouched (SSL-policy) trust.
            let chain = SecTrustCopyCertificateChain(trust)! as! [SecCertificate]
            var copy: SecTrust?
            SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &copy)
            SecTrustSetAnchorCertificates(copy!, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(copy!, true)
            let ok = SecTrustEvaluateWithError(copy!, nil)
            completionHandler(ok ? .useCredential : .cancelAuthenticationChallenge, ok ? URLCredential(trust: trust) : nil)
        case .spkiPin:
            let leaf = (SecTrustCopyCertificateChain(trust)! as! [SecCertificate])[0]
            let ok = spkiPin(leaf) == expectedPin
            completionHandler(ok ? .useCredential : .cancelAuthenticationChallenge, ok ? URLCredential(trust: trust) : nil)
        }
    }
}

func fetch(_ label: String, _ url: String, _ mode: Mode) {
    let done = DispatchSemaphore(value: 0)
    let session = URLSession(configuration: .ephemeral, delegate: Delegate(mode), delegateQueue: nil)
    session.dataTask(with: URL(string: url)!) { data, response, error in
        if let http = response as? HTTPURLResponse {
            print("\(label): HTTP \(http.statusCode) bytes=\(data?.count ?? 0)")
        } else {
            let e = error! as NSError
            print("\(label): FAILED \(e.domain) \(e.code) \(e.localizedDescription)")
        }
        done.signal()
    }.resume()
    done.wait()
    session.invalidateAndCancel()
}

print("== URLSession ==")
fetch("hub99   no delegate override        ", "https://127.0.0.1:18443/", .none)
fetch("hub99   BasicX509 on challenge trust ", "https://127.0.0.1:18443/", .ownerRootModifyTrust)
fetch("hub99   BasicX509 on a copy, return original trust", "https://127.0.0.1:18443/", .ownerRootSeparateTrust)
fetch("local99 SPKI pin, return original trust", "https://127.0.0.1:19002/", .spkiPin)

print("== Network.framework verify block ==")
func nwGet(_ label: String, port: UInt16, serverName: String?, verify: @escaping (SecTrust) -> Bool) {
    let tls = NWProtocolTLS.Options()
    let sec = tls.securityProtocolOptions
    if let serverName { sec_protocol_options_set_tls_server_name(sec, serverName) }
    sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
        complete(verify(sec_trust_copy_ref(secTrust).takeRetainedValue()))
    }, DispatchQueue.global())
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: tls))
    let done = DispatchSemaphore(value: 0)
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            connection.send(content: "GET / HTTP/1.0\r\n\r\n".data(using: .ascii), completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                let line = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first ?? ""
                print("\(label): ready, first line: \(line)")
                done.signal()
            }
        case .failed(let error), .waiting(let error):
            print("\(label): \(error)")
            done.signal()
        default: break
        }
    }
    connection.start(queue: .global())
    _ = done.wait(timeout: .now() + 10)
    connection.cancel()
}
nwGet("local99 SPKI pin        ", port: 19002, serverName: nil) { trust in
    spkiPin((SecTrustCopyCertificateChain(trust)! as! [SecCertificate])[0]) == expectedPin
}
nwGet("hub99   BasicX509+root  ", port: 18443, serverName: "eidolon-hub-test.local") { trust in
    SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
    SecTrustSetAnchorCertificates(trust, [root] as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    return SecTrustEvaluateWithError(trust, nil)
}
nwGet("hub99   SSL(host)+root  ", port: 18443, serverName: "eidolon-hub-test.local") { trust in
    SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "eidolon-hub-test.local" as CFString))
    SecTrustSetAnchorCertificates(trust, [root] as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    return SecTrustEvaluateWithError(trust, nil)
}
