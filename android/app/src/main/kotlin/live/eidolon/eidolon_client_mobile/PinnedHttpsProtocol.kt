package live.eidolon.eidolon_client_mobile

import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.Locale
import javax.net.ssl.SSLException

import java.net.InetAddress
import java.net.Inet4Address
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import okhttp3.Dns
import okhttp3.OkHttpClient

/** Address discovery changes only DNS. URL, Host, SNI and TLS name checking
 * remain tied to the original Authority; a wrong address cannot authenticate.
 */
internal fun buildPinnedHttpsClient(
    trustManager: X509TrustManager,
    addressHints: Map<String, String> = emptyMap(),
    hostSpkiPinned: Boolean = false,
    resolver: Dns = Dns.SYSTEM,
): OkHttpClient {
    val context = SSLContext.getInstance("TLS")
    context.init(null, arrayOf(trustManager), SecureRandom())
    val builder = OkHttpClient.Builder()
        .sslSocketFactory(context.socketFactory, trustManager)
        .dns(object : Dns {
          override fun lookup(hostname: String): List<InetAddress> {
            val address = addressHints[hostname]
            val resolved = if (address == null) resolver.lookup(hostname)
                else listOf(InetAddress.getByName(address))
            return resolved.sortedBy { it !is Inet4Address }
          }
        })
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
    // Controller TLS is identified by its signed SPKI. Owner-domain TLS must
    // retain the library's standard hostname verifier as well as its root CA.
    if (hostSpkiPinned) builder.hostnameVerifier { _, _ -> true }
    return builder.build()
}

internal const val PINNED_HTTPS_PROTOCOL_VERSION = 1
internal const val PINNED_HTTPS_MAX_BODY_BYTES = 1024 * 1024

private val HTTP_METHOD_TOKEN = Regex("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
private val FORBIDDEN_LOCAL_METHODS = setOf("CONNECT", "TRACE")

/**
 * Validates transport syntax without duplicating the Local API's route/method
 * contract in the Android adapter. Authorization remains a server concern.
 */
internal fun normalizePinnedHttpMethod(value: String): String {
    val method = value.trim().uppercase(Locale.ROOT)
    require(method.isNotEmpty() && HTTP_METHOD_TOKEN.matches(method)) {
        "HTTP method is invalid"
    }
    require(method !in FORBIDDEN_LOCAL_METHODS) {
        "HTTP method is not allowed for the Local API transport"
    }
    return method
}

internal fun validatePinnedHttpHeaders(headers: Map<String, String>) {
    for ((name, value) in headers) {
        require(HTTP_METHOD_TOKEN.matches(name)) { "HTTP header name is invalid" }
        require('\r' !in value && '\n' !in value) { "HTTP header value is invalid" }
    }
}

internal fun pinnedHttpsErrorCode(error: Exception): String = when (error) {
    is IllegalArgumentException -> "PINNED_HTTPS_INVALID_REQUEST"
    is SocketTimeoutException -> "PINNED_HTTPS_TIMEOUT"
    is SSLException -> "PINNED_HTTPS_SECURE_CHANNEL_FAILED"
    is UnknownHostException,
    is ConnectException,
    is NoRouteToHostException -> "PINNED_HTTPS_UNREACHABLE"
    is IOException -> "PINNED_HTTPS_IO_FAILED"
    else -> "PINNED_HTTPS_INTERNAL_FAILED"
}
