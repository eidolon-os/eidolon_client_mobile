package live.eidolon.eidolon_client_mobile

import com.espressif.provisioning.listeners.ResponseListener
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*
import okhttp3.OkHttpClient

class ProvisioningHttpTransportTest {
    private class Reply : ResponseListener {
        val count = AtomicInteger()
        val done = CompletableFuture<String>()
        override fun onSuccess(bytes: ByteArray?) { count.incrementAndGet(); done.complete(String(bytes!!)) }
        override fun onFailure(error: Exception?) { count.incrementAndGet(); done.complete("failed") }
        fun await() = done.get(3, TimeUnit.SECONDS)
    }
    private fun readRequest(socket: java.net.Socket): List<String> {
        socket.soTimeout = 3000
        val reader = socket.getInputStream().bufferedReader()
        val headers = mutableListOf<String>()
        while (true) { val line = reader.readLine() ?: break; if (line.isEmpty()) break; headers += line }
        val length = headers.firstOrNull { it.startsWith("Content-Length:", true) }?.substringAfter(':')?.trim()?.toInt() ?: 0
        repeat(length) { reader.read() }
        return headers
    }
    @Test fun `close cancels socket and answers once while next visit succeeds`() {
        val server = ServerSocket(0)
        val accepted = CountDownLatch(1)
        val eof = CountDownLatch(1)
        val thread = Thread {
            server.accept().use { socket ->
                readRequest(socket); accepted.countDown()
                if (socket.getInputStream().read() == -1) eof.countDown()
            }
            server.accept().use { socket ->
                readRequest(socket)
                socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
            }
        }.apply { isDaemon = true; start() }
        val url = "http://127.0.0.1:${server.localPort}/"
        val first = ProvisioningHttpTransport(OkHttpClient.Builder(), { it() }, url)
        val second = ProvisioningHttpTransport(OkHttpClient.Builder(), { it() }, url)
        val old = Reply(); val current = Reply()
        try {
            first.sendConfigData("prov-scan", byteArrayOf(1), old)
            assertTrue(accepted.await(3, TimeUnit.SECONDS))
            first.close()
            assertEquals("failed", old.await())
            assertTrue(eof.await(3, TimeUnit.SECONDS))
            second.sendConfigData("proto-ver", byteArrayOf(), current)
            assertEquals("ok", current.await())
            thread.join(3000)
            assertEquals(1, old.count.get())
        } finally { first.close(); second.close(); server.close() }
    }
    @Test fun `cookie survives a replaced socket but never crosses visits`() {
        val server = ServerSocket(0)
        val headers = LinkedBlockingQueue<List<String>>()
        val thread = Thread { repeat(3) { index -> server.accept().use { socket ->
            headers.add(readRequest(socket))
            val cookie = if (index == 0) "Set-Cookie: session=12345\r\n" else ""
            socket.getOutputStream().write(("HTTP/1.1 200 OK\r\n" + cookie +
                "Content-Length: 2\r\nConnection: close\r\n\r\nok").toByteArray())
        } } }.apply { isDaemon = true; start() }
        val url = "http://127.0.0.1:${server.localPort}/"
        val first = ProvisioningHttpTransport(OkHttpClient.Builder(), { it() }, url)
        val second = ProvisioningHttpTransport(OkHttpClient.Builder(), { it() }, url)
        try {
            val one = Reply(); first.sendConfigData("proto-ver", "ESP".toByteArray(), one)
            assertEquals("ok", one.await())
            val two = Reply(); first.sendConfigData("prov-session", byteArrayOf(1), two)
            assertEquals("ok", two.await())
            first.close()
            val three = Reply(); second.sendConfigData("proto-ver", "ESP".toByteArray(), three)
            assertEquals("ok", three.await())
            assertFalse(headers.take().any { it.startsWith("Cookie:", true) })
            assertTrue(headers.take().any { it == "Cookie: session=12345" })
            assertFalse(headers.take().any { it.startsWith("Cookie:", true) })
        } finally { first.close(); second.close(); server.close(); thread.join(3000) }
    }
    @Test fun `read deadline ends a server that never responds without caller cancellation`() {
        val server = ServerSocket(0)
        val thread = Thread { server.accept().use { socket -> readRequest(socket); socket.getInputStream().read() } }
            .apply { isDaemon = true; start() }
        val transport = ProvisioningHttpTransport(OkHttpClient.Builder(), { it() }, "http://127.0.0.1:${server.localPort}/", 200)
        val reply = Reply()
        try {
            transport.sendConfigData("prov-scan", byteArrayOf(1), reply)
            assertEquals("failed", reply.await())
            thread.join(3000)
            assertEquals(1, reply.count.get())
        } finally { transport.close(); server.close() }
    }
    @Test fun `close fences a response queued on the protocol dispatcher`() {
        val server = ServerSocket(0)
        val callbacks = LinkedBlockingQueue<() -> Unit>()
        val thread = Thread { server.accept().use { socket ->
            readRequest(socket)
            socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
        }}.apply { isDaemon = true; start() }
        val transport = ProvisioningHttpTransport(OkHttpClient.Builder(), { callbacks.add(it) }, "http://127.0.0.1:${server.localPort}/")
        val reply = Reply()
        try {
            transport.sendConfigData("proto-ver", byteArrayOf(), reply)
            val lateSuccess = callbacks.poll(3, TimeUnit.SECONDS)!!
            transport.close()
            lateSuccess()
            callbacks.poll(3, TimeUnit.SECONDS)!!()
            assertEquals("failed", reply.await())
            assertEquals(1, reply.count.get())
        } finally { transport.close(); server.close(); thread.join(3000) }
    }
    @Test fun `fragmented response completes on content length without socket close`() {
        val server = ServerSocket(0)
        val sentHeaders = CountDownLatch(1)
        val release = CountDownLatch(1)
        val eof = CompletableFuture<Int>()
        val body = "r".repeat(169)
        val thread = Thread {
            try { server.accept().use { socket ->
                readRequest(socket)
                val output = socket.getOutputStream()
                output.write("HTTP/1.1 200 OK\r\nContent-Length: 169\r\n".toByteArray())
                output.flush(); sentHeaders.countDown()
                check(release.await(3, TimeUnit.SECONDS))
                output.write("\r\n".toByteArray()); output.flush()
                body.chunked(7).forEach { output.write(it.toByteArray()); output.flush() }
                eof.complete(socket.getInputStream().read())
            } } catch (e: Exception) { eof.completeExceptionally(e) }
        }.apply { isDaemon = true; start() }
        val transport = ProvisioningHttpTransport(OkHttpClient.Builder(), { it() }, "http://127.0.0.1:${server.localPort}/")
        val reply = Reply()
        try {
            transport.sendConfigData("prov-scan", byteArrayOf(1), reply)
            assertTrue(sentHeaders.await(3, TimeUnit.SECONDS))
            assertFalse(reply.done.isDone)
            release.countDown()
            assertEquals(body, reply.await())
            transport.close()
            assertEquals(-1, eof.get(3, TimeUnit.SECONDS))
            assertEquals(1, reply.count.get())
        } finally { release.countDown(); transport.close(); server.close(); thread.join(3000) }
    }

    @Test fun `incomplete headers and incomplete body each fail once and close socket`() {
        for (tail in listOf("", "\r\npartial")) {
            val server = ServerSocket(0)
            val eof = CompletableFuture<Int>()
            val thread = Thread {
                try { server.accept().use { socket ->
                    readRequest(socket)
                    socket.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Length: 169\r\n" + tail).toByteArray())
                    socket.getOutputStream().flush()
                    eof.complete(socket.getInputStream().read())
                } } catch (e: Exception) { eof.completeExceptionally(e) }
            }.apply { isDaemon = true; start() }
            val transport = ProvisioningHttpTransport(OkHttpClient.Builder(), { it() },
                "http://127.0.0.1:${server.localPort}/", 350)
            val reply = Reply()
            try {
                transport.sendConfigData("prov-scan", byteArrayOf(1), reply)
                assertEquals("failed", reply.await())
                assertEquals(-1, eof.get(3, TimeUnit.SECONDS))
                transport.close()
                assertEquals(1, reply.count.get())
            } finally { transport.close(); server.close(); thread.join(3000) }
        }
    }

}
