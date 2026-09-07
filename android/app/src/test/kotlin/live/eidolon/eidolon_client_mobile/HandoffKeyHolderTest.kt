package live.eidolon.eidolon_client_mobile

import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The handoff key's lifetime, which is the part of this that can hurt.
 *
 * The cryptography is already held to RFC 9180 in `HpkeP256Test`; nothing here
 * re-checks it. What is asserted is what happens when the key is *not* there —
 * because both ways that occurs, a restart and a replacing proposal, would
 * otherwise surface as an unexplained decryption failure, which is the kind of
 * thing a client reports as "still working on it" forever.
 *
 * Sealing is done with the receiver's own key agreement rather than a sender
 * implementation this app does not have and must not grow: HPKE's encapsulation
 * and decapsulation agree by construction — `DH(skE, pkR)` is `DH(skR, pkE)` —
 * and that agreement is what the RFC vector already proves.
 */
class HandoffKeyHolderTest {
    private val recipient = HpkeP256.generateHandoffKeyPair()

    /** A holder whose key is one this test can also seal to. */
    private fun holder() = HandoffKeyHolder(generate = { recipient })

    /** A ClaimGrant as a Hub would have sealed it to [recipient]. */
    private fun seal(aad: ByteArray, plaintext: ByteArray): Pair<ByteArray, ByteArray> {
        val ephemeral = HpkeP256.generateHandoffKeyPair()
        val enc = ephemeral.publicKeyUncompressed
        val sharedSecret =
            HpkeP256.decapsulate(recipient.privateKey, enc, recipient.publicKeyUncompressed)
        // Empty info: the ClaimGrant profile binds its context through the AAD.
        val schedule = HpkeP256.keySchedule(sharedSecret, ByteArray(0))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(schedule.key, "AES"),
            GCMParameterSpec(128, HpkeP256.nonceFor(schedule.baseNonce, 0)),
        )
        cipher.updateAAD(aad)
        return enc to cipher.doFinal(plaintext)
    }

    @Test
    fun `an issued key is addressed by its handle and published as SPKI`() {
        val holder = holder()

        val issued = holder.issue()

        assertTrue(issued.handle.isNotEmpty())
        // The Admission schema's `handoff_key.public_key` pattern is
        // `^p256-spki:[A-Za-z0-9_-]+$`; anything else is refused on arrival.
        assertTrue(issued.publicKeySpki.startsWith("p256-spki:"))
        assertTrue(
            Regex("^p256-spki:[A-Za-z0-9_-]+$").matches(issued.publicKeySpki),
            "base64url without padding, as the contract states it",
        )
        assertTrue(holder.holdsKey())
    }

    @Test
    fun `the key id is the digest a Grant envelope will name`() {
        // The Authority derives `recipient_handoff_key_id` by hashing exactly
        // the SPKI bytes after stripping the scheme
        // (`hub/admission/crypto.py::key_id`). Recomputed here from the
        // published wire value, so this asserts the rule rather than the code.
        val issued = holder().issue()
        val encoded = issued.publicKeySpki.removePrefix("p256-spki:")
        val spki = Base64.getUrlDecoder().decode(encoded)

        val digest = MessageDigest.getInstance("SHA-256").digest(spki)

        assertEquals("sha256:" + digest.joinToString("") { "%02x".format(it) }, issued.keyId)
        assertTrue(Regex("^sha256:[0-9a-f]{64}$").matches(issued.keyId))
    }

    @Test
    fun `each proposal gets its own key and handle`() {
        val holder = HandoffKeyHolder()

        val first = holder.issue()
        val second = holder.issue()

        assertTrue(first.handle != second.handle)
        assertTrue(first.publicKeySpki != second.publicKeySpki)
    }

    @Test
    fun `a Grant sealed to the issued key opens`() {
        val holder = holder()
        val issued = holder.issue()
        val aad = "claim-grant-aad".toByteArray()
        val plaintext = "claim-grant-fixture-v1".toByteArray()
        val (enc, ciphertext) = seal(aad, plaintext)

        val opened = holder.open(issued.handle, enc, aad, ciphertext)

        assertContentEquals(plaintext, opened)
    }

    @Test
    fun `a Grant whose AAD does not match is refused`() {
        val holder = holder()
        val issued = holder.issue()
        val (enc, ciphertext) = seal("one-owner-domain".toByteArray(), "grant".toByteArray())

        // The AAD is where the Owner Domain, the claim generation and the trust
        // epoch are bound. A Grant for another one must not open.
        assertFailsWith<AEADBadTagException> {
            holder.open(issued.handle, enc, "another-owner-domain".toByteArray(), ciphertext)
        }
    }

    @Test
    fun `a collection proof verifies against the published handoff key`() {
        // The Authority verifies `handoff_key_proof` against the very SPKI the
        // proposal carried, so the check here is the same one it will make:
        // take the published key, and see whether the proof stands up.
        val holder = holder()
        val issued = holder.issue()
        val document = "{\"contract\":\"claim-grant-collection\"}".toByteArray()

        val proof = holder.sign(issued.handle, document)

        val spki = Base64.getUrlDecoder().decode(issued.publicKeySpki.removePrefix("p256-spki:"))
        val verifier = Signature.getInstance("SHA256withECDSA")
        verifier.initVerify(
            KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(spki)),
        )
        verifier.update(document)
        // P1363 on the wire, DER for the JCA — the same conversion the
        // descriptor check uses, held to the ES256 vectors elsewhere.
        val raw = Base64.getUrlDecoder().decode(proof)
        assertEquals(64, raw.size, "the contract states 64-byte r||s")
        assertTrue(verifier.verify(EcdsaSignatureEncoding.p1363ToDer(raw)))
    }

    @Test
    fun `a proof made with a replaced key is refused before it is sent`() {
        val holder = HandoffKeyHolder()
        val stale = holder.issue()
        holder.issue()

        // Refused here, where the cause is known, rather than by the Authority
        // as an opaque HANDOFF_PROOF_INVALID that names nothing recoverable.
        assertFailsWith<HandoffKeyHolder.MissingHandoffKey> {
            holder.sign(stale.handle, "document".toByteArray())
        }
    }

    @Test
    fun `a handle from a replaced proposal is refused by name`() {
        val holder = HandoffKeyHolder()
        val stale = holder.issue()
        holder.issue()

        val error =
            assertFailsWith<HandoffKeyHolder.MissingHandoffKey> {
                holder.open(stale.handle, ByteArray(65), ByteArray(0), ByteArray(16))
            }

        // The message names the recovery, because there is one. A bad-tag
        // exception here would read as "the Grant is wrong" and send the reader
        // looking in the wrong place entirely.
        assertTrue(error.message!!.contains("replaced"))
        assertTrue(error.message!!.contains("Cancel"))
    }

    @Test
    fun `opening after a restart says what is missing and what to do`() {
        // A fresh holder is what a relaunched process has: the key lived only
        // in memory, and no amount of retrying brings it back.
        val holder = HandoffKeyHolder()

        val error =
            assertFailsWith<HandoffKeyHolder.MissingHandoffKey> {
                holder.open("some-handle", ByteArray(65), ByteArray(0), ByteArray(16))
            }

        assertTrue(error.message!!.contains("restarted"))
        assertTrue(error.message!!.contains("propose again"))
        assertFalse(holder.holdsKey())
    }

    @Test
    fun `a discarded key is gone`() {
        val holder = holder()
        val issued = holder.issue()

        holder.discard()

        assertFalse(holder.holdsKey())
        assertFailsWith<HandoffKeyHolder.MissingHandoffKey> {
            holder.open(issued.handle, ByteArray(65), ByteArray(0), ByteArray(16))
        }
    }

    @Test
    fun `handles do not repeat across issues`() {
        val holder = HandoffKeyHolder()
        val seen = mutableSetOf<String>()

        repeat(32) { seen += holder.issue().handle }

        assertEquals(32, seen.size)
    }
}
