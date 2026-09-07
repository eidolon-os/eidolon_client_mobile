package live.eidolon.eidolon_client_mobile

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The receiving half of HPKE base mode, for the one suite this product uses:
 * `DHKEM(P-256, HKDF-SHA256)` / `HKDF-SHA256` / `AES-128-GCM`
 * (`eidolon-trust-p256-hpke-v1`).
 *
 * Why this is here rather than in Dart: pure-Dart P-256 ECDH does not exist.
 * `package:cryptography`'s `DartEcdh.newKeyPair()` throws `UnimplementedError`
 * for every NIST curve, so the key agreement has to happen on a platform that
 * has one. The JCA does, at `minSdk` — `KeyAgreement("ECDH")` over a software
 * key pair needs no Keystore, and only Keystore-backed ECDH requires API 31.
 *
 * Why the handoff key is deliberately *not* in the Android Keystore: it is
 * one-shot, generated per enrollment and discarded once the ClaimGrant is open.
 * A Keystore key would buy nothing here and would cost the `minSdk` this app
 * ships (`PURPOSE_AGREE_KEY` is API 31). The operational key — the one whose
 * SPKI this device's identity is derived from, and which signs — stays in the
 * Keystore where it belongs. These are two different keys with two different
 * lifetimes, and conflating them is how a per-enrollment secret becomes
 * permanent.
 *
 * No Android imports: every step is held to `rfc9180-p256-base.json` by a JVM
 * unit test, and a step that could only run on a device could only be checked
 * on a device. The intermediates are exposed for the same reason — a wrong
 * key schedule should fail at the line that computed it, not as an opaque
 * "decryption failed" against a live Host.
 */
object HpkeP256 {
    private const val KEM_ID = 0x0010
    private const val KDF_ID = 0x0001
    private const val AEAD_ID = 0x0001

    /** DHKEM(P-256, HKDF-SHA256) shared-secret length. */
    private const val N_SECRET = 32

    /** AES-128-GCM key length. */
    private const val N_K = 16

    /** AES-128-GCM nonce length. */
    private const val N_N = 12

    /** SHA-256 output length, which is also the exporter secret's. */
    private const val N_H = 32

    private const val MODE_BASE: Byte = 0x00

    private val HPKE_V1 = "HPKE-v1".toByteArray(Charsets.US_ASCII)

    /** `"KEM" || I2OSP(kem_id, 2)`, the suite id every KEM step is labelled with. */
    private val KEM_SUITE_ID =
        "KEM".toByteArray(Charsets.US_ASCII) + i2osp(KEM_ID, 2)

    /** `"HPKE" || I2OSP(kem_id, 2) || I2OSP(kdf_id, 2) || I2OSP(aead_id, 2)`. */
    private val HPKE_SUITE_ID =
        "HPKE".toByteArray(Charsets.US_ASCII) +
            i2osp(KEM_ID, 2) + i2osp(KDF_ID, 2) + i2osp(AEAD_ID, 2)

    /** An uncompressed P-256 point: `0x04 || X(32) || Y(32)`. */
    private const val UNCOMPRESSED_POINT_LENGTH = 65

    /**
     * What a key schedule produced. Carried as a value so a test can compare
     * every field against a vector rather than only the plaintext at the end.
     */
    data class KeySchedule(
        val keyScheduleContext: ByteArray,
        val secret: ByteArray,
        val key: ByteArray,
        val baseNonce: ByteArray,
        val exporterSecret: ByteArray,
    ) {
        // Data classes over ByteArray get identity equality, which would make
        // an assertion on one silently pass. Spelled out rather than left to
        // surprise the next reader.
        override fun equals(other: Any?): Boolean =
            other is KeySchedule &&
                keyScheduleContext.contentEquals(other.keyScheduleContext) &&
                secret.contentEquals(other.secret) &&
                key.contentEquals(other.key) &&
                baseNonce.contentEquals(other.baseNonce) &&
                exporterSecret.contentEquals(other.exporterSecret)

        override fun hashCode(): Int =
            keyScheduleContext.contentHashCode() * 31 + key.contentHashCode()
    }

    /** A one-shot recipient key pair, with its public half already on the wire. */
    data class HandoffKeyPair(
        val privateKey: PrivateKey,
        /** `0x04 || X || Y`, the form `encapsulated_key` and `pkRm` both take. */
        val publicKeyUncompressed: ByteArray,
        /** X.509 SubjectPublicKeyInfo, the form the Admission contract carries. */
        val publicKeySpki: ByteArray,
    )

