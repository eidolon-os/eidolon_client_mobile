package live.eidolon.eidolon_client_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
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
import com.espressif.provisioning.listeners.ResponseListener
import com.espressif.provisioning.listeners.WiFiScanListener
import com.espressif.provisioning.utils.MessengeHelper
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.greenrobot.eventbus.EventBus
import org.greenrobot.eventbus.Subscribe
import org.greenrobot.eventbus.ThreadMode
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicBoolean
import espressif.Constants
import espressif.NetworkConfig

/**
 * The Android half of device provisioning: protocomm over the device's own
 * access point.
 *
 * A device that has never been set up offers a Wi-Fi network named
 * `eidolon-<mac tail>` and speaks Espressif's provisioning protocol on it —
 * protobuf over HTTP, inside an SRP6a-authenticated session (Security 2). That
 * protocol is not reimplemented here. It is the vendor's own wire format for
 * the vendor's own firmware, and the vendor's client is what talks it; this
 * class is the part that belongs to Eidolon: which devices count, what is asked
 * of them, and in what order.
 *
 * Two things are worth knowing before reading further.
 *
 * The vendor client binds the process to the device's network while a session
 * is open, because that access point has no route to anything else. Eidolon,
 * rather than the vendor convenience API, owns that route lease: it is released
 * only after committed terminal evidence has been read and acknowledged. The
 * next Host request can therefore never race the final device request.
 *
 * Owner trust is staged before the network candidate. The device keeps the
 * provisioning service alive through validation and atomic commit, then the
 * controller sends the canonical terminal ACK before either side tears down
 * the transport.
 */
