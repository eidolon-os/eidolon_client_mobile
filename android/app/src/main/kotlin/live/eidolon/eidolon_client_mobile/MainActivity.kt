package live.eidolon.eidolon_client_mobile

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.provider.Settings
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "live.eidolon.mobile/platform"
        private const val SERVICE_TYPE = "_eidolon-hub._tcp."
        private const val KEY_ALIAS = "eidolon-mobile-device-p256-v1"
        private const val DEVICE_ID_NAMESPACE = "eidolon-mobile-android-v1"
        private const val MIC_REQUEST_CODE = 7001
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var permissionResult: MethodChannel.Result? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleMethodCall)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "discoverHub" -> discoverHub(call.argument<Int>("timeoutMs") ?: 8000, result)
                "getDeviceIdentity" -> result.success(deviceIdentity())
                "signRequest" -> result.success(signRequest(call))
                "requestMicrophonePermission" -> requestMicrophonePermission(result)
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("PLATFORM_ERROR", error.message, error.stackTraceToString())
        }
    }

    private fun deviceId(): String {
        // ANDROID_ID is stable across uninstall/reinstall for the same Android
        // user and signing key (Android 8+), but is not a globally reusable
        // hardware serial. Hashing it with an Eidolon namespace keeps the Hub
        // identity deterministic without exposing the platform identifier.
        val androidId = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ANDROID_ID,
        )?.trim().orEmpty()
        check(androidId.isNotEmpty()) { "ANDROID_ID is unavailable" }
        val seed = "$DEVICE_ID_NAMESPACE:$androidId"
        return "mobile-android-${hex(sha256(seed.toByteArray(StandardCharsets.UTF_8))).take(32)}"
    }

    private fun ensureKeyEntry(): KeyStore.PrivateKeyEntry {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry)?.let { return it }

        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .build()
        generator.initialize(spec)
        generator.generateKeyPair()
        keyStore.load(null)
        return keyStore.getEntry(KEY_ALIAS, null) as KeyStore.PrivateKeyEntry
    }

    private fun deviceIdentity(): Map<String, String> {
        val publicDer = ensureKeyEntry().certificate.publicKey.encoded
        return mapOf(
            "deviceId" to deviceId(),
            "fingerprint" to "p256:${hex(sha256(publicDer))}",
        )
    }

    private fun signRequest(call: MethodCall): Map<String, String> {
        val method = call.argument<String>("method") ?: error("method is required")
        val pathQuery = call.argument<String>("pathQuery") ?: error("pathQuery is required")
        val body = call.argument<String>("body") ?: ""
        val entry = ensureKeyEntry()
        val nonceBytes = ByteArray(16).also(SecureRandom()::nextBytes)
        val nonce = base64Url(nonceBytes)
        val timestamp = (System.currentTimeMillis() / 1000L).toString()
        val publicDer = entry.certificate.publicKey.encoded
        val canonical = listOf(
            method,
            pathQuery,
            deviceId(),
            nonce,
            timestamp,
            hex(sha256(body.toByteArray(StandardCharsets.UTF_8))),
        ).joinToString("\n")
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(entry.privateKey)
        signer.update(canonical.toByteArray(StandardCharsets.UTF_8))
        return mapOf(
            "deviceId" to deviceId(),
            "nonce" to nonce,
            "timestamp" to timestamp,
            "publicKey" to base64Url(publicDer),
            "signature" to base64Url(signer.sign()),
        )
    }

    private fun requestMicrophonePermission(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (permissionResult != null) {
            result.error("PERMISSION_BUSY", "A microphone permission request is already active", null)
            return
        }
        permissionResult = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MIC_REQUEST_CODE) {
            permissionResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            permissionResult = null
        }
    }

    private fun discoverHub(timeoutMs: Int, result: MethodChannel.Result) {
        if (discoveryListener != null) {
            result.error("DISCOVERY_BUSY", "mDNS discovery is already running", null)
            return
        }
        val nsd = getSystemService(Context.NSD_SERVICE) as NsdManager
        val completed = AtomicBoolean(false)
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("eidolon-hub-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }

        fun finish(value: Map<String, String>? = null, code: String? = null, message: String? = null) {
            if (!completed.compareAndSet(false, true)) return
            discoveryListener?.let {
                try { nsd.stopServiceDiscovery(it) } catch (_: Exception) { }
            }
            discoveryListener = null
            multicastLock?.let { if (it.isHeld) it.release() }
            multicastLock = null
            if (value != null) result.success(value) else result.error(code ?: "NOT_FOUND", message, null)
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                finish(code = "DISCOVERY_FAILED", message = "NSD start failed: $errorCode")
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            @Suppress("DEPRECATION")
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (completed.get() || !serviceInfo.serviceType.startsWith("_eidolon-hub._tcp")) return
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = Unit

                    override fun onServiceResolved(info: NsdServiceInfo) {
                        val attributes = info.attributes.mapValues {
                            String(it.value, StandardCharsets.UTF_8)
                        }
                        val registerUrl = attributes["register_url"] ?: return
                        if (attributes["txtvers"] != "1" || attributes["api"] != "v1") return
                        finish(
                            mapOf(
                                "instanceName" to info.serviceName,
                                "registerUrl" to registerUrl,
                                "version" to (attributes["version"] ?: ""),
                                "api" to (attributes["api"] ?: ""),
                            ),
                        )
                    }
                })
            }
        }
        discoveryListener = listener
        mainHandler.postDelayed({
            finish(code = "NOT_FOUND", message = "No compatible Eidolon Hub found on the LAN")
        }, timeoutMs.toLong())
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    override fun onDestroy() {
        discoveryListener?.let {
            try { (getSystemService(Context.NSD_SERVICE) as NsdManager).stopServiceDiscovery(it) } catch (_: Exception) { }
        }
        discoveryListener = null
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        permissionResult?.success(false)
        permissionResult = null
        super.onDestroy()
    }

    private fun sha256(value: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(value)

    private fun hex(value: ByteArray): String = value.joinToString("") { "%02x".format(it) }

    private fun base64Url(value: ByteArray): String = Base64.encodeToString(
        value,
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
    )
}
