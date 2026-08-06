package live.eidolon.eidolon_client_mobile

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URL
import java.net.Inet4Address
import java.net.InetAddress
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.concurrent.Executors
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager

internal class PinnedHttpsClient(private val mainHandler: Handler) {
    private val executor = Executors.newSingleThreadExecutor()

    fun request(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val url = URL(call.argument<String>("url") ?: error("url is required"))
                require(url.protocol == "https" && url.userInfo == null) {
                    "Pinned Local API requests require an HTTPS origin"
                }
                val method = call.argument<String>("method") ?: "GET"
                require(method in setOf("GET", "POST", "DELETE")) { "HTTP method is unsupported" }
                val expected = call.argument<String>("tlsSpkiFingerprint")
                    ?: error("tlsSpkiFingerprint is required")
                val body = call.argument<String>("body") ?: ""
                require(body.toByteArray(StandardCharsets.UTF_8).size <= 1024 * 1024) {
                    "Local API request body is too large"
                }
                val headers = (call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>())
                    .entries
                    .associate { it.key.toString() to it.value.toString() }

                val context = SSLContext.getInstance("TLS")
                context.init(
                    null,
                    arrayOf<TrustManager>(PinnedSpkiTrustManager(expected)),
                    SecureRandom(),
                )
                val connectionUrl = preferIpv4WhenAvailable(url)
                val connection = connectionUrl.openConnection() as HttpsURLConnection
                try {
                    connection.sslSocketFactory = context.socketFactory
                    // Local discovery returns an IP address, while the self-signed
                    // certificate is identified by the Host-signed SPKI pin. The
                    // pin is the endpoint authority; DNS hostname matching is not.
                    connection.hostnameVerifier = HostnameVerifier { _, _ -> true }
                    connection.instanceFollowRedirects = false
                    connection.connectTimeout = 8000
                    connection.readTimeout = 8000
                    connection.requestMethod = method
                    for ((name, value) in headers) connection.setRequestProperty(name, value)
                    if (body.isNotEmpty()) {
                        connection.doOutput = true
                        connection.outputStream.use {
                            it.write(body.toByteArray(StandardCharsets.UTF_8))
                        }
                    }
                    val statusCode = connection.responseCode
                    val stream = if (statusCode >= 400) connection.errorStream else connection.inputStream
                    val responseBody = stream?.use { it.readBytes() } ?: ByteArray(0)
                    require(responseBody.size <= 1024 * 1024) {
                        "Local API response body is too large"
                    }
                    val responseHeaders = connection.headerFields
                        .filterKeys { it != null }
                        .mapValues { it.value.joinToString(",") }
                    mainHandler.post {
                        result.success(
                            mapOf(
                                "statusCode" to statusCode,
                                "headers" to responseHeaders,
                                "body" to String(responseBody, StandardCharsets.UTF_8),
                            ),
                        )
                    }
                } finally {
                    connection.disconnect()
                }
            } catch (error: Throwable) {
                val message = error.message?.take(180) ?: "Pinned HTTPS request failed"
                Log.w("EidolonPinnedHttps", "${error.javaClass.simpleName}: $message")
                mainHandler.post { result.error("PINNED_HTTPS_FAILED", message, null) }
            }
        }
    }

    fun close() {
        executor.shutdownNow()
    }

    private fun preferIpv4WhenAvailable(url: URL): URL {
        val ipv4 = InetAddress.getAllByName(url.host).firstOrNull { it is Inet4Address }
            ?: return url
        return URI(
            url.protocol,
            null,
            ipv4.hostAddress,
            url.port,
            url.path,
            url.query,
            null,
        ).toURL()
    }
}
