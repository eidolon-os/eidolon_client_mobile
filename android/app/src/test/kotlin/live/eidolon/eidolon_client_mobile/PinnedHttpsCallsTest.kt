package live.eidolon.eidolon_client_mobile

import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

class PinnedHttpsCallsTest {
    private class Reply : Callback {
        val result = CompletableFuture<String>()
        override fun onFailure(call: Call, error: IOException) {
            result.complete(if (call.isCanceled()) "cancelled" else "failed")
        }
        override fun onResponse(call: Call, response: Response) {
            response.use { result.complete(it.body!!.string()) }
        }
        fun await() = result.get(3, TimeUnit.SECONDS)
    }

    @Test
    fun `a stalled connection does not block another and cancel closes its socket`() {
        val calls = PinnedHttpsCalls()
        val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        val accepted = CountDownLatch(1)
        val socketClosed = CountDownLatch(1)
        val serving = Thread {
            server.accept().use { slow ->
                slow.soTimeout = 5000
                val reader = slow.getInputStream().bufferedReader()
                while (!reader.readLine().isNullOrEmpty()) { }
                accepted.countDown()
                server.accept().use { fast ->
                    val fastReader = fast.getInputStream().bufferedReader()
                    while (!fastReader.readLine().isNullOrEmpty()) { }
                    fast.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
                }
                if (reader.read() == -1) socketClosed.countDown()
            }
        }.apply { isDaemon = true; start() }
        val client = OkHttpClient.Builder().dispatcher(calls.dispatcher).build()
        val slow = Reply()
        val fast = Reply()
        fun request(path: String) = Request.Builder().url("http://127.0.0.1:${server.localPort}/$path").build()
        try {
            calls.enqueue("old-address", client, request("slow"), slow)
            assertTrue(accepted.await(3, TimeUnit.SECONDS))
            calls.enqueue("current-host", client, request("fast"), fast)
            assertEquals("ok", fast.await())
            assertTrue(!slow.result.isDone)
            calls.cancel("old-address")
            assertEquals("cancelled", slow.await())
            assertTrue(socketClosed.await(3, TimeUnit.SECONDS))
        } finally {
            calls.close()
            client.connectionPool.evictAll()
            server.close()
            serving.join(3000)
        }
    }

    @Test
    fun `queued cancellation and scope shutdown complete without transmitting queued work`() {
        val calls = PinnedHttpsCalls()
        calls.dispatcher.maxRequests = 1
        val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        val accepted = CountDownLatch(1)
        val serving = Thread {
            server.accept().use { socket ->
                socket.soTimeout = 5000
                val input = socket.getInputStream().bufferedReader()
                while (!input.readLine().isNullOrEmpty()) { }
                accepted.countDown()
                input.read()
            }
        }.apply { isDaemon = true; start() }
        val client = OkHttpClient.Builder().dispatcher(calls.dispatcher).build()
        val request = Request.Builder().url("http://127.0.0.1:${server.localPort}/").build()
        val running = Reply()
        val queued = Reply()
        try {
            calls.enqueue("running", client, request, running)
            assertTrue(accepted.await(3, TimeUnit.SECONDS))
            calls.enqueue("queued", client, request, queued)
            assertEquals(1, calls.dispatcher.queuedCallsCount())
            calls.cancel("queued")
            calls.close()
            assertEquals("cancelled", running.await())
            assertEquals("cancelled", queued.await())
            server.soTimeout = 200
            kotlin.test.assertFailsWith<java.net.SocketTimeoutException> { server.accept() }
        } finally {
            calls.close()
            client.connectionPool.evictAll()
            server.close()
            serving.join(3000)
        }
    }
}
