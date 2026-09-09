package live.eidolon.eidolon_client_mobile

import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import kotlin.test.assertFailsWith
import java.net.InetAddress
import java.security.KeyStore
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request

class PinnedHttpsAddressTest {
    private fun trustManager(): X509TrustManager {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        return factory.trustManagers.filterIsInstance<X509TrustManager>().single()
    }

    @Test
    fun `routed HTTPS authenticates the original hostname and refuses wrong name or root`() {
        // Generated solely for this loopback test; contains no deployment key.
        val keys = KeyStore.getInstance("PKCS12")
        javaClass.getResourceAsStream("/owner-route-test.p12").use {
            keys.load(it, "test-password".toCharArray())
        }
        val keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        keyManagers.init(keys, "test-password".toCharArray())
        val tls = SSLContext.getInstance("TLS")
        tls.init(keyManagers.keyManagers, null, null)
        val server = tls.serverSocketFactory.createServerSocket(
            0, 10, InetAddress.getByName("127.0.0.1")) as SSLServerSocket
        val serving = Thread {
            repeat(3) {
                try {
                    server.accept().use { socket ->
                        socket.soTimeout = 2000
                        val reader = socket.getInputStream().bufferedReader()
                        while (!reader.readLine().isNullOrEmpty()) { }
                        socket.getOutputStream().write(
                            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
                    }
                } catch (_: java.io.IOException) { /* expected for rejected TLS */ }
            }
        }
        serving.isDaemon = true
        serving.start()
        val roots = KeyStore.getInstance(KeyStore.getDefaultType())
        roots.load(null, null)
        roots.setCertificateEntry("test-root", keys.getCertificate("test"))
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(roots)
        val trusted = factory.trustManagers.filterIsInstance<X509TrustManager>().single()
        val clients = mutableListOf<OkHttpClient>()
        fun request(host: String, trust: X509TrustManager): String {
            val client = buildPinnedHttpsClient(trust, mapOf(host to "127.0.0.1"))
                .newBuilder().proxy(java.net.Proxy.NO_PROXY).build()
            clients.add(client)
            return client.newCall(Request.Builder().url("https://$host:${server.localPort}/").build())
                .execute().use { it.body!!.string() }
        }
        try {
            assertEquals("ok", request("hub.local", trusted))
            assertFailsWith<SSLException> { request("stranger.local", trusted) }
            assertFailsWith<SSLException> { request("hub.local", trustManager()) }
        } finally {
            clients.forEach {
                it.connectionPool.evictAll()
                it.dispatcher.executorService.shutdown()
            }
            server.close()
            serving.join(3000)
        }
    }

    @Test
    fun `address hint changes DNS only and does not apply to another Authority`() {
        val resolved = mutableListOf<String>()
        val client = buildPinnedHttpsClient(trustManager(), mapOf("hub.local" to "192.0.2.10"),
            resolver = object : Dns {
                override fun lookup(host: String): List<InetAddress> {
                    resolved.add(host)
                    return listOf(InetAddress.getByName("192.0.2.20"))
                }
            })
        assertEquals("192.0.2.10", client.dns.lookup("hub.local").single().hostAddress)
        assertEquals("192.0.2.20", client.dns.lookup("remote.example").single().hostAddress)
        assertEquals(listOf("remote.example"), resolved)
        // Keeping the URL hostname lets OkHttp handle SNI, Host and SAN
        // verification normally. Do not replace it with the dial address.
        val request = Request.Builder().url("https://hub.local:8443/api?at=12%3A00").build()
        assertEquals("hub.local", request.url.host)
        assertEquals("at=12%3A00", request.url.encodedQuery)
        assertSame(OkHttpClient().hostnameVerifier, client.hostnameVerifier)
        assertFalse(client.followRedirects)
        assertFalse(client.followSslRedirects)
        assertFalse(client.retryOnConnectionFailure)
    }
}
