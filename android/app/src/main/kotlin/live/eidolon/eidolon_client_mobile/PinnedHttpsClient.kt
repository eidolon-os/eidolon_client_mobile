package live.eidolon.eidolon_client_mobile

import android.os.Handler
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.URI
import java.net.URL
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
                require(call.argument<Int>("protocolVersion") == PINNED_HTTPS_PROTOCOL_VERSION) {
                    "Pinned HTTPS protocol version is unsupported"
                }
                val url = URL(call.argument<String>("url") ?: error("url is required"))
                require(url.protocol == "https" && url.userInfo == null) {
                    "Pinned Local API requests require an HTTPS origin"
                }
                val method = normalizePinnedHttpMethod(
                    call.argument<String>("method") ?: "GET",
                )
                val expected = call.argument<String>("tlsSpkiFingerprint")
                    ?: error("tlsSpkiFingerprint is required")
                val body = Base64.decode(
                    call.argument<String>("bodyBase64") ?: "",
                    Base64.DEFAULT,
                )
                require(body.size <= PINNED_HTTPS_MAX_BODY_BYTES) {
                    "Local API request body is too large"
                }
                val headers = (call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>())
                    .entries
                    .associate { it.key.toString() to it.value.toString() }
                validatePinnedHttpHeaders(headers)

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
                            it.write(body)
                        }
                    }
                    val statusCode = connection.responseCode
                    val stream = if (statusCode >= 400) connection.errorStream else connection.inputStream
                    val responseBody = stream?.use { readBounded(it) } ?: ByteArray(0)
                    val responseHeaders = connection.headerFields
                        .filterKeys { it != null }
                        .mapValues { it.value.joinToString(",") }
                    mainHandler.post {
                        result.success(
                            mapOf(
                                "protocolVersion" to PINNED_HTTPS_PROTOCOL_VERSION,
                                "statusCode" to statusCode,
                                "headers" to responseHeaders,
                                "bodyBase64" to Base64.encodeToString(
                                    responseBody,
                                    Base64.NO_WRAP,
                                ),
                            ),
                        )
                    }
                } finally {
                    connection.disconnect()
                }
            } catch (error: Exception) {
                val message = error.message?.take(180) ?: "Pinned HTTPS request failed"
                Log.w("EidolonPinnedHttps", "${error.javaClass.simpleName}: $message")
                mainHandler.post {
                    result.error(
                        pinnedHttpsErrorCode(error),
                        message,
                        mapOf("exceptionType" to error.javaClass.simpleName),
                    )
                }
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
