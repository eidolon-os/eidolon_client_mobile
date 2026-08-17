package live.eidolon.eidolon_client_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import com.espressif.provisioning.DeviceConnectionEvent
import com.espressif.provisioning.ESPConstants
import com.espressif.provisioning.ESPDevice
import com.espressif.provisioning.ESPProvisionManager
import com.espressif.provisioning.WiFiAccessPoint
import com.espressif.provisioning.listeners.ProvisionListener
import com.espressif.provisioning.listeners.ResponseListener
import com.espressif.provisioning.listeners.WiFiScanListener
import io.flutter.plugin.common.MethodChannel
import org.greenrobot.eventbus.EventBus
import org.greenrobot.eventbus.Subscribe
import org.greenrobot.eventbus.ThreadMode
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The Android half of device provisioning: protocomm over the device's own
 * access point.
 *
 * A device that has never been set up offers a Wi-Fi network named
 * `Eidolon-<mac tail>` and speaks Espressif's provisioning protocol on it —
 * protobuf over HTTP, inside an SRP6a-authenticated session (Security 2). That
 * protocol is not reimplemented here. It is the vendor's own wire format for
 * the vendor's own firmware, and the vendor's client is what talks it; this
 * class is the part that belongs to Eidolon: which devices count, what is asked
 * of them, and in what order.
 *
 * Two things are worth knowing before reading further.
 *
 * The vendor client binds the whole process to the device's network while a
 * session is open, because that access point has no route to anything else.
 * That is acceptable only if it is undone the moment the session's work is
 * finished — the very next thing this app does is ask the *Host* whether the
 * device enrolled, and that question travels over the home network. So the
 * binding is released as soon as credentials have been handed over, not when
 * the screen is dismissed.
 *
 * And handing over credentials is the last thing that can be asked. The
 * provisioning service stops once they are accepted, so anything Eidolon needs
 * to say — which Host this device belongs to — has to be said before it, and
 * the order is enforced by the caller rather than assumed here.
 */