    // -- keys -------------------------------------------------------------

    /**
     * Generate the per-enrollment handoff key pair.
     *
     * Both encodings of the public half are returned because both are needed
     * and neither can be derived from the other without EC arithmetic this
     * object deliberately does not implement: the contract's `handoff_key`
     * carries SPKI, while the KEM's `pkRm` is the raw uncompressed point.
     */
    fun generateHandoffKeyPair(): HandoffKeyPair {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        val public = pair.public as ECPublicKey
        return HandoffKeyPair(
            privateKey = pair.private,
            publicKeyUncompressed = serializePoint(public.w),
            publicKeySpki = public.encoded,
        )
    }

    /** Read a P-256 private key from its raw scalar, as a vector states it. */
    fun privateKeyFromScalar(scalar: ByteArray): PrivateKey {
        val spec = ECPrivateKeySpec(BigInteger(1, scalar), p256Parameters())
        return KeyFactory.getInstance("EC").generatePrivate(spec)
    }

    /** Read a P-256 public key from `0x04 || X || Y`. */
    fun publicKeyFromUncompressed(point: ByteArray): PublicKey {
        require(point.size == UNCOMPRESSED_POINT_LENGTH && point[0] == 0x04.toByte()) {
            "P-256 public key must be an uncompressed point"
        }
        val x = BigInteger(1, point.copyOfRange(1, 33))
        val y = BigInteger(1, point.copyOfRange(33, 65))
        val spec = ECPublicKeySpec(ECPoint(x, y), p256Parameters())
        return KeyFactory.getInstance("EC").generatePublic(spec)
    }

    // -- KEM --------------------------------------------------------------

    /**
     * `Decap(enc, skR)` — the shared secret this recipient derives.
     *
     * [recipientPublicKeyUncompressed] is required rather than derived from
     * the private key: `kem_context` is `enc || pkRm`, and recovering `pkRm`
     * from a scalar means a scalar multiplication. The caller always has it —
     * it generated the pair, or a vector handed it over — so implementing EC
     * arithmetic to re-derive a value already in hand would be adding a
     * cryptographic surface for nothing.
     */
    fun decapsulate(
        recipientPrivateKey: PrivateKey,
        encapsulatedKey: ByteArray,
        recipientPublicKeyUncompressed: ByteArray,
    ): ByteArray {
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(recipientPrivateKey)
        agreement.doPhase(publicKeyFromUncompressed(encapsulatedKey), true)
        // For P-256 the JCA returns the X coordinate, which is exactly what
        // RFC 9180 §7.1.1 defines the DH output to be.
        val dh = agreement.generateSecret()
        val kemContext = encapsulatedKey + recipientPublicKeyUncompressed
        val eaePrk = labeledExtract(KEM_SUITE_ID, ByteArray(0), "eae_prk", dh)
        return labeledExpand(KEM_SUITE_ID, eaePrk, "shared_secret", kemContext, N_SECRET)
    }

    // -- key schedule -----------------------------------------------------

    /** `KeySchedule(mode_base, shared_secret, info, default_psk, default_psk_id)`. */
    fun keySchedule(sharedSecret: ByteArray, info: ByteArray): KeySchedule {
        val empty = ByteArray(0)
        val pskIdHash = labeledExtract(HPKE_SUITE_ID, empty, "psk_id_hash", empty)
        val infoHash = labeledExtract(HPKE_SUITE_ID, empty, "info_hash", info)
        val context = byteArrayOf(MODE_BASE) + pskIdHash + infoHash
        val secret = labeledExtract(HPKE_SUITE_ID, sharedSecret, "secret", empty)
        return KeySchedule(
            keyScheduleContext = context,
            secret = secret,
            key = labeledExpand(HPKE_SUITE_ID, secret, "key", context, N_K),
            baseNonce = labeledExpand(HPKE_SUITE_ID, secret, "base_nonce", context, N_N),
            exporterSecret = labeledExpand(HPKE_SUITE_ID, secret, "exp", context, N_H),
        )
    }

    /** `base_nonce XOR I2OSP(sequence, Nn)`. */
    fun nonceFor(baseNonce: ByteArray, sequenceNumber: Long): ByteArray {
        require(sequenceNumber >= 0) { "HPKE sequence number cannot be negative" }
        val sequence = i2osp(sequenceNumber, N_N)
        return ByteArray(N_N) { index -> (baseNonce[index].toInt() xor sequence[index].toInt()).toByte() }
    }

