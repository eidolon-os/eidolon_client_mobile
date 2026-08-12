package live.eidolon.eidolon_client_mobile

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.PatternMatcher
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android-only adapter for the legacy ESP32 local hotspot contract.
 *
 * The requested Wi-Fi network is local-only and every HTTP connection is
 * created from the selected [Network]. The Activity process is never bound to
 * the device hotspot, so Host Local API traffic cannot accidentally cross this
 * untrusted link.
 */
class LegacyHotspotProvisioningManager(
    context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "EidolonDeviceSetup"
        private const val AP_SSID_PREFIX = "Xiaozhi-"
        private const val ENDPOINT = "http://192.168.4.1"
        // Commissioning is Eidolon's own contract and runs beside the vendor
        // captive portal rather than inside it, so it answers on its own port.
        private const val COMMISSIONING_ENDPOINT = "http://192.168.4.1:8266"
        private const val MAX_RESPONSE_BYTES = 64 * 1024
        private const val NETWORK_SELECTION_TIMEOUT_MS = 120_000
    }

    private val connectivity =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val lock = Any()
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var activeNetwork: Network? = null
    private var opening = false
    private var closed = false

    fun open(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error(
                "WIFI_UNSUPPORTED",
                "Android 10 or newer is required for in-app device hotspot selection",
                null,
            )
            return
        }

        synchronized(lock) {
            if (closed) {
                result.error("HOTSPOT_CONNECTION_LOST", "Provisioning manager is closed", null)
                return
            }
            if (opening) {
                result.error("HOTSPOT_BUSY", "A device hotspot selection is already active", null)
                return
            }
            releaseNetworkLocked()
            opening = true
        }

        val completed = AtomicBoolean(false)
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsidPattern(PatternMatcher(AP_SSID_PREFIX, PatternMatcher.PATTERN_PREFIX))
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        fun fail(code: String, message: String) {
            if (!completed.compareAndSet(false, true)) return
            synchronized(lock) {
                opening = false
                releaseNetworkLocked()
            }
            mainHandler.post { result.error(code, message, null) }
        }

        val networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.i(TAG, "Device hotspot is available; starting the device Wi-Fi scan")
                synchronized(lock) {
                    if (closed || callback !== this) return
                    activeNetwork = network
                }
                executor.execute {
                    try {
                        val networks = scanNetworks(network)
                        Log.i(TAG, "Device Wi-Fi scan completed with ${networks.size} network(s)")
                        if (!completed.compareAndSet(false, true)) return@execute
                        synchronized(lock) { opening = false }
                        mainHandler.post {
                            result.success(mapOf("networks" to networks))
                        }
                    } catch (error: Exception) {
                        Log.w(TAG, "The selected hotspot did not complete the device scan", error)
                        fail(
                            "HOTSPOT_PROTOCOL_ERROR",
                            error.message ?: "The selected hotspot is not a compatible device",
                        )
                    }
                }
            }

            override fun onUnavailable() {
                Log.i(TAG, "Device hotspot selection was cancelled, unavailable, or timed out")
                fail("HOTSPOT_NOT_FOUND", "No compatible device hotspot was selected")
            }

            override fun onLost(network: Network) {
                var shouldFail = false
                synchronized(lock) {
                    if (activeNetwork == network) {
                        activeNetwork = null
                        shouldFail = opening
                    }
                }
                if (shouldFail) {
                    Log.w(TAG, "Device hotspot was lost before its scan completed")
                    fail("HOTSPOT_CONNECTION_LOST", "The device hotspot connection was lost")
                }
            }
        }
        synchronized(lock) { callback = networkCallback }
        try {
            Log.i(TAG, "Opening the Android device hotspot selector")
            connectivity.requestNetwork(
                request,
                networkCallback,
                NETWORK_SELECTION_TIMEOUT_MS,
            )
        } catch (error: SecurityException) {
            Log.e(TAG, "Unable to submit the local-only network request", error)
            fail(
                "HOTSPOT_PLATFORM_ERROR",
                error.message ?: "Android rejected the local-only network request",
            )
        } catch (error: Exception) {
            Log.e(TAG, "Unable to submit the local-only network request", error)
            fail("HOTSPOT_NOT_FOUND", error.message ?: "Unable to select a device hotspot")
        }
    }

    fun submit(ssid: String, password: String, result: MethodChannel.Result) {
        val ssidBytes = ssid.toByteArray(StandardCharsets.UTF_8).size
        val passwordBytes = password.toByteArray(StandardCharsets.UTF_8).size
        if (ssid.isBlank() || ssidBytes > 32 || passwordBytes > 64) {
            result.error(
                "INVALID_WIFI_CREDENTIALS",
                "Wi-Fi name or password exceeds the device protocol limits",
                null,
            )
            return
        }
        val network = synchronized(lock) { activeNetwork }
        if (network == null) {
            result.error(
                "HOTSPOT_CONNECTION_LOST",
                "Connect to the device hotspot before configuring Wi-Fi",
                null,
            )
            return
        }
        executor.execute {
            try {
                val request = JSONObject()
                    .put("ssid", ssid)
                    .put("password", password)
                    .toString()
                    .toByteArray(StandardCharsets.UTF_8)
                val response = request(
                    network = network,
                    path = "/submit",
                    method = "POST",
                    body = request,
                    readTimeoutMs = 75_000,
                )
                val payload = JSONObject(response)
                if (!payload.optBoolean("success", false)) {
                    val firmwareError = payload.optString("error").trim()
                    val message = when (firmwareError) {
                        "Failed to connect to the Access Point" ->
                            "设备未能加入该 Wi-Fi，请核对密码、频段和网络兼容性"
                        "Invalid SSID" -> "Wi-Fi 名称无效"
                        else -> firmwareError.ifEmpty { "设备未确认网络配置成功" }
                    }
                    mainHandler.post {
                        result.error("WIFI_CONFIGURATION_REJECTED", message, null)
                    }
                    return@execute
                }
                mainHandler.post { result.success(mapOf("success" to true)) }
            } catch (error: Exception) {
                val code = if (error is IOException) {
                    "WIFI_CONFIGURATION_UNKNOWN"
                } else {
                    "HOTSPOT_PROTOCOL_ERROR"
                }
                val message = if (error is IOException) {
                    "与设备的连接在结果确认前断开；设备可能已经加入 Wi-Fi，请先查看设备状态"
                } else {
                    error.message ?: "The device returned an invalid configuration response"
                }
                mainHandler.post {
                    result.error(code, message, null)
                }
            }
        }
    }

    fun close() {
        synchronized(lock) {
            releaseNetworkLocked()
            opening = false
        }
    }

    fun destroy() {
        synchronized(lock) {
            closed = true
            releaseNetworkLocked()
            opening = false
        }
        executor.shutdownNow()
    }

    private fun scanNetworks(network: Network): List<Map<String, Any>> {
        val response = request(
            network = network,
            path = "/scan",
            method = "GET",
            body = null,
            readTimeoutMs = 10_000,
        )
        val payload = JSONObject(response)
        val aps = payload.optJSONArray("aps")
            ?: error("Device /scan response does not contain aps")
        val strongestBySsid = linkedMapOf<String, Map<String, Any>>()
        for (index in 0 until aps.length()) {
            val ap = aps.optJSONObject(index) ?: continue
            val ssid = ap.optString("ssid").trim()
            if (ssid.isEmpty()) continue
            val rssi = ap.optInt("rssi", -100)
            val authMode = ap.optInt("authmode", 0)
            val signal = ((rssi + 100) * 2).coerceIn(0, 100)
            val item = mapOf<String, Any>(
                "ssid" to ssid,
                "signalStrength" to signal,
                "security" to if (authMode == 0) "open" else "secured",
            )
            val previous = strongestBySsid[ssid]
            if (previous == null || signal > previous.getValue("signalStrength") as Int) {
                strongestBySsid[ssid] = item
            }
        }
        return strongestBySsid.values.sortedByDescending { it.getValue("signalStrength") as Int }
    }

    /** What device is on the other end of this hotspot. */
    fun identify(result: MethodChannel.Result) {
        val network = boundNetwork
        if (network == null) {
            result.error(
                "HOTSPOT_NOT_CONNECTED",
                "Connect to the device hotspot before identifying it",
                null,
            )
            return
        }
        executor.execute {
            try {
                val payload = JSONObject(
                    request(
                        network = network,
                        path = "/identity",
                        method = "GET",
                        body = null,
                        readTimeoutMs = 10_000,
                        endpoint = COMMISSIONING_ENDPOINT,
                    )
                )
                val identity = mapOf(
                    "deviceId" to payload.getString("device_id"),
                    "board" to payload.optString("board"),
                    "deviceKind" to payload.optString("device_kind"),
                )
                mainHandler.post { result.success(identity) }
            } catch (error: Exception) {
                mainHandler.post { failure(result, error, "DEVICE_IDENTITY") }
            }
        }
    }

    /**
     * Hand the device the Host it belongs to, and the network to reach it on.
     *
     * One act: a device that joined a network without knowing which Host to
     * trust would have nothing it could safely talk to there.
     */
    fun commission(
        hubId: String,
        hubCertificate: String,
        ssid: String?,
        password: String?,
        result: MethodChannel.Result,
    ) {
        val network = boundNetwork
        if (network == null) {
            result.error(
                "HOTSPOT_NOT_CONNECTED",
                "Connect to the device hotspot before commissioning it",
                null,
            )
            return
        }
        executor.execute {
            try {
                val document = JSONObject()
                    .put("schema_version", 1)
                    .put("hub_id", hubId)
                    .put("hub_certificate", hubCertificate)
                if (ssid != null) {
                    document.put(
                        "wifi",
                        JSONObject().put("ssid", ssid).put("password", password ?: ""),
                    )
                }
                val response = request(
                    network = network,
                    path = "/commission",
                    method = "POST",
                    body = document.toString().toByteArray(StandardCharsets.UTF_8),
                    // The device answers only once it has joined the network,
                    // so this waits as long as the vendor Wi-Fi submission does.
                    readTimeoutMs = 75_000,
                    endpoint = COMMISSIONING_ENDPOINT,
                )
                val payload = JSONObject(response)
                val commissioned = mapOf(
                    "deviceId" to payload.getString("device_id"),
                    "hubId" to payload.getString("hub_id"),
                )
                mainHandler.post { result.success(commissioned) }
            } catch (error: Exception) {
                mainHandler.post { failure(result, error, "COMMISSIONING") }
            }
        }
    }

    private fun failure(result: MethodChannel.Result, error: Exception, stage: String) {
        val transport = error is IOException
        result.error(
            if (transport) "${stage}_UNREACHABLE" else "${stage}_REJECTED",
            if (transport) {
                "与设备的连接中断，请靠近设备后重试"
            } else {
                error.message ?: "设备拒绝了这次设置"
            },
            null,
        )
    }

    private fun request(
        network: Network,
        path: String,
        method: String,
        body: ByteArray?,
        readTimeoutMs: Int,
        endpoint: String = ENDPOINT,
    ): String {
        val connection = network.openConnection(URL(endpoint + path)) as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = 5_000
            connection.readTimeout = readTimeoutMs
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Connection", "close")
            if (body != null) {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val response = stream?.use(::readBounded).orEmpty()
            check(status in 200..299) { "Device returned HTTP $status" }
            check(response.isNotBlank()) { "Device returned an empty response" }
            return response
        } finally {
            connection.disconnect()
        }
    }

    private fun readBounded(input: java.io.InputStream): String {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            check(output.size() + count <= MAX_RESPONSE_BYTES) { "Device response is too large" }
            output.write(buffer, 0, count)
        }
        return output.toString(StandardCharsets.UTF_8.name())
    }

    private fun releaseNetworkLocked() {
        callback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        callback = null
        activeNetwork = null
    }
}
