package live.eidolon.eidolon_client_mobile

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.os.ParcelUuid
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.provider.Settings
import android.util.Base64
import android.util.Log
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets
import java.net.Inet4Address
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.atomic.AtomicBoolean
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "live.eidolon.mobile/platform"
        private const val HUB_SERVICE_TYPE = "_eidolon-hub._tcp."
        private const val LOCAL_API_SERVICE_TYPE = "_eidolon-local-api._tcp."
        private const val KEY_ALIAS = "eidolon-mobile-device-p256-v1"
        private const val CONTROLLER_KEY_ALIAS = "eidolon-host-controller-p256-v1"
        private val CONTROLLER_CHALLENGE_PURPOSES = setOf(
            "eidolon-controller-ble-auth-v1",
            "eidolon-controller-local-auth-v1",
        )
        private const val DEVICE_ID_NAMESPACE = "eidolon-mobile-android-v1"
        private const val MIC_REQUEST_CODE = 7001
        private const val BLE_REQUEST_CODE = 7002
        private const val WIFI_PROVISIONING_REQUEST_CODE = 7003
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var permissionResult: MethodChannel.Result? = null
    private var bluetoothPermissionResult: MethodChannel.Result? = null
    private var wifiProvisioningPermissionResult: MethodChannel.Result? = null
    private var codeScanResult: MethodChannel.Result? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private val serviceInfoCallbacks = mutableSetOf<NsdManager.ServiceInfoCallback>()
    private var multicastLock: WifiManager.MulticastLock? = null
    private var setupScanCallback: ScanCallback? = null
    private var setupScanResult: MethodChannel.Result? = null
    private var commissioningManager: BleCommissioningManager? = null
    private val pinnedHttpsClient by lazy { PinnedHttpsClient(mainHandler) }
    private val deviceEnrollmentMaterialStore by lazy {
        DeviceEnrollmentMaterialStore(applicationContext)
    }
    private val legacyHotspotProvisioning by lazy {
        LegacyHotspotProvisioningManager(applicationContext, mainHandler)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleMethodCall)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "discoverHub" -> discoverHub(call.argument<Int>("timeoutMs") ?: 8000, result)
                "discoverLocalApis" -> discoverLocalApis(
                    call.argument<Int>("timeoutMs") ?: 5000,
                    result,
                )
                "getDeviceIdentity" -> result.success(deviceIdentity())
                "signRequest" -> result.success(signRequest(call))
                "loadOrCreateDeviceEnrollmentMaterial" -> result.success(
                    deviceEnrollmentMaterialStore.loadOrCreate(
                        call.argument<String>("hubId") ?: error("hubId is required"),
                    ),
                )
                "saveDeviceEnrollmentReceipt" -> {
                    deviceEnrollmentMaterialStore.saveReceipt(
                        hubId = call.argument<String>("hubId")
                            ?: error("hubId is required"),
                        enrollmentId = call.argument<String>("enrollmentId")
                            ?: error("enrollmentId is required"),
                        retrievalExpiresAtMs = call.argument<Number>("retrievalExpiresAtMs")
                            ?.toLong() ?: error("retrievalExpiresAtMs is required"),
                    )
                    result.success(null)
                }
                "clearDevicePairingSecret" -> {
                    deviceEnrollmentMaterialStore.clearPairingSecret(
                        call.argument<String>("hubId") ?: error("hubId is required"),
                    )
                    result.success(null)
                }
                "clearDeviceEnrollmentMaterial" -> {
                    deviceEnrollmentMaterialStore.clear(
                        call.argument<String>("hubId") ?: error("hubId is required"),
                    )
                    result.success(null)
                }
                "loadPendingDevicePairing" -> result.success(
                    deviceEnrollmentMaterialStore.loadPendingPairing(
                        call.argument<String>("hostId") ?: error("hostId is required"),
                    ),
                )
                "savePendingDevicePairing" -> {
                    deviceEnrollmentMaterialStore.savePendingPairing(
                        hostId = call.argument<String>("hostId")
                            ?: error("hostId is required"),
                        setupId = call.argument<String>("setupId")
                            ?: error("setupId is required"),
                        requestId = call.argument<String>("requestId")
                            ?: error("requestId is required"),
                        enrollmentId = call.argument<String>("enrollmentId")
                            ?: error("enrollmentId is required"),
                        pairingSecret = call.argument<String>("pairingSecret")
                            ?: error("pairingSecret is required"),
                    )
                    result.success(null)
                }
                "clearPendingDevicePairing" -> {
                    deviceEnrollmentMaterialStore.clearPendingPairing(
                        call.argument<String>("hostId") ?: error("hostId is required"),
                    )
                    result.success(null)
                }
                "signDeviceEnrollmentProof" ->
                    result.success(signDeviceEnrollmentProof(call))
                "getControllerIdentity" -> result.success(controllerIdentity())
                "signControllerChallenge" -> result.success(signControllerChallenge(call))
                "pinnedHttpsRequest" -> pinnedHttpsClient.request(call, result)
                "requestMicrophonePermission" -> requestMicrophonePermission(result)
                "requestBluetoothPermissions" -> requestBluetoothPermissions(result)
                "requestWifiProvisioningPermission" ->
                    requestWifiProvisioningPermission(result)
                "scanDevicePairingCode" -> scanDevicePairingCode(result)
                "openLegacyHotspotProvisioning" -> {
                    if (!hasWifiProvisioningPermission()) {
                        result.error(
                            "WIFI_PERMISSION_DENIED",
                            "Nearby Wi-Fi permission is required",
                            null,
                        )
                    } else {
                        legacyHotspotProvisioning.open(result)
                    }
                }
                "submitLegacyHotspotWifi" -> legacyHotspotProvisioning.submit(
                    call.argument<String>("ssid") ?: error("ssid is required"),
                    call.argument<String>("password") ?: error("password is required"),
                    result,
                )
                "closeLegacyHotspotProvisioning" -> {
                    legacyHotspotProvisioning.close()
                    result.success(null)
                }
                "scanSetupHosts" -> scanSetupHosts(
                    call.argument<String>("serviceUuid") ?: error("serviceUuid is required"),
                    call.argument<Int>("timeoutMs") ?: 8000,
                    result,
                )
                "openCommissioningLink" -> openCommissioningLink(call, result)
                "startCommissioningTls" -> commissioningManager?.secure(
                    call.argument<String>("tlsSpkiFingerprint")
                        ?: error("tlsSpkiFingerprint is required"),
                    result,
                ) ?: result.error("LINK_NOT_READY", "Open a commissioning link first", null)
                "commissioningRequest" -> commissioningManager?.request(
                    call.argument<String>("requestJson") ?: error("requestJson is required"),
                    result,
                ) ?: result.error("LINK_NOT_READY", "Open a commissioning link first", null)
                "closeCommissioningLink" -> {
                    commissioningManager?.close()
                    commissioningManager = null
                    result.success(null)
                }
                "readAppPreference" -> result.success(
                    getSharedPreferences("eidolon-mobile", Context.MODE_PRIVATE).getString(
                        call.argument<String>("key") ?: error("key is required"),
                        null,
                    ),
                )
                "writeAppPreference" -> {
                    getSharedPreferences("eidolon-mobile", Context.MODE_PRIVATE)
                        .edit()
                        .putString(
                            call.argument<String>("key") ?: error("key is required"),
                            call.argument<String>("value") ?: error("value is required"),
                        )
                        .apply()
                    result.success(null)
                }
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

    private fun ensureKeyEntry(alias: String = KEY_ALIAS): KeyStore.PrivateKeyEntry {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getEntry(alias, null) as? KeyStore.PrivateKeyEntry)?.let { return it }

        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .build()
        generator.initialize(spec)
        generator.generateKeyPair()
        keyStore.load(null)
        return keyStore.getEntry(alias, null) as KeyStore.PrivateKeyEntry
    }

    private fun deviceIdentity(): Map<String, String> {
        val publicDer = ensureKeyEntry().certificate.publicKey.encoded
        return mapOf(
            "deviceId" to deviceId(),
            "fingerprint" to "p256:${hex(sha256(publicDer))}",
        )
    }

    private fun controllerIdentity(): Map<String, String> {
        val publicDer = ensureKeyEntry(CONTROLLER_KEY_ALIAS).certificate.publicKey.encoded
        val digest = sha256(publicDer)
        return mapOf(
            "controllerId" to "ectrl-${hex(digest).take(20)}",
            "publicKey" to base64Url(publicDer),
            "fingerprint" to "sha256:${hex(digest)}",
        )
    }

    private fun signControllerChallenge(call: MethodCall): String {
        val challenge = call.argument<String>("challenge") ?: error("challenge is required")
        val contractVersion = call.argument<String>("contract_version")
            ?: error("contract_version is required")
        val controllerId = call.argument<String>("controller_id")
            ?: error("controller_id is required")
        val purpose = call.argument<String>("purpose") ?: error("purpose is required")
        val resetEpoch = call.argument<Int>("reset_epoch") ?: error("reset_epoch is required")
        require(contractVersion == "1" && purpose in CONTROLLER_CHALLENGE_PURPOSES) {
            "Unsupported Controller challenge"
        }
        val identity = controllerIdentity()
        require(identity["controllerId"] == controllerId) { "Controller challenge targets another key" }
        val canonical = "{" +
            "\"challenge\":${org.json.JSONObject.quote(challenge)}," +
            "\"contract_version\":\"1\"," +
            "\"controller_id\":${org.json.JSONObject.quote(controllerId)}," +
            "\"purpose\":${org.json.JSONObject.quote(purpose)}," +
            "\"reset_epoch\":$resetEpoch}"
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(ensureKeyEntry(CONTROLLER_KEY_ALIAS).privateKey)
        signer.update(canonical.toByteArray(StandardCharsets.UTF_8))
        return base64Url(signer.sign())
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

    private fun signDeviceEnrollmentProof(call: MethodCall): Map<String, String> {
        val values = listOf(
            requiredEnrollmentProofField(call, "requestId", 1, 96),
            requiredEnrollmentProofField(call, "deviceId", 1, 128),
            requiredEnrollmentHash(call, "retrievalTokenHash"),
            requiredEnrollmentProofField(call, "pairingMethod", 0, 64),
            requiredEnrollmentHash(call, "pairingCommitment"),
            requiredEnrollmentProofField(call, "deviceKind", 1, 96),
            requiredEnrollmentProofField(call, "displayName", 0, 128),
            requiredEnrollmentHash(call, "manifestRevision"),
        )
        require(values[3].isEmpty() || values[3] == "local-secret-sha256") {
            "pairingMethod is unsupported"
        }
        require(values[3].isEmpty() == values[4].isEmpty()) {
            "pairingMethod and pairingCommitment must be supplied together"
        }
        val statement = buildString {
            append("eidolon-device-enrollment-proof-v1\n")
            for (value in values) {
                val encoded = value.toByteArray(StandardCharsets.UTF_8)
                append(encoded.size)
                append(':')
                append(value)
                append('\n')
            }
        }.toByteArray(StandardCharsets.UTF_8)
        val entry = ensureKeyEntry()
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(entry.privateKey)
        signer.update(statement)
        return mapOf(
            "publicKeySpki" to base64Url(entry.certificate.publicKey.encoded),
            "signature" to base64Url(signer.sign()),
        )
    }

    private fun requiredEnrollmentProofField(
        call: MethodCall,
        name: String,
        minLength: Int,
        maxLength: Int,
    ): String = (call.argument<String>(name) ?: error("$name is required")).also {
        require(it.length in minLength..maxLength) { "$name is invalid" }
    }

    private fun requiredEnrollmentHash(call: MethodCall, name: String): String =
        requiredEnrollmentProofField(call, name, 0, 71).also {
            require(it.isEmpty() || Regex("^sha256:[0-9a-f]{64}$").matches(it)) {
                "$name is invalid"
            }
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

    private fun scanDevicePairingCode(result: MethodChannel.Result) {
        if (codeScanResult != null) {
            result.error("SCANNER_BUSY", "A device pairing scan is already active", null)
            return
        }
        codeScanResult = result
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        GmsBarcodeScanning.getClient(this, options)
            .startScan()
            .addOnSuccessListener { barcode ->
                val pending = codeScanResult
                codeScanResult = null
                val value = barcode.rawValue
                if (value.isNullOrBlank()) {
                    pending?.error("SCAN_EMPTY", "The QR code contains no text", null)
                } else {
                    pending?.success(value)
                }
            }
            .addOnCanceledListener {
                val pending = codeScanResult
                codeScanResult = null
                pending?.success(null)
            }
            .addOnFailureListener { error ->
                val pending = codeScanResult
                codeScanResult = null
                pending?.error(
                    "SCAN_FAILED",
                    error.message?.take(180) ?: "Could not scan the device QR code",
                    mapOf("exceptionType" to error.javaClass.simpleName),
                )
            }
    }

    private fun requiredBluetoothPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun hasBluetoothPermissions(): Boolean =
        requiredBluetoothPermissions().all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun requestBluetoothPermissions(result: MethodChannel.Result) {
        if (hasBluetoothPermissions()) {
            result.success(true)
            return
        }
        if (bluetoothPermissionResult != null) {
            result.error("PERMISSION_BUSY", "A Bluetooth permission request is already active", null)
            return
        }
        bluetoothPermissionResult = result
        requestPermissions(requiredBluetoothPermissions(), BLE_REQUEST_CODE)
    }

    private fun requiredWifiProvisioningPermissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
            arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        else -> emptyArray()
    }

    private fun hasWifiProvisioningPermission(): Boolean =
        requiredWifiProvisioningPermissions().all {
            checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }

    private fun requestWifiProvisioningPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "WIFI_UNSUPPORTED",
                "Android 10 or newer is required for in-app device hotspot selection",
                null,
            )
            return
        }
        if (hasWifiProvisioningPermission()) {
            result.success(true)
            return
        }
        if (wifiProvisioningPermissionResult != null) {
            result.error("PERMISSION_BUSY", "A Wi-Fi permission request is already active", null)
            return
        }
        wifiProvisioningPermissionResult = result
        requestPermissions(
            requiredWifiProvisioningPermissions(),
            WIFI_PROVISIONING_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MIC_REQUEST_CODE) {
            permissionResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            permissionResult = null
        }
        if (requestCode == BLE_REQUEST_CODE) {
            bluetoothPermissionResult?.success(
                grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED },
            )
            bluetoothPermissionResult = null
        }
        if (requestCode == WIFI_PROVISIONING_REQUEST_CODE) {
            val pending = wifiProvisioningPermissionResult
            wifiProvisioningPermissionResult = null
            // The package permission state is authoritative. Some Android
            // variants update the Nearby Devices app-op asynchronously or
            // return an empty grantResults array for an already-granted group.
            mainHandler.post {
                pending?.success(hasWifiProvisioningPermission())
            }
        }
    }

    private fun scanSetupHosts(serviceUuid: String, timeoutMs: Int, result: MethodChannel.Result) {
        if (!hasBluetoothPermissions()) {
            result.error("PERMISSION_DENIED", "Nearby devices permission is required", null)
            return
        }
        if (setupScanCallback != null) {
            result.error("SCAN_BUSY", "A setup scan is already running", null)
            return
        }
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = manager.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("BLUETOOTH_OFF", "Turn on Bluetooth to find the Eidolon Host", null)
            return
        }
        val scanner = adapter.bluetoothLeScanner
        val uuid = UUID.fromString(serviceUuid)
        val parcelUuid = ParcelUuid(uuid)
        val found = mutableMapOf<String, Map<String, Any>>()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, scanResult: ScanResult) {
                val record = scanResult.scanRecord ?: return
                val advertisedName = record.deviceName ?: ""
                val marker = record.getServiceData(parcelUuid)?.let(::hex)
                    ?: advertisedName.substringAfter("Eidolon-", "")
                val address = scanResult.device.address
                val previous = found[address]
                if (previous != null && (previous["rssi"] as Int) >= scanResult.rssi) return
                found[address] = mapOf(
                    "address" to address,
                    "name" to (advertisedName.ifEmpty { "Eidolon Host" }),
                    "hostMarker" to marker.lowercase(),
                    "rssi" to scanResult.rssi,
                )
            }

            override fun onScanFailed(errorCode: Int) {
                finishSetupScan(errorCode = errorCode)
            }
        }
        setupScanCallback = callback
        setupScanResult = result
        val filter = ScanFilter.Builder().setServiceUuid(parcelUuid).build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanner.startScan(listOf(filter), settings, callback)
        mainHandler.postDelayed({ finishSetupScan(found.values.toList()) }, timeoutMs.toLong())
    }

    private fun finishSetupScan(
        values: List<Map<String, Any>>? = null,
        errorCode: Int? = null,
    ) {
        val callback = setupScanCallback ?: return
        val result = setupScanResult ?: return
        setupScanCallback = null
        setupScanResult = null
        try {
            val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            manager.adapter?.bluetoothLeScanner?.stopScan(callback)
        } catch (_: Exception) {
        }
        if (errorCode == null) {
            result.success(values ?: emptyList<Map<String, Any>>())
        } else {
            result.error("SCAN_FAILED", "Bluetooth scan failed: $errorCode", null)
        }
    }

    private fun openCommissioningLink(call: MethodCall, result: MethodChannel.Result) {
        if (!hasBluetoothPermissions()) {
            result.error("PERMISSION_DENIED", "Nearby devices permission is required", null)
            return
        }
        commissioningManager?.close()
        commissioningManager = BleCommissioningManager(applicationContext, mainHandler).also {
            it.open(
                call.argument<String>("address") ?: error("address is required"),
                call.argument<String>("serviceUuid") ?: error("serviceUuid is required"),
                result,
            )
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
        nsd.discoverServices(HUB_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun discoverLocalApis(timeoutMs: Int, result: MethodChannel.Result) {
        if (discoveryListener != null) {
            result.error("DISCOVERY_BUSY", "mDNS discovery is already running", null)
            return
        }
        val nsd = getSystemService(Context.NSD_SERVICE) as NsdManager
        val completed = AtomicBoolean(false)
        val resolved = linkedMapOf<String, Map<String, String>>()
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("eidolon-local-api-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }

        fun finish(code: String? = null, message: String? = null) {
            if (!completed.compareAndSet(false, true)) return
            discoveryListener?.let {
                try { nsd.stopServiceDiscovery(it) } catch (_: Exception) { }
            }
            discoveryListener = null
            val callbacks = serviceInfoCallbacks.toList()
            serviceInfoCallbacks.clear()
            for (callback in callbacks) {
                try { nsd.unregisterServiceInfoCallback(callback) } catch (_: Exception) { }
            }
            multicastLock?.let { if (it.isHeld) it.release() }
            multicastLock = null
            if (resolved.isNotEmpty()) {
                result.success(resolved.values.toList())
            } else {
                result.error(code ?: "NOT_FOUND", message ?: "No Eidolon Local API found", null)
            }
        }

        fun recordResolved(info: NsdServiceInfo) {
            if (completed.get()) return
            val attributes = info.attributes.mapValues {
                String(it.value, StandardCharsets.UTF_8)
            }
            if (attributes["contract"] != "1" || attributes["scheme"] != "https") return
            val addresses = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                info.hostAddresses
            } else {
                @Suppress("DEPRECATION")
                listOfNotNull(info.host)
            }
            val mdnsHost = if (Build.VERSION.SDK_INT >= 36) {
                info.hostname
                    ?.trim()
                    ?.trimEnd('.')
                    ?.takeIf { it.isNotEmpty() }
                    ?.let {
                        if (it.endsWith(".local", ignoreCase = true)) it else "$it.local"
                    }
            } else {
                null
            }
            val ipv4Addresses = addresses
                .filterIsInstance<Inet4Address>()
                .mapNotNull { it.hostAddress }
            val ipv6Addresses = addresses
                .filterNot { it is Inet4Address }
                .mapNotNull { it.hostAddress }
                .filterNot { it.contains('%') }
            val fallbackAddress = ipv4Addresses.firstOrNull() ?: ipv6Addresses.firstOrNull()
            val candidates = buildList {
                addAll(ipv4Addresses.map { it to it })
                if (mdnsHost != null && fallbackAddress != null) {
                    add(mdnsHost to fallbackAddress)
                }
                addAll(ipv6Addresses.map { "[$it]" to it })
            }.distinctBy { it.first }
            for ((host, ipAddress) in candidates) {
                val baseUrl = "https://$host:${info.port}"
                Log.d("EidolonLocalApi", "Resolved ${info.serviceName} to $baseUrl")
                resolved[baseUrl] = mapOf(
                    "instanceName" to info.serviceName,
                    "baseUrl" to baseUrl,
                    "ipAddress" to ipAddress,
                    "contractVersion" to "1",
                )
            }
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                finish("DISCOVERY_FAILED", "NSD start failed: $errorCode")
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            @Suppress("DEPRECATION")
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (completed.get() ||
                    !serviceInfo.serviceType.startsWith("_eidolon-local-api._tcp")
                ) return
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    val callback = object : NsdManager.ServiceInfoCallback {
                        override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                            serviceInfoCallbacks.remove(this)
                        }

                        override fun onServiceUpdated(info: NsdServiceInfo) {
                            recordResolved(info)
                        }

                        override fun onServiceLost() = Unit

                        override fun onServiceInfoCallbackUnregistered() {
                            serviceInfoCallbacks.remove(this)
                        }
                    }
                    serviceInfoCallbacks.add(callback)
                    try {
                        nsd.registerServiceInfoCallback(serviceInfo, mainExecutor, callback)
                    } catch (_: Exception) {
                        serviceInfoCallbacks.remove(callback)
                    }
                    return
                }
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = Unit

                    override fun onServiceResolved(info: NsdServiceInfo) {
                        recordResolved(info)
                    }
                })
            }
        }
        discoveryListener = listener
        mainHandler.postDelayed({
            finish("NOT_FOUND", "No compatible Eidolon Local API found on the LAN")
        }, timeoutMs.toLong())
        nsd.discoverServices(LOCAL_API_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    override fun onDestroy() {
        finishSetupScan()
        commissioningManager?.close()
        commissioningManager = null
        legacyHotspotProvisioning.destroy()
        pinnedHttpsClient.close()
        discoveryListener?.let {
            try { (getSystemService(Context.NSD_SERVICE) as NsdManager).stopServiceDiscovery(it) } catch (_: Exception) { }
        }
        discoveryListener = null
        val nsd = getSystemService(Context.NSD_SERVICE) as NsdManager
        val callbacks = serviceInfoCallbacks.toList()
        serviceInfoCallbacks.clear()
        for (callback in callbacks) {
            try { nsd.unregisterServiceInfoCallback(callback) } catch (_: Exception) { }
        }
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        permissionResult?.success(false)
        permissionResult = null
        bluetoothPermissionResult?.success(false)
        bluetoothPermissionResult = null
        wifiProvisioningPermissionResult?.success(false)
        wifiProvisioningPermissionResult = null
        codeScanResult?.success(null)
        codeScanResult = null
        super.onDestroy()
    }

    private fun sha256(value: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(value)

    private fun hex(value: ByteArray): String = value.joinToString("") { "%02x".format(it) }

    private fun base64Url(value: ByteArray): String = Base64.encodeToString(
        value,
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
    )
}