class DeviceProvisioningManager(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "EidolonDeviceSetup"

        /** What an unprovisioned Eidolon device calls its setup network. */
        private const val AP_PREFIX = "eidolon-"

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
        private const val STATUS_ENDPOINT = "eidolon-status"
        private const val TERMINAL_ACK_ENDPOINT = "eidolon-terminal-ack"
        private const val PROV_CONFIG_ENDPOINT = "prov-config"

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

        /** How long to wait for the phone to actually be on the device's network. */
        private const val JOIN_TIMEOUT_MILLIS = 60_000
        private const val TERMINAL_TIMEOUT_MILLIS = 30_000L
        private const val TERMINAL_POLL_MILLIS = 500L
    }

    private val provisioning: ESPProvisionManager =
        ESPProvisionManager.getInstance(context.applicationContext)
    private val connectivity = context.applicationContext
        .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
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
     *
     * The joining is done here rather than left to the vendor client, and the
     * reason is a real failure: a device's setup network has no route to the
     * internet, Android notices within about twelve seconds, and moves the
     * phone back to a network that has one — in the middle of the handshake.
     * The device saw the phone arrive, start authenticating, and leave.
     *
     * So the network is requested as local-only and *held* for as long as the
     * session lasts. That is what tells Android this network is wanted despite
     * having nothing behind it. The same discipline was already in this app
     * once, in the path this one replaced.
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
            connectResult = PendingResult(result)
        }
        joinDeviceNetwork(transportId)
    }

    private fun joinDeviceNetwork(transportId: String) {
        val pending = synchronized(lock) { connectResult } ?: return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // Without this, Android validates the network, finds no internet
            // behind it, and drops it — which is exactly what happened.
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(
                WifiNetworkSpecifier.Builder().setSsid(transportId).build(),
            )
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.i(TAG, "Joined the device's setup network")
                // Every request this process makes now goes over the device's
                // network. The commissioning adapter retains this lease through
                // committed terminal evidence and its ACK, then releases it
                // before the next Host request.
                connectivity.bindProcessToNetwork(network)
                mainHandler.post { startSession(transportId, pending) }
            }

            override fun onUnavailable() {
                Log.w(TAG, "The device's setup network was not joined")
                mainHandler.post {
                    failConnection(
                        pending,
                        "DEVICE_UNREACHABLE",
                        "Could not join the device's setup network",
                    )
                }
            }

            override fun onLost(network: Network) {
                Log.w(TAG, "The device's setup network went away")
                mainHandler.post {
                    failConnection(
                        pending,
                        "DEVICE_DISCONNECTED",
                        "The device's setup network went away",
                    )
                }
            }
        }
        synchronized(lock) { networkCallback = callback }
        try {
            connectivity.requestNetwork(request, callback, JOIN_TIMEOUT_MILLIS)
        } catch (error: SecurityException) {
            Log.e(TAG, "Android refused the local-only network request", error)
            failConnection(
                pending,
                "WIFI_PERMISSION_DENIED",
                error.message ?: "Android refused the device network request",
            )
        }
    }

    private fun startSession(transportId: String, pending: PendingResult) {
        val espDevice = provisioning.createESPDevice(
            ESPConstants.TransportType.TRANSPORT_SOFTAP,
            ESPConstants.SecurityType.SECURITY_2,
        )
        espDevice.userName = SECURITY_USERNAME
        espDevice.proofOfPossession = SECURITY_PASSPHRASE
        espDevice.deviceName = transportId
        synchronized(lock) { device = espDevice }
        // The phone is already on the device's network and stays there, so this
        // is the variant that authenticates rather than the one that joins.
        espDevice.connectWiFiDevice()
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

    /** Hand the device a network and return only device-confirmed terminal evidence. */
    fun configureNetwork(ssid: String, password: String, result: MethodChannel.Result) {
        val espDevice = synchronized(lock) { device }
        if (espDevice == null) {
            result.error("PROVISIONING_CLOSED", "No setup session is open", null)
            return
        }
        val pending = PendingResult(result)
        val lease = CommissioningClientLeaseCore()
        var terminalDeadlineMillis = SystemClock.elapsedRealtime() + TERMINAL_TIMEOUT_MILLIS
        var committedStatus: JSONObject? = null

        fun finish(success: Boolean, code: String = "", message: String = "") {
            mainHandler.post {
                // This is the one route-lease release point. No vendor callback
                // may unbind SoftAP before the Eidolon core reaches terminal.
                close()
                if (success) {
                    val status = committedStatus
                    if (status == null) {
                        pending.error(
                            "COMMISSIONING_STATUS_MISSING",
                            "Committed terminal evidence was not retained",
                        )
                        return@post
                    }
                    pending.success(mapOf(
                        "contract" to status.getString("contract"),
                        "contract_version" to status.getString("contract_version"),
                        "profile_id" to status.getString("profile_id"),
                        "session_id" to status.getString("session_id"),
                        "setup_generation" to status.getLong("setup_generation"),
                        "state_revision" to status.getLong("state_revision"),
                        "state" to status.getString("state"),
                        "conditions" to mapOf(
                            "wifi_connected" to true,
                            "owner_route_validated" to true,
                            "trust_committed" to true,
                            "network_committed" to true,
                        ),
                        "failure_code" to null,
                    ))
                } else {
                    pending.error(code, message)
                }
            }
        }

        fun fail(code: String, message: String) {
            if (lease.handle(CommissioningClientLeaseEvent.Failed) ==
                CommissioningClientLeaseAction.ReleaseFailed
            ) {
                Log.w(TAG, "Commissioning client lease failed: $code: $message")
                finish(false, code, message)
            }
        }

        lateinit var sendNetworkCandidate: () -> Unit
        lateinit var applyNetworkCandidate: () -> Unit
        lateinit var readCommittedTerminal: () -> Unit
        lateinit var sendTerminalAck: () -> Unit

        sendTerminalAck = {
            val status = committedStatus
            if (status == null) {
                fail("COMMISSIONING_STATUS_MISSING", "No committed status to acknowledge")
            } else {
                val ack = JSONObject()
                    .put("contract", "eidolon.device-foundation.commissioning-terminal-ack")
                    .put("contract_version", "1.0")
                    .put("session_id", status.getString("session_id"))
                    .put("setup_generation", status.getLong("setup_generation"))
                    .put("observed_state_revision", status.getLong("state_revision"))
                espDevice.sendDataToCustomEndPoint(
                    TERMINAL_ACK_ENDPOINT,
                    ack.toString().toByteArray(StandardCharsets.UTF_8),
                    object : ResponseListener {
                        override fun onSuccess(response: ByteArray?) {
                            val acknowledged = try {
                                JSONObject(
                                    response?.toString(StandardCharsets.UTF_8).orEmpty(),
                                ).optBoolean("acknowledged", false)
                            } catch (error: Exception) {
                                fail("TERMINAL_ACK_INVALID", errorText(error))
                                return
                            }
                            if (!acknowledged) {
                                fail(
                                    "TERMINAL_ACK_REFUSED",
                                    "Device refused commissioning terminal ACK",
                                )
                                return
                            }
                            if (lease.handle(
                                    CommissioningClientLeaseEvent.TerminalAckAccepted,
                                ) == CommissioningClientLeaseAction.ReleaseSucceeded
                            ) {
                                Log.i(TAG, "Committed terminal ACK accepted; releasing SoftAP")
                                finish(true)
                            }
                        }

                        override fun onFailure(error: Exception?) =
                            fail("TERMINAL_ACK_FAILED", errorText(error))
                    },
                )
            }
        }

        readCommittedTerminal = {
            espDevice.sendDataToCustomEndPoint(
                STATUS_ENDPOINT,
                EMPTY_REQUEST,
                object : ResponseListener {
                    override fun onSuccess(response: ByteArray?) {
                        val body = response?.toString(StandardCharsets.UTF_8).orEmpty()
                        try {
                            val status = JSONObject(body)
                            val conditions = status.getJSONObject("conditions")
                            val committed =
                                status.getString("contract") ==
                                    "eidolon.device-foundation.commissioning-status" &&
                                status.getString("contract_version") == "1.0" &&
                                status.getString("state") == "committed" &&
                                status.isNull("failure_code") &&
                                conditions.getBoolean("wifi_connected") &&
                                conditions.getBoolean("owner_route_validated") &&
                                conditions.getBoolean("trust_committed") &&
                                conditions.getBoolean("network_committed")
                            if (!committed &&
                                status.optString("state") == "applying-configuration"
                            ) {
                                if (SystemClock.elapsedRealtime() >= terminalDeadlineMillis) {
                                    fail(
                                        "COMMISSIONING_TERMINAL_TIMEOUT",
                                        "Device did not publish terminal evidence in time",
                                    )
                                    return
                                }
                                if (lease.handle(CommissioningClientLeaseEvent.StatusApplying) ==
                                    CommissioningClientLeaseAction.ReadTerminalStatus
                                ) {
                                    mainHandler.postDelayed(
                                        { readCommittedTerminal() },
                                        TERMINAL_POLL_MILLIS,
                                    )
                                }
                                return
                            }
                            if (!committed) {
                                fail(
                                    "COMMISSIONING_NOT_COMMITTED",
                                    "Device did not commit network and Owner trust",
                                )
                                return
                            }
                            committedStatus = status
                            if (lease.handle(CommissioningClientLeaseEvent.StatusCommitted) ==
                                CommissioningClientLeaseAction.SendTerminalAck
                            ) {
                                Log.i(TAG, "Observed committed terminal evidence")
                                sendTerminalAck()
                            }
                        } catch (error: Exception) {
                            fail("COMMISSIONING_STATUS_INVALID", errorText(error))
                        }
                    }

                    override fun onFailure(error: Exception?) =
                        fail("COMMISSIONING_STATUS_UNAVAILABLE", errorText(error))
                },
            )
        }

        applyNetworkCandidate = {
            espDevice.sendDataToCustomEndPoint(
                PROV_CONFIG_ENDPOINT,
                MessengeHelper.prepareApplyWiFiConfigMsg(),
                object : ResponseListener {
                    override fun onSuccess(response: ByteArray?) {
                        val accepted = try {
                            val payload = NetworkConfig.NetworkConfigPayload.parseFrom(
                                response ?: byteArrayOf(),
                            )
                            payload.hasRespApplyWifiConfig() &&
                                payload.respApplyWifiConfig.status == Constants.Status.Success
                        } catch (error: Exception) {
                            fail("NETWORK_APPLY_RESPONSE_INVALID", errorText(error))
                            return
                        }
                        if (!accepted) {
                            fail("NETWORK_APPLY_REJECTED", "Device rejected Wi-Fi apply")
                            return
                        }
                        terminalDeadlineMillis =
                            SystemClock.elapsedRealtime() + TERMINAL_TIMEOUT_MILLIS
                        if (lease.handle(CommissioningClientLeaseEvent.ConfigurationApplied) ==
                            CommissioningClientLeaseAction.ReadTerminalStatus
                        ) {
                            Log.i(TAG, "Wi-Fi candidate applied; retaining SoftAP for terminal evidence")
                            readCommittedTerminal()
                        }
                    }

                    override fun onFailure(error: Exception?) =
                        fail("NETWORK_APPLY_UNAVAILABLE", errorText(error))
                },
            )
        }

        sendNetworkCandidate = {
            espDevice.sendDataToCustomEndPoint(
                PROV_CONFIG_ENDPOINT,
                MessengeHelper.prepareWiFiConfigMsg(ssid, password),
                object : ResponseListener {
                    override fun onSuccess(response: ByteArray?) {
                        val accepted = try {
                            val payload = NetworkConfig.NetworkConfigPayload.parseFrom(
                                response ?: byteArrayOf(),
                            )
                            payload.hasRespSetWifiConfig() &&
                                payload.respSetWifiConfig.status == Constants.Status.Success
                        } catch (error: Exception) {
                            fail("NETWORK_CANDIDATE_RESPONSE_INVALID", errorText(error))
                            return
                        }
                        if (!accepted) {
                            fail("NETWORK_CANDIDATE_REJECTED", "Device rejected Wi-Fi credentials")
                            return
                        }
                        if (lease.handle(
                                CommissioningClientLeaseEvent.NetworkCandidateAccepted,
                            ) == CommissioningClientLeaseAction.ApplyNetworkCandidate
                        ) {
                            Log.i(TAG, "Wi-Fi candidate accepted; applying under the same lease")
                            applyNetworkCandidate()
                        }
                    }

                    override fun onFailure(error: Exception?) =
                        fail("NETWORK_CANDIDATE_UNAVAILABLE", errorText(error))
                },
            )
        }

        if (lease.handle(CommissioningClientLeaseEvent.Start) ==
            CommissioningClientLeaseAction.SendNetworkCandidate
        ) {
            Log.i(TAG, "Starting Eidolon-owned commissioning client lease")
            sendNetworkCandidate()
        }
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
        networkCallback?.let { callback ->
            try {
                connectivity.unregisterNetworkCallback(callback)
            } catch (error: IllegalArgumentException) {
                Log.w(TAG, "The device network request was already gone", error)
            }
        }
        networkCallback = null
        // Give the phone its own network back before anything else is asked of
        // it — the Host is not on the device's access point.
        connectivity.bindProcessToNetwork(null)
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
