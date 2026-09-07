package live.eidolon.eidolon_client_mobile

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import javax.crypto.AEADBadTagException

/**
 * The HPKE receiver, held to `rfc9180-p256-base.json` step by step.
 *
 * Every intermediate is asserted separately on purpose. A key schedule that is
 * wrong in one label produces a key that is wrong in every byte, and the only
 * symptom at the end is a bad GCM tag — which is indistinguishable from a Grant
 * addressed to somebody else. Asserting `shared_secret`, then
 * `key_schedule_context`, then `key` and `base_nonce`, means a mistake names
 * the line that made it.
 *
 * The vector is RFC 9180 Appendix A.3.1, which is the suite this product's
 * ClaimGrant profile (`eidolon-trust-p256-hpke-v1`) uses: DHKEM(P-256,
 * HKDF-SHA256) / HKDF-SHA256 / AES-128-GCM.
 */
class HpkeP256Test {
    private val vector = GoldenFixtures.load("rfc9180-p256-base.json")

    private val recipientPrivate = HpkeP256.privateKeyFromScalar(vector.bytes("skRm"))
    private val recipientPublic = vector.bytes("pkRm")
    private val encapsulated = vector.bytes("enc")
    private val info = vector.bytes("info")

    @Test
    fun `vector is the suite this product uses`() {
        // If the SDK ever re-pins this file to another suite, the code below is
        // not merely failing — it is answering a question nobody asked.
        assertEquals("RFC9180-A.3.1-BASE", vector.str("vector_id"))
        assertEquals(0L, vector.long("mode"), "base mode")
        assertEquals(16L, vector.long("kem_id"), "DHKEM(P-256, HKDF-SHA256)")
        assertEquals(1L, vector.long("kdf_id"), "HKDF-SHA256")
        assertEquals(1L, vector.long("aead_id"), "AES-128-GCM")
    }

    @Test
    fun `decapsulation reproduces the shared secret`() {
        val sharedSecret =
            HpkeP256.decapsulate(recipientPrivate, encapsulated, recipientPublic)

        assertEquals(vector.str("shared_secret"), sharedSecret.toHex())
    }

    @Test
    fun `key schedule reproduces every derived value`() {
        val sharedSecret =
            HpkeP256.decapsulate(recipientPrivate, encapsulated, recipientPublic)

        val schedule = HpkeP256.keySchedule(sharedSecret, info)

        assertEquals(vector.str("key_schedule_context"), schedule.keyScheduleContext.toHex())
        assertEquals(vector.str("secret"), schedule.secret.toHex())
        assertEquals(vector.str("key"), schedule.key.toHex())
        assertEquals(vector.str("base_nonce"), schedule.baseNonce.toHex())
        assertEquals(vector.str("exporter_secret"), schedule.exporterSecret.toHex())
    }

    @Test
    fun `sealed message opens to the vector plaintext`() {
        val encryption = vector.obj("encryption")

        val plaintext =
            HpkeP256.openBase(
                recipientPrivateKey = recipientPrivate,
                recipientPublicKeyUncompressed = recipientPublic,
                encapsulatedKey = encapsulated,
                info = info,
                aad = hex(encryption.str("aad")),
                ciphertext = hex(encryption.str("ciphertext")),
            )

        assertEquals(encryption.str("plaintext"), plaintext.toHex())
    }

    @Test
    fun `nonce for a sequence number matches the vector`() {
        val encryption = vector.obj("encryption")
        val schedule =
            HpkeP256.keySchedule(
                HpkeP256.decapsulate(recipientPrivate, encapsulated, recipientPublic),
                info,
            )

        val nonce = HpkeP256.nonceFor(schedule.baseNonce, encryption.long("sequence_number"))

        assertEquals(encryption.str("nonce"), nonce.toHex())
    }

    @Test
    fun `sequence numbers past the first are still XORed into the nonce`() {
        // The vector only exercises sequence 0, where the nonce is the base
        // nonce and a missing XOR is invisible. A ClaimGrant is a single
        // message, so this path is unused today — which is exactly why it
        // needs a test rather than a reader's confidence.
        val base = hex("4e0bc5018beba4bf004cca59")

        assertEquals("4e0bc5018beba4bf004cca58", HpkeP256.nonceFor(base, 1).toHex())
        assertEquals("4e0bc5018beba4bf004ccb59", HpkeP256.nonceFor(base, 256).toHex())
    }

    @Test
    fun `a tampered aad refuses to open`() {
        val encryption = vector.obj("encryption")
        val aad = hex(encryption.str("aad"))
        aad[0] = (aad[0].toInt() xor 0x01).toByte()

        // Not a wrong answer, not an empty answer: a refusal. The AAD is what
        // binds a Grant to one Owner Domain, one claim generation and one trust
        // epoch, so a Grant whose AAD does not match must not travel further.
        assertFailsWith<AEADBadTagException> {
            HpkeP256.openBase(
                recipientPrivateKey = recipientPrivate,
                recipientPublicKeyUncompressed = recipientPublic,
                encapsulatedKey = encapsulated,
                info = info,
                aad = aad,
                ciphertext = hex(encryption.str("ciphertext")),
            )
        }
    }

    @Test
    fun `another recipient key does not open the message`() {
        val other = HpkeP256.generateHandoffKeyPair()
        val encryption = vector.obj("encryption")

        assertFailsWith<AEADBadTagException> {
            HpkeP256.openBase(
                recipientPrivateKey = other.privateKey,
                recipientPublicKeyUncompressed = other.publicKeyUncompressed,
                encapsulatedKey = encapsulated,
                info = info,
                aad = hex(encryption.str("aad")),
                ciphertext = hex(encryption.str("ciphertext")),
            )
        }
    }

    @Test
    fun `generated handoff key pair is a usable P-256 recipient`() {
        val pair = HpkeP256.generateHandoffKeyPair()

        assertEquals(65, pair.publicKeyUncompressed.size)
        assertEquals(0x04.toByte(), pair.publicKeyUncompressed[0])
        // SPKI is what the Admission contract carries in `handoff_key`; the raw
        // point is what the KEM hashes into `kem_context`. Both are needed and
        // neither is derivable from the other without EC arithmetic this code
        // deliberately does not implement.
        assertTrue(pair.publicKeySpki.size > pair.publicKeyUncompressed.size)
        assertContentEquals(
            pair.publicKeyUncompressed,
            pair.publicKeySpki.copyOfRange(
                pair.publicKeySpki.size - 65,
                pair.publicKeySpki.size,
            ),
            "the uncompressed point is the tail of the SPKI encoding",
        )
    }

    @Test
    fun `an encapsulated key that is not an uncompressed point is refused`() {
        assertFailsWith<IllegalArgumentException> {
            HpkeP256.publicKeyFromUncompressed(ByteArray(65))
        }
        assertFailsWith<IllegalArgumentException> {
            HpkeP256.publicKeyFromUncompressed(byteArrayOf(0x04))
        }
    }
}
