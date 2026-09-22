package live.eidolon.eidolon_client_mobile

import com.espressif.provisioning.listeners.ResponseListener
import espressif.NetworkScan
import kotlin.test.*

class ProvisioningScanTest {
    private fun response(build: NetworkScan.NetworkScanPayload.Builder.() -> Unit): ByteArray =
        NetworkScan.NetworkScanPayload.newBuilder().apply(build).build().toByteArray()

    @Test fun `scan frees HTTP between polls and terminates when scan event never arrives`() {
        var time = 0L
        var requests = 0
        var result: Exception? = null
        var completions = 0
        val scheduled = java.util.PriorityQueue<Pair<Long, () -> Unit>>(compareBy { it.first })
        val scan = ProvisioningScan({ data, reply ->
            requests++
            val request = NetworkScan.NetworkScanPayload.parseFrom(data)
            if (request.hasCmdScanWifiStart()) {
                assertFalse(request.cmdScanWifiStart.blocking)
                assertTrue(request.cmdScanWifiStart.groupChannels > 0)
                reply.onSuccess(response { setRespScanWifiStart(NetworkScan.RespScanWifiStart.getDefaultInstance()) })
            } else reply.onSuccess(response {
                setRespScanWifiStatus(NetworkScan.RespScanWifiStatus.newBuilder().setScanFinished(false))
            })
        }, { delay, action -> scheduled.add((time + delay) to action) }, { time }, { _, error -> result = error; completions++ })
        scan.start()
        while (scheduled.isNotEmpty()) { val next = scheduled.remove(); time = next.first; next.second() }
        assertEquals(15_000L, time)
        assertNotNull(result)
        assertEquals(1, completions)
        assertTrue(requests in 2..62)
    }
    @Test fun `deadline completes even when the start request never responds`() {
        var timeout: (() -> Unit)? = null
        var late: ResponseListener? = null
        var completions = 0
        var failed = false
        val scan = ProvisioningScan({ _, reply -> late = reply },
            { delay, action -> assertEquals(15_000L, delay); timeout = action },
            { 0 }, { _, error -> completions++; failed = error != null })
        scan.start()
        timeout!!()
        late!!.onSuccess(response { setRespScanWifiStart(NetworkScan.RespScanWifiStart.getDefaultInstance()) })
        assertTrue(failed)
        assertEquals(1, completions)
    }
    @Test fun `cancel during status ignores late response and never fetches results`() {
        var late: ResponseListener? = null
        var sends = 0
        var completions = 0
        val scan = ProvisioningScan({ data, reply ->
            sends++
            if (NetworkScan.NetworkScanPayload.parseFrom(data).hasCmdScanWifiStart())
                reply.onSuccess(response { setRespScanWifiStart(NetworkScan.RespScanWifiStart.getDefaultInstance()) })
            else late = reply
        }, { delay, _ -> assertEquals(15_000L, delay) }, { 0 }, { _, _ -> completions++ })
        scan.start(); scan.cancel()
        late!!.onSuccess(response { setRespScanWifiStatus(NetworkScan.RespScanWifiStatus.newBuilder().setScanFinished(true).setResultCount(1)) })
        assertEquals(2, sends); assertEquals(1, completions)
    }
    @Test fun `complete scan reads vendor results and rejects truncated batches`() {
        for (truncated in listOf(false, true)) {
            var count: Int? = null
            var failure: Exception? = null
            val scan = ProvisioningScan({ data, reply ->
                val request = NetworkScan.NetworkScanPayload.parseFrom(data)
                reply.onSuccess(response {
                    when {
                        request.hasCmdScanWifiStart() -> setRespScanWifiStart(NetworkScan.RespScanWifiStart.getDefaultInstance())
                        request.hasCmdScanWifiStatus() -> setRespScanWifiStatus(NetworkScan.RespScanWifiStatus.newBuilder().setScanFinished(true).setResultCount(1))
                        else -> setRespScanWifiResult(NetworkScan.RespScanWifiResult.newBuilder().apply {
                            if (!truncated) addEntries(NetworkScan.WiFiScanResult.newBuilder().setSsid(com.google.protobuf.ByteString.copyFromUtf8("test-ap")))
                        })
                    }
                })
            }, { delay, _ -> assertEquals(15_000L, delay) }, { 0 }, { points, error -> count = points?.size; failure = error })
            scan.start()
            if (truncated) assertNotNull(failure) else { assertEquals(1, count); assertNull(failure) }
        }
    }
}
