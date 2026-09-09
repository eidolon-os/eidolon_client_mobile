package live.eidolon.eidolon_client_mobile

import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.util.Base64

/**
 * The one-shot key a ClaimGrant is sealed to, for as long as one enrollment is
 * in flight.
 *
 * One slot per virtual Device. The platform owns one holder for each Device
 * scope: two enrollments in flight for a single device instance id is not a case
 * to support, it is a case to notice. Starting a second proposal replaces the
 * first key and orphans the first enrollment, and the orphan then has to be
 * cancelled rather than quietly forgotten.
 *
 * ## Why the key is not persisted
 *
 * It is a secret, and this app's checkpoint store deliberately refuses secrets
 * (Wi-Fi passwords, pairing material, Controller credentials). Writing an HPKE
 * recipient private key to disk to survive a process death would be the first
 * exception to that rule, bought for a window that is normally seconds long:
 * this phone is its own Controller, so it can approve its own proposal
 * immediately and collect the Grant in the same foreground session.
 *
 * ## What that costs, and why it is not a dead end
 *
 * If the process dies between proposing and collecting, the Grant can no longer
 * be opened by anybody, including this phone. That is a real loss and the code
 * says so: [open] refuses with a sentence naming what is missing rather than
 * failing as a bad AEAD tag. The way forward is `admission.cancel-enrollment`
 * and a fresh proposal — an action the Owner can take, not a wait that never
 * ends. An enrollment left in `approvedAwaitingHandoff` with no key is exactly
 * the shape this project keeps finding and refusing to ship: a screen that says
 * "in progress" about something no party can advance.
 */
/**
 * The HPKE application info the ClaimGrant profile derives its key schedule
 * under, byte for byte as the Authority uses it
 * (`hub/admission/crypto.py::seal_claim_grant`).
 *
 * Named rather than inlined because it is a value two implementations must
 * agree on exactly and neither transmits: a disagreement here is not a
 * mismatch anybody can see, it is a bad AEAD tag.
 */
internal val CLAIM_GRANT_HPKE_INFO: ByteArray =
    "eidolon-trust-p256-hpke-v1".toByteArray(Charsets.UTF_8)

internal class HandoffKeyHolder(
    private val random: SecureRandom = SecureRandom(),
    private val generate: () -> HpkeP256.HandoffKeyPair = HpkeP256::generateHandoffKeyPair,
) {
    /** A live handoff key, the handle that addresses it, and its wire id. */
    data class Issued(
        val handle: String,
        val publicKeySpki: String,
        /**
         * `sha256:<hex>` over the SPKI DER, which is how a ClaimGrant envelope
         * names the key it was sealed to (`recipient_handoff_key_id`).
         *
         * Computed here because this is where the bytes are. The rule is the
         * Authority's — `hub/admission/crypto.py::key_id` hashes exactly these
         * bytes after stripping the `p256-spki:` scheme — and a second
         * derivation of it up in Dart would be a rule with two homes over a
         * value whose only job is to be compared.
         */
        val keyId: String,
    )

    class MissingHandoffKey(message: String) : IllegalStateException(message)

    private var handle: String? = null
    private var keyPair: HpkeP256.HandoffKeyPair? = null

    /**
     * Mint a handoff key for one enrollment, replacing any previous one.
     *
     * Replacement is silent here and loud above: the caller is starting a new
     * proposal, which is a deliberate act, and whether the previous enrollment
     * needs cancelling is a question about enrollments rather than about keys.
     */
    fun issue(): Issued {
        val pair = generate()
        val bytes = ByteArray(16).also(random::nextBytes)
        val issuedHandle = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        handle = issuedHandle
        keyPair = pair
        val digest = MessageDigest.getInstance("SHA-256").digest(pair.publicKeySpki)
        return Issued(
            handle = issuedHandle,
            publicKeySpki = "p256-spki:" +
                Base64.getUrlEncoder().withoutPadding().encodeToString(pair.publicKeySpki),
            keyId = "sha256:" + digest.joinToString("") { "%02x".format(it) },
        )
    }

    /**
     * Open a ClaimGrant sealed to the key [handle] addresses.
     *
     * A handle that is not the current one is refused by name. It means one of
     * two things — the app restarted, or a second proposal replaced this key —
     * and both are recoverable by cancelling the enrollment and proposing
     * again. Letting the wrong key through instead would surface as a bad tag,
     * which is indistinguishable from a Grant addressed to another device.
     */
    fun open(
        handle: String,
        encapsulatedKey: ByteArray,
        aad: ByteArray,
        ciphertext: ByteArray,
    ): ByteArray {
        val pair = requireCurrent(handle)
        return HpkeP256.openBase(
            recipientPrivateKey = pair.privateKey,
            recipientPublicKeyUncompressed = pair.publicKeyUncompressed,
            encapsulatedKey = encapsulatedKey,
            // The profile id, as the Authority's key schedule uses it.
            //
            // This was `ByteArray(0)`, with a comment asserting that the
            // profile bound its context through the AAD alone and that passing
            // anything here would "disagree with every other implementation".
            // That was reasoning, not a reading, and it was wrong: `info` is
            // hashed into the key schedule, so an empty one derives a
            // different AES key and every Grant fails with
            // `AEADBadTagException` — the same symptom as a Grant addressed to
            // another device. It took a real-device run to find.
            //
            // `rfc9180-p256-base.json` could not catch it: that vector carries
            // its own `info` and proves the HPKE construction, not which
            // string this profile feeds it.
            info = CLAIM_GRANT_HPKE_INFO,
            aad = aad,
            ciphertext = ciphertext,
        )
    }

    /**
     * Sign an already-canonical document with the handoff private key.
     *
     * Collection requires proving possession of the key a Grant will be sealed
     * to (`CollectClaimGrant.handoff_key_proof`), and the Authority verifies it
     * against the very SPKI the proposal carried
     * (`hub/admission/application.py`). So this key both agrees and signs —
     * that is the contract's design, matched by the firmware, and not a choice
     * this client gets to make differently.
     *
     * Same handle rule as [open], for the same reason: a proof made with a
     * replaced key is refused here, where the cause is known, rather than at
     * the Authority as an opaque `HANDOFF_PROOF_INVALID`.
     */
    fun sign(handle: String, document: ByteArray): String {
        val pair = requireCurrent(handle)
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(pair.privateKey)
        signer.update(document)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(
            EcdsaSignatureEncoding.derToP1363(signer.sign()),
        )
    }

    /**
     * Forget the current key.
     *
     * Called once a Grant is acknowledged, and on an enrollment that was
     * cancelled. A one-shot key that outlives its one shot is just a secret
     * nobody is watching.
     */
    fun discard() {
        handle = null
        keyPair = null
    }

    /** Whether a key is currently held. For a screen that has to say so. */
    fun holdsKey(): Boolean = keyPair != null

    /**
     * The key [handle] addresses, or a refusal that names which way it is gone.
     *
     * The two cases are told apart because their recoveries differ, and both
     * are actions rather than waits.
     */
    private fun requireCurrent(handle: String): HpkeP256.HandoffKeyPair {
        val current = this.handle
        val pair = keyPair
        if (current == null || pair == null) {
            throw MissingHandoffKey(
                "this enrollment's handoff key is gone: it lives only in memory " +
                    "and the app has restarted since the proposal was made. " +
                    "Cancel the enrollment and propose again.",
            )
        }
        if (current != handle) {
            throw MissingHandoffKey(
                "this enrollment's handoff key was replaced by a newer proposal. " +
                    "Cancel the older enrollment and collect the newer one.",
            )
        }
        return pair
    }
}
