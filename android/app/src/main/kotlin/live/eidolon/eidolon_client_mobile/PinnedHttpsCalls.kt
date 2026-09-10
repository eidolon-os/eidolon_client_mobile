package live.eidolon.eidolon_client_mobile

import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dispatcher
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/** Owns native calls; scheduling and socket cancellation belong to OkHttp. */
internal class PinnedHttpsCalls {
    val dispatcher = Dispatcher().apply {
        maxRequests = 16
        maxRequestsPerHost = 4
    }
    private val pending = ConcurrentHashMap<String, Call>()
    private var closed = false

    @Synchronized
    fun enqueue(id: String, client: OkHttpClient, request: Request, callback: Callback) {
        check(!closed) { "Pinned HTTPS transport is closed" }
        require(client.dispatcher === dispatcher) { "Call must use the shared dispatcher" }
        val call = client.newCall(request)
        require(pending.putIfAbsent(id, call) == null) { "Duplicate requestId" }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, error: IOException) {
                try { callback.onFailure(call, error) }
                finally { pending.remove(id, call) }
            }
            override fun onResponse(call: Call, response: Response) {
                try { callback.onResponse(call, response) }
                finally { pending.remove(id, call) }
            }
        })
    }

    fun cancel(id: String) { pending[id]?.cancel() }

    @Synchronized
    fun close() {
        if (closed) return
        closed = true
        pending.values.forEach { it.cancel() }
        // Queued cancelled calls still receive their completion callback.
        dispatcher.idleCallback = Runnable { dispatcher.executorService.shutdown() }
        if (dispatcher.runningCallsCount() == 0) dispatcher.executorService.shutdown()
    }
}
