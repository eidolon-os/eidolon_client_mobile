package live.eidolon.eidolon_client_mobile

import android.util.Base64
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import java.security.AlgorithmParameters
import java.security.MessageDigest
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec

/** Cryptographic Adapter for the frozen eidolon-trust-p256-hpke-v1 profile. */
internal object OwnerDomainDescriptorVerifier {
    fun verify(
        ownerDomainId: String,
        ownerRootCertificate: String,
        authoritySigningCertificate: String,
        signingKeyId: String,
        trustRootRefs: List<String>,
        signature: String,
        canonicalSigningDocument: String,
    ): Boolean {
        val root = parseCertificate(ownerRootCertificate)
        val authority = parseCertificate(authoritySigningCertificate)
        val rawSignature = base64UrlDecode(signature)

        root.checkValidity()
        authority.checkValidity()
        require(root.basicConstraints >= 0) { "Owner root certificate is not a CA" }
        require(authority.basicConstraints < 0) {
            "Authority signer must be a constrained leaf"
        }
        require(authority.extendedKeyUsage?.contains("1.3.6.1.5.5.7.3.3") == true) {
            "Authority signer is not limited to code signing"
        }
        requireP256(root)
        requireP256(authority)
        authority.verify(root.publicKey)

        val rootKeyId = "sha256:${hex(sha256(root.publicKey.encoded))}"
        val authorityKeyId = "sha256:${hex(sha256(authority.publicKey.encoded))}"
        require(ownerDomainId == "owner-${rootKeyId.removePrefix("sha256:").take(20)}") {
            "Owner Domain ID does not match the Owner root"
        }
        require(rootKeyId in trustRootRefs) {
            "Descriptor does not retain the commissioned Owner root"
        }
        require(signingKeyId == authorityKeyId) {
            "Descriptor signer is not the delegated authority"
        }
        require(rawSignature.size == 64) { "Descriptor signature is not P1363 ES256" }

        val verifier = Signature.getInstance("SHA256withECDSA")
        verifier.initVerify(authority.publicKey)
        verifier.update(canonicalSigningDocument.toByteArray(StandardCharsets.UTF_8))
        require(verifier.verify(EcdsaSignatureEncoding.p1363ToDer(rawSignature))) {
            "Descriptor signature is invalid"
        }
        return true
    }

    private fun parseCertificate(pem: String): X509Certificate =
        CertificateFactory.getInstance("X.509").generateCertificate(
            ByteArrayInputStream(pem.toByteArray(StandardCharsets.US_ASCII)),
        ) as X509Certificate

    private fun requireP256(certificate: X509Certificate) {
        val key = certificate.publicKey as? ECPublicKey
            ?: error("Owner Domain key must be EC")
        val expected = AlgorithmParameters.getInstance("EC").apply {
            init(ECGenParameterSpec("secp256r1"))
        }.getParameterSpec(ECParameterSpec::class.java)
        val actual = key.params
        require(
            actual.curve == expected.curve &&
                actual.generator == expected.generator &&
                actual.order == expected.order &&
                actual.cofactor == expected.cofactor
        ) {
            "Owner Domain key must be P-256"
        }
    }

    private fun base64UrlDecode(value: String): ByteArray = Base64.decode(
        value.replace('-', '+').replace('_', '/') + "=".repeat((4 - value.length % 4) % 4),
        Base64.DEFAULT,
    )

    private fun sha256(value: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(value)

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString(separator = "") { "%02x".format(it) }
}
