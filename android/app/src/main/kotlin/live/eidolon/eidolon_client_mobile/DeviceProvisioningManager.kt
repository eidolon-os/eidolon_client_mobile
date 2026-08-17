package live.eidolon.eidolon_client_mobile

import android.content.Context
import android.os.Handler
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

    /** Nearby devices offering to be set up, newest scan each time. */
    fun discover(result: MethodChannel.Result) {
        val pending = PendingResult(result)
        provisioning.searchWiFiEspDevices(
            AP_PREFIX,
            object : WiFiScanListener {
                override fun onWifiListReceived(points: ArrayList<WiFiAccessPoint>?) {
                    val candidates = (points ?: arrayListOf())
                        .mapNotNull { point ->
                            val ssid = point.wifiName?.takeIf { it.isNotEmpty() }
                                ?: return@mapNotNull null
                            mapOf(
                                "transportId" to ssid,
                                "displayName" to ssid,
                                "transportKind" to TRANSPORT_KIND,
                                "signalStrength" to point.rssi,
                            )
                        }
                    mainHandler.post { pending.success(candidates) }
                }

                override fun onWiFiScanFailed(error: Exception?) {
                    Log.w(TAG, "Scanning for setup networks failed", error)
                    mainHandler.post {
                        pending.error(
                            "DEVICE_SCAN_FAILED",
                            error?.message ?: "Scanning for devices failed",
                        )
                    }
                }
            },
        )
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
            ByteArray(0),
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
                        failConnection(
                            pending,
                            "DESCRIPTOR_UNAVAILABLE",
                            error?.message ?: "The device did not say what it is",
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
