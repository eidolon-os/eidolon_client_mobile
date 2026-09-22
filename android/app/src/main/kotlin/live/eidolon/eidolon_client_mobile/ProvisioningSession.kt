package live.eidolon.eidolon_client_mobile

import android.net.Network
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import com.espressif.provisioning.Session
import com.espressif.provisioning.security.Security2
import com.espressif.provisioning.listeners.ResponseListener
import com.espressif.provisioning.listeners.WiFiScanListener
import com.espressif.provisioning.WiFiAccessPoint
import java.io.IOException
import okhttp3.OkHttpClient
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.Response
import org.json.JSONObject

/** Main-thread protocol owner. Espressif still owns SRP, AEAD and protobuf. */
internal class ProvisioningSession(
    network: Network,
    private val handler: Handler,
    private val onInvalidated: (Exception) -> Unit,
) {
    private val exchange = ProvisioningExchangeLifecycle(::finishTermination)
    private val closed: Boolean get() = exchange.closed
    private var session: Session? = null
    private var scan: ProvisioningScan? = null
    private val transport = ProvisioningHttpTransport(
        OkHttpClient.Builder().socketFactory(network.socketFactory)
            .eventListenerFactory { object : EventListener() {
                private fun stage(call: Call, detail: String) {
                    Log.i("ProvisioningSession", "http path=${call.request().url.encodedPath} $detail")
                }
                override fun requestBodyEnd(call: Call, byteCount: Long) { stage(call, "request_sent bytes=$byteCount") }
                override fun responseHeadersEnd(call: Call, response: Response) {
                    stage(call, "headers code=${response.code} length=${response.header("Content-Length")} transfer=${response.header("Transfer-Encoding")}")
                }
                override fun responseBodyEnd(call: Call, byteCount: Long) { stage(call, "body_received bytes=$byteCount") }
                override fun callFailed(call: Call, ioe: IOException) { stage(call, "failed type=${ioe.javaClass.simpleName}") }
            } },
        { action -> handler.post { action() } },
    )

    fun open(username: String, password: String, listener: ResponseListener) {
        val reply = exchange.begin(listener) ?: return
        // Match the vendor probe: protocomm rejects a zero-length HTTP body.
        transport.sendConfigData("proto-ver", "ESP".toByteArray(Charsets.UTF_8), object : ResponseListener {
            override fun onSuccess(bytes: ByteArray?) {
                if (closed) return
                try {
                    val info = JSONObject(String(bytes ?: byteArrayOf(), Charsets.UTF_8)).getJSONObject("prov")
                    check(info.getInt("sec_ver") == 2) { "Device must support Security 2" }
                    val patch = info.optInt("sec_patch_ver", 0)
                    check(patch in 0..1) { "Unsupported Security 2 patch" }
                    val protocol = Session(transport, Security2(username, password, patch))
                    session = protocol
                    protocol.init(null, object : Session.SessionListener {
                        override fun OnSessionEstablished() { if (!closed) reply.onSuccess(byteArrayOf()) }
                        override fun OnSessionEstablishFailed(e: Exception?) { reply.onFailure(e) }
                    })
                } catch (e: Exception) { reply.onFailure(e) }
            }
            override fun onFailure(e: Exception?) { reply.onFailure(e) }
        })
    }

    fun sendDataToCustomEndPoint(path: String, data: ByteArray, listener: ResponseListener) {
        val protocol = session
        if (closed || protocol == null || !protocol.isEstablished) {
            listener.onFailure(IOException("Provisioning session closed"))
            return
        }
        val reply = exchange.begin(listener) ?: return
        val started = SystemClock.elapsedRealtime()
        Log.i("ProvisioningSession", "request path=$path")
        try {
            protocol.sendDataToDevice(path, data, object : ResponseListener {
                override fun onSuccess(bytes: ByteArray?) {
                    Log.i("ProvisioningSession", "response path=$path elapsed_ms=${SystemClock.elapsedRealtime() - started}")
                    reply.onSuccess(bytes)
                }
                override fun onFailure(e: Exception?) {
                    Log.w("ProvisioningSession", "failed path=$path elapsed_ms=${SystemClock.elapsedRealtime() - started}")
                    reply.onFailure(e)
                }
            })
        } catch (e: Exception) { reply.onFailure(e) }
    }

    fun scanNetworks(listener: WiFiScanListener) {
        if (scan != null) { listener.onWiFiScanFailed(IOException("Scan already running")); return }
        val operation = ProvisioningScan(
            { data, reply -> sendDataToCustomEndPoint("prov-scan", data, reply) },
            { delay, action -> handler.postDelayed({ if (!closed) action() }, delay) },
            { SystemClock.elapsedRealtime() },
            { points, error ->
                scan = null
                if (error != null) {
                    listener.onWiFiScanFailed(error)
                    terminate(error, notifyOwner = true)
                }
                else listener.onWifiListReceived(ArrayList(points.orEmpty().map { point ->
                    WiFiAccessPoint().apply {
                        wifiName = point.ssid.toStringUtf8()
                        rssi = point.rssi
                        security = point.authValue
                    }
                }))
            },
        )
        scan = operation
        operation.start()
    }

    // Security2 counters become ambiguous after an incomplete response. All
    // endpoints invalidate the visit; reconnect requires a fresh handshake.
    private fun terminate(error: Exception, notifyOwner: Boolean) =
        exchange.terminate(error, notifyOwner)

    private fun finishTermination(error: Exception, notifyOwner: Boolean, reply: ResponseListener?) {
        session = null
        val operation = scan
        scan = null
        // Let the operation preserve its own failure code or committed terminal
        // evidence before the manager releases the Android network lease.
        try {
            transport.close()
        } finally {
            try {
                reply?.onFailure(error)
            } finally {
                try { operation?.cancel() }
                finally { if (notifyOwner) onInvalidated(error) }
            }
        }
    }

    fun disconnectDevice() = terminate(IOException("Provisioning session closed"), notifyOwner = false)
}
