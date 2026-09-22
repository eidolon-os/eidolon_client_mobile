package live.eidolon.eidolon_client_mobile

import com.espressif.provisioning.listeners.ResponseListener
import java.io.IOException

/** Confined to the protocol dispatcher. One exchange per authenticated visit. */
internal class ProvisioningExchangeLifecycle(
    private val terminated: (Exception, Boolean, ResponseListener?) -> Unit,
) {
    var closed = false
        private set
    private var active: ResponseListener? = null

    fun begin(listener: ResponseListener): ResponseListener? {
        if (closed || active != null) {
            listener.onFailure(IOException(if (closed) "Provisioning session closed" else "Provisioning exchange already active"))
            return null
        }
        // Use a distinct token, even when callers reuse a listener instance.
        val token = object : ResponseListener {
            override fun onSuccess(bytes: ByteArray?) = listener.onSuccess(bytes)
            override fun onFailure(error: Exception?) = listener.onFailure(error)
        }
        active = token
        return object : ResponseListener {
            override fun onSuccess(bytes: ByteArray?) {
                if (closed || active !== token) return
                if (bytes == null) {
                    terminate(IOException("Invalid authenticated provisioning response"), true)
                    return
                }
                active = null
                token.onSuccess(bytes)
            }
            override fun onFailure(error: Exception?) {
                if (closed || active !== token) return
                terminate(error ?: IOException("Provisioning exchange failed"), true)
            }
        }
    }

    fun terminate(error: Exception, notifyOwner: Boolean) {
        if (closed) return
        closed = true
        val reply = active
        active = null
        terminated(error, notifyOwner, reply)
    }
}
