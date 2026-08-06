package live.eidolon.eidolon_client_mobile

import android.util.Base64
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.X509TrustManager

internal class PinnedSpkiTrustManager(expected: String) : X509TrustManager {
    private val expectedDigest: ByteArray

    init {
        require(Regex("^sha256:[A-Za-z0-9_-]{43}$").matches(expected)) {
            "Host TLS SPKI fingerprint is invalid"
        }
        expectedDigest = Base64.decode(
            expected.removePrefix("sha256:"),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
        require(expectedDigest.size == 32) { "Host TLS SPKI fingerprint is invalid" }
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        throw CertificateException("Client certificates are not accepted")
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        val certificate = chain?.firstOrNull()
            ?: throw CertificateException("Host TLS certificate is missing")
        certificate.checkValidity()
        val digest = MessageDigest.getInstance("SHA-256").digest(certificate.publicKey.encoded)
        if (!MessageDigest.isEqual(digest, expectedDigest)) {
            throw CertificateException("Host TLS identity does not match its signed endpoint")
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}
