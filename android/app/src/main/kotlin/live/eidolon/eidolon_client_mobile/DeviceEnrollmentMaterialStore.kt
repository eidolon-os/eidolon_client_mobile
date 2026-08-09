package live.eidolon.eidolon_client_mobile

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android-Keystore-backed storage for the short-lived Hub enrollment bearer
 * material. The normal app preference bridge never sees these values.
 */
internal class DeviceEnrollmentMaterialStore(context: Context) {
    companion object {
        private const val KEY_ALIAS = "eidolon-mobile-enrollment-aes-v1"
        private const val PREFERENCES = "eidolon-mobile-enrollment-secrets"
        private const val RECORD_VERSION = 1
        private const val GCM_TAG_BITS = 128
        private const val RANDOM_BYTES = 32
    }

    private val applicationContext = context.applicationContext
    private val preferences = applicationContext.getSharedPreferences(
        PREFERENCES,
        Context.MODE_PRIVATE,
    )
    private val random = SecureRandom()

    @Synchronized
    fun loadOrCreate(hubId: String): Map<String, Any> {
        val normalizedHubId = requireHubId(hubId)
        val key = enrollmentPreferenceKey(normalizedHubId)
        val stored = preferences.getString(key, null)
        val record = if (stored == null) {
            JSONObject()
                .put("version", RECORD_VERSION)
                .put("hubId", normalizedHubId)
                .put("enrollmentRequestId", "mobile-enroll-${UUID.randomUUID()}")
                .put("handoffRequestId", "mobile-handoff-${UUID.randomUUID()}")
                .put("retrievalToken", randomBase64Url())
                .also { save(key, normalizedHubId, it) }
        } else {
            decrypt(stored, normalizedHubId)
        }
        validateRecord(record, normalizedHubId)
        return record.toPlatformMap()
    }

    @Synchronized
    fun saveReceipt(
        hubId: String,
        enrollmentId: String,
        retrievalExpiresAtMs: Long,
    ) {
        val normalizedHubId = requireHubId(hubId)
        require(enrollmentId.isNotBlank() && enrollmentId.length <= 128) {
            "enrollmentId is invalid"
        }
        require(retrievalExpiresAtMs >= 0) { "retrievalExpiresAtMs is invalid" }
        val key = enrollmentPreferenceKey(normalizedHubId)
        val stored = preferences.getString(key, null)
            ?: error("Enrollment material does not exist")
        val record = decrypt(stored, normalizedHubId)
        validateRecord(record, normalizedHubId)
        record
            .put("enrollmentId", enrollmentId)
            .put("retrievalExpiresAtMs", retrievalExpiresAtMs)
        save(key, normalizedHubId, record)
    }

    @Synchronized
    fun clear(hubId: String) {
        remove(enrollmentPreferenceKey(requireHubId(hubId)))
    }

    private fun save(key: String, associatedData: String, record: JSONObject) {
        preferences.edit().putString(key, encrypt(record, associatedData)).commit().also {
            check(it) { "Could not persist enrollment material" }
        }
    }

    private fun remove(key: String) {
        preferences.edit().remove(key).commit().also {
            check(it) { "Could not clear encrypted enrollment material" }
        }
    }

    private fun encrypt(record: JSONObject, associatedData: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        cipher.updateAAD(associatedData.toByteArray(StandardCharsets.UTF_8))
        val ciphertext = cipher.doFinal(record.toString().toByteArray(StandardCharsets.UTF_8))
        return JSONObject()
            .put("version", RECORD_VERSION)
            .put("iv", base64Url(cipher.iv))
            .put("ciphertext", base64Url(ciphertext))
            .toString()
    }

    private fun decrypt(envelopeValue: String, associatedData: String): JSONObject {
        val envelope = JSONObject(envelopeValue)
        check(envelope.getInt("version") == RECORD_VERSION) {
            "Enrollment secret envelope version is unsupported"
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(),
            GCMParameterSpec(GCM_TAG_BITS, decodeBase64Url(envelope.getString("iv"))),
        )
        cipher.updateAAD(associatedData.toByteArray(StandardCharsets.UTF_8))
        val plaintext = cipher.doFinal(
            decodeBase64Url(envelope.getString("ciphertext")),
        )
        return JSONObject(String(plaintext, StandardCharsets.UTF_8))
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun validateRecord(record: JSONObject, hubId: String) {
        check(record.getInt("version") == RECORD_VERSION) {
            "Enrollment material version is unsupported"
        }
        check(record.getString("hubId") == hubId) {
            "Enrollment material belongs to another Hub"
        }
        requireBounded(record.getString("enrollmentRequestId"), 1, 96, "enrollmentRequestId")
        requireBounded(record.getString("handoffRequestId"), 1, 96, "handoffRequestId")
        requireBase64Url(record.getString("retrievalToken"), "retrievalToken")
        if (record.has("enrollmentId")) {
            requireBounded(record.getString("enrollmentId"), 1, 128, "enrollmentId")
        }
        if (record.has("retrievalExpiresAtMs")) {
            check(record.getLong("retrievalExpiresAtMs") >= 0) {
                "retrievalExpiresAtMs is invalid"
            }
        }
    }

    private fun JSONObject.toPlatformMap(): Map<String, Any> = buildMap {
        put("enrollmentRequestId", getString("enrollmentRequestId"))
        put("handoffRequestId", getString("handoffRequestId"))
        put("retrievalToken", getString("retrievalToken"))
        if (has("enrollmentId")) put("enrollmentId", getString("enrollmentId"))
        if (has("retrievalExpiresAtMs")) {
            put("retrievalExpiresAtMs", getLong("retrievalExpiresAtMs"))
        }
    }

    private fun enrollmentPreferenceKey(hubId: String): String =
        "hub-${digestKey(hubId)}"

    private fun digestKey(value: String): String = hex(
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray(StandardCharsets.UTF_8)),
    ).take(32)

    private fun randomBase64Url(): String =
        base64Url(ByteArray(RANDOM_BYTES).also(random::nextBytes))

    private fun base64Url(value: ByteArray): String =
        Base64.encodeToString(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private fun decodeBase64Url(value: String): ByteArray =
        Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private fun requireHubId(value: String): String = value.trim().also {
        require(it.isNotEmpty() && it.length <= 128) { "hubId is invalid" }
    }

    private fun requireBase64Url(value: String, field: String) {
        requireBounded(value, 32, 256, field)
        require(value.all { it.isLetterOrDigit() || it == '-' || it == '_' }) {
            "$field is invalid"
        }
    }

    private fun requireBounded(value: String, min: Int, max: Int, field: String) {
        require(value.length in min..max) { "$field is invalid" }
    }

    private fun hex(value: ByteArray): String = value.joinToString("") { "%02x".format(it) }
}
