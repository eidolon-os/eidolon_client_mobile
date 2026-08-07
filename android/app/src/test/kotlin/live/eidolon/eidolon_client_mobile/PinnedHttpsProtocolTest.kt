package live.eidolon.eidolon_client_mobile

import java.io.IOException
import java.net.SocketTimeoutException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import javax.net.ssl.SSLException

class PinnedHttpsProtocolTest {
    @Test
    fun `transport accepts Local API methods without a route-level whitelist`() {
        for (method in listOf("GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS")) {
            assertEquals(method, normalizePinnedHttpMethod(method))
        }
    }

    @Test
    fun `transport normalizes method casing`() {
        assertEquals("PUT", normalizePinnedHttpMethod("put"))
    }

    @Test
    fun `transport rejects tunnel and reflection methods`() {
        assertFailsWith<IllegalArgumentException> { normalizePinnedHttpMethod("CONNECT") }
        assertFailsWith<IllegalArgumentException> { normalizePinnedHttpMethod("TRACE") }
    }

    @Test
    fun `transport rejects header injection`() {
        assertFailsWith<IllegalArgumentException> {
            validatePinnedHttpHeaders(mapOf("X-Eidolon" to "safe\r\ninjected: true"))
        }
    }

    @Test
    fun `transport failures keep request response and security errors distinct`() {
        assertEquals(
            "PINNED_HTTPS_INVALID_REQUEST",
            pinnedHttpsErrorCode(IllegalArgumentException("invalid request")),
        )
        assertEquals(
            "PINNED_HTTPS_TIMEOUT",
            pinnedHttpsErrorCode(SocketTimeoutException("timed out")),
        )
        assertEquals(
            "PINNED_HTTPS_SECURE_CHANNEL_FAILED",
            pinnedHttpsErrorCode(SSLException("certificate mismatch")),
        )
        assertEquals(
            "PINNED_HTTPS_IO_FAILED",
            pinnedHttpsErrorCode(IOException("response body is too large")),
        )
    }
}
