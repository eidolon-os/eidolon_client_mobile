package live.eidolon.eidolon_client_mobile

import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.Locale
import javax.net.ssl.SSLException

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
