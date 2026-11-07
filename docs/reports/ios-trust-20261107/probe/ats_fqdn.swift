// Scratch experiment: with ATS active, does a delegate override for an FQDN
// still fail (-9802) even when the app's own evaluation trusts the cert?
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

enum Mode { case none, ownerRootModifyTrust, ownerRootSeparateTrust, spkiPin, sslRootAnchorForce }

final class Delegate: NSObject, URLSessionDelegate {
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        FileHandle.standardError.write("    [delegate called host=\(challenge.protectionSpace.host)]\n".data(using: .utf8)!)
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
        case .sslRootAnchorForce:
            SecTrustSetAnchorCertificates(trust, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            let ok = SecTrustEvaluateWithError(trust, nil)
            FileHandle.standardError.write("    [app-side SSL+root verdict=\(ok), returning useCredential anyway]\n".data(using: .utf8)!)
            completionHandler(.useCredential, URLCredential(trust: trust))
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

func describe(_ error: Error) -> String {
    let e = error as NSError
    let stream = e.userInfo["_kCFStreamErrorCodeKey"].map { " stream=\($0)" } ?? ""
    let under = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { " underlying=\($0.domain)/\($0.code)" } ?? ""
    return "FAILED \(e.code)\(stream)\(under)"
}
func get(_ label: String, _ url: String, _ mode: Mode?) {
    let done = DispatchSemaphore(value: 0)
    let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
    let session = URLSession(configuration: config, delegate: mode.map { Delegate($0) }, delegateQueue: nil)
    session.dataTask(with: URL(string: url)!) { _, response, error in
        print("\(label): " + ((response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? describe(error!)))
        done.signal()
    }.resume()
    done.wait(); session.invalidateAndCancel()
}
let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any] ?? [:]
print("ATS dict: \(ats)")
for (name, port) in [("nip825", 18444), ("nip99 ", 18443)] {
    get("https FQDN \(name) SSL(host) + root anchor on challenge trust", "https://127.0.0.1.nip.io:\(port)/", .sslRootAnchorForce)
    get("https FQDN \(name) BasicX509 + root on challenge trust     ", "https://127.0.0.1.nip.io:\(port)/", .ownerRootModifyTrust)
}
