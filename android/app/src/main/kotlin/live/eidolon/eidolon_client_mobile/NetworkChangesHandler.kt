package live.eidolon.eidolon_client_mobile

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.os.Handler
import io.flutter.plugin.common.EventChannel

/** Report route identity/address changes, including Wi-Fi -> another Wi-Fi. */
class NetworkChangesHandler(context: Context, private val main: Handler) : EventChannel.StreamHandler {
    private val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        close()
        var previous: String? = null
        val listener = object : ConnectivityManager.NetworkCallback() {
            fun publish() {
                main.post {
                    if (callback !== this) return@post
                    val network = connectivity.activeNetwork
                    val links = network?.let { connectivity.getLinkProperties(it) }
                    val signature = "${network?.networkHandle}:${links?.interfaceName}:" +
                        links?.linkAddresses?.map { it.toString() }?.sorted()?.joinToString(",")
                    if (signature != previous) {
                        previous = signature
                        events.success(signature)
                    }
                }
            }
            override fun onAvailable(network: Network) = publish()
            override fun onLost(network: Network) = publish()
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = publish()
        }
        callback = listener
        connectivity.registerDefaultNetworkCallback(listener)
        listener.publish()
    }

    override fun onCancel(arguments: Any?) = close()

    fun close() {
        val old = callback ?: return
        callback = null
        connectivity.unregisterNetworkCallback(old)
    }
}
