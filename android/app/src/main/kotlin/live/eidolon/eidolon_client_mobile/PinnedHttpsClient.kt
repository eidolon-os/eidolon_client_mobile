package live.eidolon.eidolon_client_mobile

import android.os.Handler
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URL
import java.security.KeyStore
import java.security.cert.CertificateFactory
import okhttp3.Call
import okhttp3.Callback
import okhttp3.EventListener
import okhttp3.Response
import okhttp3.Handshake
import java.net.InetSocketAddress
import java.net.Proxy
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import javax.net.ssl.TrustManagerFactory

internal class PinnedHttpsClient(private val mainHandler: Handler) {
    private val calls = PinnedHttpsCalls()

    fun request(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("requestId")
        try {
            require(!id.isNullOrBlank()) { "requestId is required" }
            require(call.argument<Int>("protocolVersion") == PINNED_HTTPS_PROTOCOL_VERSION) {
                "Pinned HTTPS protocol version is unsupported"
            }
            val url = URL(call.argument<String>("url") ?: error("url is required"))
            require(url.protocol == "https" && url.userInfo == null) {
                "Pinned Local API requests require an HTTPS origin"
            }
            val method = normalizePinnedHttpMethod(call.argument<String>("method") ?: "GET")
            val expected = call.argument<String>("tlsSpkiFingerprint")
            val ownerRootCertificate = call.argument<String>("ownerRootCertificate")
            require((expected == null) != (ownerRootCertificate == null)) {
                "exactly one endpoint trust mode is required"
            }
            val body = Base64.decode(call.argument<String>("bodyBase64") ?: "", Base64.DEFAULT)
            require(body.size <= PINNED_HTTPS_MAX_BODY_BYTES) { "Local API request body is too large" }
            val headers = (call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>())
                .entries.associate { it.key.toString() to it.value.toString() }
            validatePinnedHttpHeaders(headers)
            val trustManager = if (expected != null) PinnedSpkiTrustManager(expected)
                else ownerDomainTrustManagers(ownerRootCertificate!!)
                    .filterIsInstance<X509TrustManager>().single()
            val address = call.argument<String>("connectionAddress")
            require(address == null || (expected == null && url.host.endsWith(".local"))) {
                "Address hints are only valid for a local Owner Authority"
            }
            val started = System.nanoTime()
            var stage = "queued"
            val origin = "${url.protocol}://${url.host}:${if (url.port == -1) 443 else url.port}"
            // No credentials, query strings or response content enter diagnostics.
            val target = expected?.takeLast(8) ?: "owner-root"
            fun trace(outcome: String) {
                Log.d("EidolonPinnedHttps", "request=$id target=$target origin=$origin " +
                    "stage=$stage elapsedMs=${(System.nanoTime() - started) / 1_000_000} $outcome")
            }
            val client = buildPinnedHttpsClient(
                trustManager,
                if (address == null) emptyMap() else mapOf(url.host to address),
                hostSpkiPinned = expected != null,
            ).newBuilder().dispatcher(calls.dispatcher)
                .eventListener(object : EventListener() {
                    override fun dnsStart(call: Call, domainName: String) { stage = "dns" }
                    override fun connectStart(call: Call, address: InetSocketAddress, proxy: Proxy) { stage = "connect" }
                    override fun secureConnectStart(call: Call) { stage = "tls" }
                    override fun secureConnectEnd(call: Call, handshake: Handshake?) { stage = "request" }
                    override fun responseHeadersStart(call: Call) { stage = "response" }
                }).build()
            val request = Request.Builder().url(url.toString())
            for ((name, value) in headers) request.header(name, value)
            val requestBody = if (body.isNotEmpty() || method in setOf("POST", "PUT", "PATCH"))
                body.toRequestBody() else null
            request.method(method, requestBody)
            calls.enqueue(id, client, request.build(), object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    trace(if (call.isCanceled()) "cancelled" else error.javaClass.simpleName)
                    client.connectionPool.evictAll()
                    fail(result, error, call.isCanceled())
                }
                override fun onResponse(call: Call, response: Response) {
                    try {
                        response.use {
                            val responseBody = response.body?.byteStream()?.use { readBounded(it) }
                                ?: ByteArray(0)
                            val responseHeaders = response.headers.toMultimap()
                                .mapValues { it.value.joinToString(",") }
                            mainHandler.post {
                                result.success(mapOf(
                                    "protocolVersion" to PINNED_HTTPS_PROTOCOL_VERSION,
                                    "statusCode" to response.code,
                                    "headers" to responseHeaders,
                                    "bodyBase64" to Base64.encodeToString(responseBody, Base64.NO_WRAP),
                                ))
                            }
                        }
                        trace("completed")
                    } catch (error: Exception) {
                        trace(error.javaClass.simpleName)
                        fail(result, error, call.isCanceled())
                    } finally {
                        client.connectionPool.evictAll()
                    }
                }
            })
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    fun cancel(call: MethodCall, result: MethodChannel.Result) {
        call.argument<String>("requestId")?.let(calls::cancel)
        result.success(null)
    }

    private fun fail(result: MethodChannel.Result, error: Exception, cancelled: Boolean = false) {
        val message = error.message?.take(180) ?: "Pinned HTTPS request failed"
        Log.w("EidolonPinnedHttps", "${error.javaClass.simpleName}: $message")
        mainHandler.post {
            result.error(
                if (cancelled) "PINNED_HTTPS_CANCELLED" else pinnedHttpsErrorCode(error),
                message,
                mapOf("exceptionType" to error.javaClass.simpleName),
            )
        }
    }

    fun close() {
        calls.close()
    }

    private fun ownerDomainTrustManagers(certificatePem: String): Array<TrustManager> {
        val certificate = CertificateFactory.getInstance("X.509").generateCertificate(
            certificatePem.byteInputStream(Charsets.US_ASCII),
        )
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType())
        keyStore.load(null)
        keyStore.setCertificateEntry("eidolon-owner-root", certificate)
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(keyStore)
        return factory.trustManagers
    }

    private fun readBounded(stream: java.io.InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        var total = 0
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            total += count
            if (total > PINNED_HTTPS_MAX_BODY_BYTES) {
                throw IOException("Local API response body is too large")
            }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
}