class DeviceProvisioningManager(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "EidolonDeviceSetup"

        /** What an unprovisioned Eidolon device calls its setup network. */
        private const val AP_PREFIX = "Eidolon-"

        /**
         * The Security 2 identity and passphrase for development builds.
         *
         * The device stores only a salt and an SRP verifier, so this passphrase
         * cannot be recovered from a board; a manufacturer-bound build carries
         * a per-device secret in its place and refuses to run with this one.
         */
        private const val SECURITY_USERNAME = "eidolon-setup"
        private const val SECURITY_PASSPHRASE = "eidolon-dev-setup"

        private const val DESCRIPTOR_ENDPOINT = "eidolon-descriptor"
        private const val TRUST_ENDPOINT = "eidolon-trust"

        private const val TRANSPORT_KIND = "softap"

        /** The smallest thing that is not nothing. See its use below. */
        private val EMPTY_REQUEST = "{}".toByteArray(StandardCharsets.UTF_8)

        /**
         * How old a scan may be and still count as an answer.
         *
         * Android throttles how often an app may ask for a fresh Wi-Fi scan,
         * and when it refuses it hands back whatever it last saw — which can
         * be from before the device in front of the person was even switched
         * on. An empty list from a stale cache is not "there is nothing
         * there"; it is "nobody looked".
         */
        private const val FRESH_SCAN_MILLIS = 30_000L
        private const val SCAN_TIMEOUT_MILLIS = 15_000L
    }

    private val provisioning: ESPProvisionManager =
        ESPProvisionManager.getInstance(context.applicationContext)
    private val lock = Any()
    private var device: ESPDevice? = null
    private var connectResult: PendingResult? = null
    private var subscribed = false

    /**
     * One in-flight platform call, answered exactly once.
     *
     * The vendor client reports through a listener that may fire more than one
     * terminal callback for the same act — a failure after a success, a status
     * query that times out after credentials were already applied. A result
     * delivered twice crashes the engine, so the answer is claimed here.
     */
    private class PendingResult(private val result: MethodChannel.Result) {
        private val answered = AtomicBoolean(false)

        fun success(value: Any?): Boolean {
            if (!answered.compareAndSet(false, true)) return false
            result.success(value)
            return true
        }

        fun error(code: String, message: String): Boolean {
            if (!answered.compareAndSet(false, true)) return false
            result.error(code, message, null)
            return true
        }

        val isAnswered: Boolean get() = answered.get()
    }

    private val wifi: WifiManager =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var scanReceiver: BroadcastReceiver? = null

    /**
     * Nearby devices offering to be set up.
     *
     * The scan is driven here rather than left to the vendor client, for one
     * reason: this has to be able to tell "the phone looked and there was
     * nothing" apart from "the phone would not look". They arrive as the same
     * empty list, and only the first of them means what the screen would say.
     */
    fun discover(result: MethodChannel.Result) {
        val pending = PendingResult(result)
        if (!wifi.isWifiEnabled) {
            pending.error("WIFI_DISABLED", "Wi-Fi is switched off")
            return
        }
        // Holding the permission is not the same as the service being on, and
        // Android withholds scan results for either reason without saying
        // which. Untangled here, because the two are fixed in different
        // places and neither of them is the device.
        if (!isLocationEnabled()) {
            pending.error("LOCATION_SERVICES_OFF", "Location services are switched off")
            return
        }
        synchronized(lock) {
            if (scanReceiver != null) {
                pending.error("DEVICE_SCAN_BUSY", "A device scan is already running")
                return
            }
        }

        val timeout = Runnable { finishScan(pending) }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                mainHandler.removeCallbacks(timeout)
                finishScan(pending)
            }
        }
        synchronized(lock) { scanReceiver = receiver }
        val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.applicationContext.registerReceiver(
                receiver,
                filter,
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.applicationContext.registerReceiver(receiver, filter)
        }

        val started = wifi.startScan()
        Log.i(TAG, "Asked for a Wi-Fi scan; the platform said $started")
        // Even a refused request is followed here rather than answered now: the
        // system may still publish results, and what is already cached may be
        // recent enough to count.
        mainHandler.postDelayed(timeout, SCAN_TIMEOUT_MILLIS)
    }

    private fun finishScan(pending: PendingResult) {
        if (pending.isAnswered) return
        synchronized(lock) {
            scanReceiver?.let {
                try {
                    context.applicationContext.unregisterReceiver(it)
                } catch (error: IllegalArgumentException) {
                    Log.w(TAG, "The scan receiver was already gone", error)
                }
            }
            scanReceiver = null
        }
        val results = try {
            wifi.scanResults
        } catch (error: SecurityException) {
            pending.error(
                "WIFI_PERMISSION_DENIED",
                error.message ?: "Nearby Wi-Fi permission is required",
            )
            return
        }
        val freshest = results.minOfOrNull { ageMillis(it) }
        val candidates = results
            .filter { it.ssidText().startsWith(AP_PREFIX) }
            .map { point ->
                mapOf(
                    "transportId" to point.ssidText(),
                    "displayName" to point.ssidText(),
                    "transportKind" to TRANSPORT_KIND,
                    "signalStrength" to point.level,
                )
            }
        Log.i(
            TAG,
            "Scan carried ${results.size} network(s), freshest ${freshest}ms old, " +
                "${candidates.size} of them offering setup",
        )
        if (candidates.isEmpty() &&
            (freshest == null || freshest > FRESH_SCAN_MILLIS)
        ) {
            // Nothing was found, and nothing was looked at either. Saying "no
            // devices" here would send a person to check a device that is
            // sitting right there, waiting, in setup mode.
            pending.error(
                "DEVICE_SCAN_STALE",
                "The phone did not scan just now",
            )
            return
        }
        pending.success(candidates)
    }

    private fun isLocationEnabled(): Boolean {
        val manager = context.applicationContext
            .getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.isLocationEnabled
        } else {
            manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    private fun ageMillis(result: ScanResult): Long =
        SystemClock.elapsedRealtime() - result.timestamp / 1000

    @Suppress("DEPRECATION")
    private fun ScanResult.ssidText(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            wifiSsid?.toString()?.trim('"').orEmpty().ifEmpty { SSID.orEmpty() }
        } else {
            SSID.orEmpty()
        }

    /**
     * Join a device's setup network, authenticate, and read what it says it is.
     */
    fun open(transportId: String, result: MethodChannel.Result) {
        synchronized(lock) {
            if (connectResult?.isAnswered == false) {
                result.error(
                    "PROVISIONING_BUSY",
                    "A device setup session is already opening",
                    null,
                )
                return
            }
            releaseDeviceLocked()
            subscribeLocked()

            val espDevice = provisioning.createESPDevice(
                ESPConstants.TransportType.TRANSPORT_SOFTAP,
                ESPConstants.SecurityType.SECURITY_2,
            )
            espDevice.userName = SECURITY_USERNAME
            espDevice.proofOfPossession = SECURITY_PASSPHRASE
            espDevice.deviceName = transportId
            device = espDevice
            connectResult = PendingResult(result)
            // Open network: an unprovisioned device cannot hold a secret that
            // the phone approaching it for the first time would already know.
            espDevice.connectWiFiDevice(transportId, "")
        }
    }

    @Subscribe(threadMode = ThreadMode.MAIN)
    fun onDeviceConnectionEvent(event: DeviceConnectionEvent) {
        val pending = synchronized(lock) { connectResult } ?: return
        if (pending.isAnswered) return
        when (event.eventType) {
            ESPConstants.EVENT_DEVICE_CONNECTED -> readDescriptor(pending)
            ESPConstants.EVENT_DEVICE_CONNECTION_FAILED ->
                failConnection(
                    pending,
                    "DEVICE_UNREACHABLE",
                    "Could not open a setup session with the device",
                )
            ESPConstants.EVENT_DEVICE_DISCONNECTED ->
                failConnection(
                    pending,
                    "DEVICE_DISCONNECTED",
                    "The device closed the setup session",
                )
        }
    }

    private fun failConnection(pending: PendingResult, code: String, message: String) {
        synchronized(lock) { releaseDeviceLocked() }
        pending.error(code, message)
    }

    private fun readDescriptor(pending: PendingResult) {
        val espDevice = synchronized(lock) { device }
        if (espDevice == null) {
            pending.error("PROVISIONING_CLOSED", "The setup session is no longer open")
            return
        }
        espDevice.sendDataToCustomEndPoint(
            DESCRIPTOR_ENDPOINT,
            // Asking nothing still has to be said with something. protocomm
            // encrypts every payload, and a zero-length one fails inside the
            // security layer before the device's own handler is reached — so
            // the device cannot answer, and cannot say why either. The
            // descriptor endpoint ignores what it is sent; it only has to be
            // sent something.
            EMPTY_REQUEST,
            object : ResponseListener {
                override fun onSuccess(response: ByteArray?) {
                    val descriptor = response?.toString(StandardCharsets.UTF_8).orEmpty()
                    mainHandler.post {
                        if (descriptor.isEmpty()) {
                            failConnection(
                                pending,
                                "DESCRIPTOR_EMPTY",
                                "The device did not say what it is",
                            )
                        } else {
                            pending.success(descriptor)
                        }
                    }
                }

                override fun onFailure(error: Exception?) {
                    Log.w(TAG, "The device did not answer the descriptor endpoint", error)
                    mainHandler.post {
                        // Carried through rather than replaced by a sentence.
                        // Three different faults have already ended here — a
                        // permission, a dangling pointer on the device, an
                        // empty payload — and every one of them read as "the
                        // device did not answer", which sent the search to the
                        // one place that was never at fault.
                        failConnection(
                            pending,
                            "DESCRIPTOR_UNAVAILABLE",
                            listOfNotNull(
                                error?.javaClass?.simpleName,
                                error?.message,
                            ).joinToString(": ").ifEmpty {
                                "The device did not say what it is"
                            },
                        )
                    }
                }
            },
        )
    }

    /** What the device can see from where it stands. */
    fun scanNetworks(result: MethodChannel.Result) {
        val espDevice = synchronized(lock) { device }
        if (espDevice == null) {
            result.error("PROVISIONING_CLOSED", "No setup session is open", null)
            return
        }
        val pending = PendingResult(result)
        espDevice.scanNetworks(object : WiFiScanListener {
            override fun onWifiListReceived(points: ArrayList<WiFiAccessPoint>?) {
                val networks = (points ?: arrayListOf())
                    .mapNotNull { point ->
                        val ssid = point.wifiName?.takeIf { it.isNotEmpty() }
                            ?: return@mapNotNull null
                        mapOf(
                            "ssid" to ssid,
                            "signalStrength" to point.rssi,
                            "security" to securityLabel(point.security),
                        )
                    }
                mainHandler.post { pending.success(networks) }
            }

            override fun onWiFiScanFailed(error: Exception?) {
                Log.w(TAG, "The device could not scan for networks", error)
                mainHandler.post {
                    pending.error(
                        "DEVICE_SCAN_FAILED",
                        error?.message ?: "The device could not scan for networks",
                    )
                }
            }
        })
    }

    /** Tell the device which Host it belongs to, and hear whether it agrees. */
    fun handOverTrust(payloadJson: String, result: MethodChannel.Result) {
        val espDevice = synchronized(lock) { device }
        if (espDevice == null) {
            result.error("PROVISIONING_CLOSED", "No setup session is open", null)
            return
        }
        val pending = PendingResult(result)
        espDevice.sendDataToCustomEndPoint(
            TRUST_ENDPOINT,
            payloadJson.toByteArray(StandardCharsets.UTF_8),
            object : ResponseListener {
                override fun onSuccess(response: ByteArray?) {
                    val answer = response?.toString(StandardCharsets.UTF_8).orEmpty()
                    mainHandler.post {
                        if (answer.isEmpty()) {
                            pending.error(
                                "TRUST_UNANSWERED",
                                "The device did not answer whether it accepted the Host",
                            )
                        } else {
                            pending.success(answer)
                        }
                    }
                }

                override fun onFailure(error: Exception?) {
                    Log.w(TAG, "The device did not answer the trust endpoint", error)
                    mainHandler.post {
                        pending.error(
                            "TRUST_UNANSWERED",
                            error?.message
                                ?: "The device did not answer whether it accepted the Host",
                        )
                    }
                }
            },
        )
    }

    /**
     * Hand the device its network, and stop being in the way.
     *
     * Silence after the credentials were applied is not failure. The device
     * leaves its own access point in order to join the network it was just
     * given, which is exactly what takes this session down — so the answer to
     * "did it work" was never going to arrive here. It is asked of the Host,
     * which is where enrolment is a fact. A device that *refused* has said
     * something, and that is reported.
     */
    fun configureNetwork(ssid: String, password: String, result: MethodChannel.Result) {
        val espDevice = synchronized(lock) { device }
        if (espDevice == null) {
            result.error("PROVISIONING_CLOSED", "No setup session is open", null)
            return
        }
        val pending = PendingResult(result)
        val applied = AtomicBoolean(false)

        fun finish(success: Boolean, code: String = "", message: String = "") {
            mainHandler.post {
                // The session's work is over either way, and the next question
                // this app asks goes to the Host over the home network.
                close()
                if (success) pending.success(null) else pending.error(code, message)
            }
        }

        espDevice.provision(
            ssid,
            password,
            object : ProvisionListener {
                override fun createSessionFailed(error: Exception?) =
                    finish(false, "PROVISIONING_SESSION_FAILED", errorText(error))

                override fun wifiConfigSent() = Unit

                override fun wifiConfigFailed(error: Exception?) =
                    finish(false, "NETWORK_REJECTED", errorText(error))

                override fun wifiConfigApplied() {
                    applied.set(true)
                }

                override fun wifiConfigApplyFailed(error: Exception?) =
                    finish(false, "NETWORK_REJECTED", errorText(error))

                override fun provisioningFailedFromDevice(
                    reason: ESPConstants.ProvisionFailureReason?,
                ) = finish(false, "DEVICE_REFUSED_NETWORK", reason?.name ?: "unknown")

                override fun deviceProvisioningSuccess() = finish(true)

                override fun onProvisioningFailed(error: Exception?) {
                    // Reached when the device stopped answering. Before the
                    // credentials were applied that is a failure; after, it is
                    // the expected shape of success and the Host will say.
                    if (applied.get()) {
                        finish(true)
                    } else {
                        finish(false, "PROVISIONING_FAILED", errorText(error))
                    }
                }
            },
        )
    }

    /** Leave the device alone and give the phone its own network back. */
    fun close() {
        synchronized(lock) { releaseDeviceLocked() }
    }

    fun destroy() {
        synchronized(lock) {
            scanReceiver?.let {
                try {
                    context.applicationContext.unregisterReceiver(it)
                } catch (error: IllegalArgumentException) {
                    Log.w(TAG, "The scan receiver was already gone", error)
                }
            }
            scanReceiver = null
            releaseDeviceLocked()
            if (subscribed) {
                EventBus.getDefault().unregister(this)
                subscribed = false
            }
        }
    }

    private fun subscribeLocked() {
        if (subscribed) return
        EventBus.getDefault().register(this)
        subscribed = true
    }

    private fun releaseDeviceLocked() {
        device?.let { espDevice ->
            try {
                // Also what releases the process from the device's network.
                espDevice.disconnectDevice()
            } catch (error: Exception) {
                Log.w(TAG, "Closing the setup session failed", error)
            }
        }
        device = null
        connectResult = null
    }

    private fun errorText(error: Exception?): String =
        error?.message ?: "The device did not accept the network"

    private fun securityLabel(security: Int): String = when (security.toShort()) {
        ESPConstants.WIFI_OPEN -> "open"
        ESPConstants.WIFI_WEP -> "wep"
        ESPConstants.WIFI_WPA_PSK -> "wpa"
        ESPConstants.WIFI_WPA2_PSK -> "wpa2"
        ESPConstants.WIFI_WPA_WPA2_PSK -> "wpa-wpa2"
        ESPConstants.WIFI_WPA2_ENTERPRISE -> "wpa2-enterprise"
        ESPConstants.WIFI_WPA3_PSK -> "wpa3"
        ESPConstants.WIFI_WPA2_WPA3_PSK -> "wpa2-wpa3"
        else -> "unknown"
    }
}
