package live.eidolon.eidolon_client_mobile

/**
 * Gives the phone back the Wi-Fi a device visit took away.
 *
 * A device's setup network is joined with a network request of its own. On
 * Android 10 that connection *replaces* the phone's Wi-Fi — one radio, one
 * connection — and the platform build decides whether the phone's own
 * network comes back once the app lets go. Android 16 on HyperOS rejoins at
 * once; EMUI 10 (Huawei BAH3-W59) does not: auto-join stays switched off and
 * the phone sits with no network, while the app waits on it for the Host.
 * Unregistering the device request is therefore only half of giving the
 * radio back.
 *
 * The other half is the ordinary way an app tells Android it needs Wi-Fi: a
 * plain network request, no specifier. Android's own auto-join then brings
 * back a network the phone already knows; nothing here picks or names one.
 * The request is held only until a network other than the device's satisfies
 * it, so it never outlives its purpose. Where the phone never left (concurrent
 * connections) or the platform rejoins by itself, it is satisfied at once.
 *
 * [N] is the platform's network identity; tests use their own.
 */
internal class OwnWifiReturn<N : Any>(private val port: Port<N>) {
    internal interface Port<N : Any> {
        /**
         * Ask for an ordinary Wi-Fi network. [offered] reports each
         * network Android matches to the request, possibly more than once.
         * Returns what lets the request go.
         */
        fun requestOrdinaryWifi(offered: (N) -> Unit): () -> Unit
    }

    private var release: (() -> Unit)? = null
    private var leftNetwork: N? = null
    private var generation = 0

    /** True while the phone has not yet been given its own Wi-Fi back. */
    val returning: Boolean get() = release != null

    /**
     * A device visit let go of the radio. [deviceNetwork] is the setup network
     * it held, if it was ever joined; it may still be torn down when Android
     * first answers, and does not count as the phone's own network.
     */
    fun deviceNetworkReleased(deviceNetwork: N?) {
        settle()
        leftNetwork = deviceNetwork
        val current = ++generation
        release = port.requestOrdinaryWifi { network -> available(current, network) }
    }

    /** Another visit takes the radio; there is nothing to give back in between. */
    fun deviceVisitStarting() = settle()

    fun close() = settle()

    private fun available(requestGeneration: Int, network: N) {
        if (requestGeneration != generation || release == null) return
        if (network == leftNetwork) return
        settle()
    }

    private fun settle() {
        generation++
        val pending = release
        release = null
        leftNetwork = null
        pending?.invoke()
    }
}
