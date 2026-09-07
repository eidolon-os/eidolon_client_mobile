package live.eidolon.eidolon_client_mobile

import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The ES256 encoding conversions, held to `es256-vectors.json`.
 *
 * The valid vector is an end-to-end pin rather than a unit test of one
 * function: a real signature, over the canonical bytes of a real Device
 * Foundation command envelope, verified through the same P1363-to-DER path the
 * Owner Domain descriptor check uses. If either the canonicalisation or the
 * conversion is wrong, it fails.
 *
 * The negative vector is the half that makes the positive one mean something.
 * It reuses the same signature over a document with one integer changed, and it
 * must not verify — which is what proves the signature is bound to the bytes
 * rather than merely being well-formed.
 */
class EcdsaSignatureEncodingTest {
    private val es256 = GoldenFixtures.load("es256-vectors.json")
    private val canonicalVectors = GoldenFixtures.load("canonical-vectors.json")

    private fun vector(id: String): Map<String, Any?> =
        (es256["vectors"] as List<*>)
            .filterIsInstance<Map<String, Any?>>()
            .first { it["vector_id"] == id }

    private fun canonicalDocument(id: String): String =
        (canonicalVectors["vectors"] as List<*>)
            .filterIsInstance<Map<String, Any?>>()
            .first { it["vector_id"] == id }
            .str("canonical_utf8")

    private fun base64Url(value: String): ByteArray =
        Base64.getUrlDecoder().decode(value)

    private fun publicKeyOf(vector: Map<String, Any?>) =
        KeyFactory.getInstance("EC").generatePublic(
            X509EncodedKeySpec(base64Url(vector.str("public_key_spki_base64url"))),
        )

    private fun verifies(vector: Map<String, Any?>, document: String): Boolean {
        val signature = base64Url(vector.str("signature"))
        assertEquals(64, signature.size, "vectors are P1363, not DER")
        val verifier = Signature.getInstance("SHA256withECDSA")
        verifier.initVerify(publicKeyOf(vector))
        verifier.update(document.toByteArray(Charsets.UTF_8))
        return verifier.verify(EcdsaSignatureEncoding.p1363ToDer(signature))
    }

    @Test
    fun `vectors are the encoding this product uses`() {
        assertEquals("ES256", es256.str("signature_algorithm"))
        assertEquals(
            "64-byte-r-concat-s-base64url-no-padding",
            es256.str("signature_encoding"),
        )
    }

    @Test
    fun `the public key in the vector is the key the vector names`() {
        // Pins the SPKI decoding itself. Without this, a wrong decode that
        // happened to produce a valid key would show up only as a confusing
        // signature failure below.
        val vector = vector("DF-ES256-001")
        val spki = base64Url(vector.str("public_key_spki_base64url"))

        val digest = MessageDigest.getInstance("SHA-256").digest(spki)

        assertEquals("sha256:${digest.toHex()}", vector.str("key_id"))
    }

    @Test
    fun `a valid vector signature verifies through the P1363 conversion`() {
        val vector = vector("DF-ES256-001")
        assertEquals(true, vector["valid"])

        assertTrue(verifies(vector, canonicalDocument(vector.str("canonical_vector_id"))))
    }

    @Test
    fun `the mutated payload vector does not verify`() {
        val vector = vector("DF-ES256-NEGATIVE-MUTATED-PAYLOAD")
        assertEquals(false, vector["valid"])

        // The mutation the vector declares, applied to the canonical bytes.
        // Both the old and the new value are single digits in the same member,
        // so the canonical form of the mutated document differs from the
        // original in exactly this one character.
        val original = canonicalDocument(vector.str("canonical_vector_id"))
        val mutated = original.replace("\"proposal_revision\":1", "\"proposal_revision\":2")
        assertTrue(mutated != original, "the declared mutation must actually apply")

        assertFalse(verifies(vector, mutated))
    }

    @Test
    fun `DER and P1363 round-trip through the vector signature`() {
        val signature = base64Url(vector("DF-ES256-001").str("signature"))

        val der = EcdsaSignatureEncoding.p1363ToDer(signature)

        assertContentEquals(signature, EcdsaSignatureEncoding.derToP1363(der))
    }

    @Test
    fun `a component with its high bit set is padded, and unpadded back`() {
        // DER INTEGERs are signed. `r` beginning 0xFF must gain a leading zero
        // on the way out and lose it on the way back; roughly one signature in
        // 256 has this shape, so getting it wrong fails rarely and confusingly.
        val raw = ByteArray(64) { 0x11 }
        raw[0] = 0xFF.toByte()

        val der = EcdsaSignatureEncoding.p1363ToDer(raw)

        assertEquals(0x02, der[2].toInt(), "first component is an INTEGER")
        assertEquals(33, der[3].toInt(), "high bit set means 33 content bytes")
        assertEquals(0x00, der[4].toInt(), "and the first of them is the pad")
        assertContentEquals(raw, EcdsaSignatureEncoding.derToP1363(der))
    }

    @Test
    fun `a component with leading zeroes is re-expanded to full width`() {
        // The other side of the same coin: DER drops leading zeroes, so a short
        // component has to be left-padded back to 32 bytes rather than written
        // at the start of the slot.
        val raw = ByteArray(64) { 0x22 }
        raw[0] = 0x00
        raw[1] = 0x00
        raw[32] = 0x00

        val der = EcdsaSignatureEncoding.p1363ToDer(raw)

        assertEquals(30, der[3].toInt(), "two leading zeroes are not magnitude")
        assertContentEquals(raw, EcdsaSignatureEncoding.derToP1363(der))
    }

    @Test
    fun `a signature the JCA actually produced converts to 64 bytes and back`() {
        // The vector only proves the P1363-to-DER direction, because that is
        // the one verification needs. Signing needs the inverse, and its only
        // real input is whatever the JCA emits — so that is what is fed to it
        // here, repeatedly, because the interesting component shapes appear at
        // random.
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        val document = "canonical document".toByteArray(Charsets.UTF_8)

        repeat(64) {
            val signer = Signature.getInstance("SHA256withECDSA")
            signer.initSign(pair.private)
            signer.update(document)
            val der = signer.sign()

            val p1363 = EcdsaSignatureEncoding.derToP1363(der)
            assertEquals(64, p1363.size)

            val verifier = Signature.getInstance("SHA256withECDSA")
            verifier.initVerify(pair.public)
            verifier.update(document)
            assertTrue(
                verifier.verify(EcdsaSignatureEncoding.p1363ToDer(p1363)),
                "a re-encoded signature must still verify",
            )
        }
    }

    @Test
    fun `malformed encodings are refused`() {
        assertFailsWith<IllegalArgumentException> {
            EcdsaSignatureEncoding.p1363ToDer(ByteArray(63))
        }
        assertFailsWith<IllegalArgumentException> {
            EcdsaSignatureEncoding.derToP1363(byteArrayOf(0x31, 0x00))
        }
        assertFailsWith<IllegalArgumentException> {
            // A SEQUENCE whose declared length does not cover its contents.
            EcdsaSignatureEncoding.derToP1363(byteArrayOf(0x30, 0x08, 0x02, 0x01, 0x01))
        }
    }
}
