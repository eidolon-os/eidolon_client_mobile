package live.eidolon.eidolon_client_mobile

import android.util.Base64
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.X509TrustManager

/// A pin that no longer matches, carrying what was actually presented.
///
/// The value travels because the caller's next move depends on it: a Host that
/// rotated its transport key still signs a statement naming the new key, and
/// checking that statement means dialling the key that was just refused. Both
/// values are public — a pin is a digest of a public key — so nothing here is
/// a secret, and without them a mismatch is indistinguishable from reaching a
/// different Host entirely.
internal class SpkiPinMismatchException(
    val expectedPin: String,
    val observedPin: String,
    val observedSubject: String,
) : CertificateException("Host TLS identity does not match its signed endpoint")

internal class PinnedSpkiTrustManager(expected: String) : X509TrustManager {
    private val expectedDigest: ByteArray
    private val expectedPin: String = expected

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
            throw SpkiPinMismatchException(
                expectedPin = expectedPin,
                observedPin = encodePin(digest),
                observedSubject = certificate.subjectX500Principal.name,
            )
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    /// The spelling the pin is stored and compared in, so the two sides of a
    /// mismatch can be read against each other without converting by hand.
    private fun encodePin(digest: ByteArray): String = "sha256:" + Base64.encodeToString(
        digest,
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
    )
}
