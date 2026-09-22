package live.eidolon.eidolon_client_mobile

import com.espressif.provisioning.listeners.ResponseListener
import com.espressif.provisioning.transport.Transport
import java.io.Closeable
import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody

/** One visit to one device. Cookies, sockets and cancellation never cross visits. */
internal class ProvisioningHttpTransport(
    builder: OkHttpClient.Builder,
    private val dispatch: (() -> Unit) -> Unit,
    private val baseUrl: String = "http://192.168.4.1/",
    // Device trust actor may wait up to 15s; let its bounded refusal arrive.
    timeoutMillis: Long = 20_000,
) : Transport, Closeable {
    private val lock = Any()
    private var closed = false
    private val pending = mutableMapOf<Call, ResponseListener>()
    private val cookies = mutableListOf<Cookie>()
    private val client = builder
        .connectTimeout(5_000, TimeUnit.MILLISECONDS)
        .readTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
        .callTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
        // An authenticated message consumes a nonce. Never replay a POST after
        // an ambiguous response, redirect it, or move it to a different network.
        .retryOnConnectionFailure(false).followRedirects(false).followSslRedirects(false)
        .cookieJar(object : CookieJar {
            override fun saveFromResponse(url: HttpUrl, values: List<Cookie>) = synchronized(lock) {
                if (closed) return@synchronized
                values.forEach { cookie ->
                    cookies.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
                    cookies.add(cookie)
                }
            }
            override fun loadForRequest(url: HttpUrl): List<Cookie> = synchronized(lock) {
                cookies.filter { it.matches(url) && it.expiresAt > System.currentTimeMillis() }
            }
        }).build()

    override fun sendConfigData(path: String, data: ByteArray, listener: ResponseListener) {
        require(path.matches(Regex("[a-z0-9-]+")))
        val request = Request.Builder().url(baseUrl + path)
            .post(data.toRequestBody("application/octet-stream".toMediaType())).build()
        synchronized(lock) {
            if (closed) {
                dispatch { listener.onFailure(IOException("Provisioning session closed")) }
                return
            }
            val call = client.newCall(request)
            pending[call] = listener
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) = complete(call, null, e)
                override fun onResponse(call: Call, response: Response) {
                    try {
                        val bytes = response.use {
                            if (!it.isSuccessful) throw IOException("Provisioning HTTP ${it.code} at $path")
                            val body = it.body ?: throw IOException("Empty provisioning response at $path")
                            body.byteStream().use { input ->
                                val output = java.io.ByteArrayOutputStream()
                                val chunk = ByteArray(4096)
                                while (true) {
                                    val count = input.read(chunk)
                                    if (count < 0) break
                                    if (output.size() + count > 128 * 1024) throw IOException("Provisioning response too large")
                                    output.write(chunk, 0, count)
                                }
                                output.toByteArray()
                            }
                        }
                        complete(call, bytes, null)
                    } catch (e: Exception) { complete(call, null, e) }
                }
            })
        }
    }

    private fun complete(call: Call, bytes: ByteArray?, error: Exception?) {
        // Claim completion on the protocol dispatcher, so close also fences a
        // response already read from the socket but not yet delivered.
        dispatch {
            val listener = synchronized(lock) { pending.remove(call) } ?: return@dispatch
            if (error != null) listener.onFailure(error) else listener.onSuccess(bytes)
        }
    }

    override fun close() {
        val cancelled = synchronized(lock) {
            if (closed) return
            closed = true
            pending.toMap().also { pending.clear(); cookies.clear() }
        }
        cancelled.forEach { (call, listener) ->
            call.cancel()
            dispatch { listener.onFailure(IOException("Provisioning session closed")) }
        }
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }
}