    // -- AEAD -------------------------------------------------------------

    /**
     * Open one AEAD message at [sequenceNumber] under an established schedule.
     *
     * Throws rather than returning null on a bad tag: a ClaimGrant that does
     * not authenticate is not a missing value, it is a Grant addressed to
     * someone else, and it must not be able to travel any further as one.
     */
    fun open(
        schedule: KeySchedule,
        aad: ByteArray,
        ciphertext: ByteArray,
        sequenceNumber: Long = 0,
    ): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(schedule.key, "AES"),
            GCMParameterSpec(128, nonceFor(schedule.baseNonce, sequenceNumber)),
        )
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertext)
    }

    /**
     * `OpenBase` end to end: the single call the ClaimGrant path makes.
     *
     * [info] is the suite's application info string; the ClaimGrant profile
     * binds its context through the AAD instead and passes it empty.
     */
    fun openBase(
        recipientPrivateKey: PrivateKey,
        recipientPublicKeyUncompressed: ByteArray,
        encapsulatedKey: ByteArray,
        info: ByteArray,
        aad: ByteArray,
        ciphertext: ByteArray,
    ): ByteArray {
        val sharedSecret =
            decapsulate(recipientPrivateKey, encapsulatedKey, recipientPublicKeyUncompressed)
        return open(keySchedule(sharedSecret, info), aad, ciphertext)
    }

    // -- HKDF and labels --------------------------------------------------

    private fun labeledExtract(
        suiteId: ByteArray,
        salt: ByteArray,
        label: String,
        ikm: ByteArray,
    ): ByteArray =
        extract(salt, HPKE_V1 + suiteId + label.toByteArray(Charsets.US_ASCII) + ikm)

    private fun labeledExpand(
        suiteId: ByteArray,
        prk: ByteArray,
        label: String,
        info: ByteArray,
        length: Int,
    ): ByteArray =
        expand(
            prk,
            i2osp(length, 2) + HPKE_V1 + suiteId +
                label.toByteArray(Charsets.US_ASCII) + info,
            length,
        )

    /** HKDF-Extract. An empty salt means `Nh` zero bytes, per RFC 5869 §2.2. */
    private fun extract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val key = if (salt.isEmpty()) ByteArray(N_H) else salt
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(ikm)
    }

    /** HKDF-Expand. */
    private fun expand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..(255 * N_H)) { "HKDF output length is out of range" }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val output = ByteArray(length)
        var previous = ByteArray(0)
        var written = 0
        var counter = 1
        while (written < length) {
            mac.reset()
            mac.update(previous)
            mac.update(info)
            mac.update(counter.toByte())
            previous = mac.doFinal()
            val take = minOf(previous.size, length - written)
            previous.copyInto(output, written, 0, take)
            written += take
            counter += 1
        }
        return output
    }

    // -- encoding ---------------------------------------------------------

    private fun serializePoint(point: ECPoint): ByteArray {
        val out = ByteArray(UNCOMPRESSED_POINT_LENGTH)
        out[0] = 0x04
        fixedWidth(point.affineX, 32).copyInto(out, 1)
        fixedWidth(point.affineY, 32).copyInto(out, 33)
        return out
    }

    /**
     * A coordinate as exactly [width] bytes.
     *
     * `BigInteger.toByteArray()` is neither: it prepends a sign byte when the
     * high bit is set and drops leading zeroes when it is not, so roughly one
     * key in 256 serialises short. A point that is one byte short is not a
     * point the other end can parse.
     */
    private fun fixedWidth(value: BigInteger, width: Int): ByteArray {
        val raw = value.toByteArray()
        val out = ByteArray(width)
        if (raw.size > width) {
            raw.copyInto(out, 0, raw.size - width, raw.size)
        } else {
            raw.copyInto(out, width - raw.size)
        }
        return out
    }

    private fun i2osp(value: Int, width: Int): ByteArray = i2osp(value.toLong(), width)

    private fun i2osp(value: Long, width: Int): ByteArray {
        val out = ByteArray(width)
        var remaining = value
        for (index in width - 1 downTo 0) {
            out[index] = (remaining and 0xFF).toByte()
            remaining = remaining ushr 8
        }
        return out
    }

    private fun p256Parameters(): ECParameterSpec {
        val parameters = AlgorithmParameters.getInstance("EC")
        parameters.init(ECGenParameterSpec("secp256r1"))
        return parameters.getParameterSpec(ECParameterSpec::class.java)
    }
}
