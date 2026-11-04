package live.eidolon.eidolon_client_mobile

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The phone's half of the chunked endpoint frames, replayed against the SDK's
 * scripted exchanges. The device's C++ core and the SDK's reference endpoint
 * are held to the same steps, so the three agree byte for byte or one is red.
 */
class ProvisioningFrameCodecTest {
    private val vector = GoldenFixtures.load("protocomm-endpoint-chunking.json")

    @Suppress("UNCHECKED_CAST")
    private fun steps(exchange: Map<String, Any?>) = exchange["steps"] as List<Map<String, Any?>>

    /** Plays the device: each frame the phone sends must be the next scripted one. */
    private fun replay(
        name: String,
        chunkSize: Int = ProvisioningFrameCodec.MAX_CHUNK_BYTES,
        acceptSize: Int = ProvisioningFrameCodec.MAX_CHUNK_BYTES,
    ): Pair<ByteArray?, Int> {
        val exchange = vector.obj("exchanges").obj(name)
        val script = steps(exchange)
        var index = 0
        var clock = 0L
        var result: ByteArray? = null
        var failure: Exception? = null
        FramedEndpointExchange(
            send = { frame, reply ->
                val step = script[index++]
                assertEquals(step.str("request_hex"), frame.toHex(), "$name step ${index - 1}")
                reply(step.bytes("response_hex"), null)
            },
            schedule = { delay, action -> clock += delay; action() },
            now = { clock },
            transferId = ProvisioningFrameCodec.decode(script[0].bytes("request_hex")).transferId,
            chunkSize = chunkSize,
            acceptSize = acceptSize,
        ).run(exchange.str("request_utf8").toByteArray()) { bytes, error ->
            result = bytes
            failure = error
        }
        assertNull(failure, "$name failed: $failure")
        assertContentEquals(exchange.str("response_utf8").toByteArray(), result)
        return result to index
    }

    @Test
    fun aDescriptorLargerThanOneFrameIsReadInOrder() {
        val (_, used) = replay("descriptor")
        assertEquals(4, used)
    }

    @Test
    fun aTrustHandoverIsSentInChunksAndItsAnswerWaitedFor() {
        // The golden ends with one more GET after the answer, to show the
        // transfer is gone; the phone stops at the answer and never sends it.
        val (_, used) = replay("trust")
        assertEquals(5, used)
    }

    @Test
    fun aReaderThatAcceptsLittleIsAnsweredLittleByLittle() {
        val (_, used) = replay("narrow_reader", acceptSize = 8)
        assertEquals(4, used)
    }

    @Test
    fun abortIsTheFrameTheDeviceExpects() {
        val abort = steps(vector.obj("exchanges").obj("abort"))[1].str("request_hex")
        assertEquals(abort, ProvisioningFrameCodec.abort(9).toHex())
    }

    @Test
    fun aRefusalEndsTheExchangeWithoutAnAnswer() {
        @Suppress("UNCHECKED_CAST")
        val refused = vector["refused"] as List<Map<String, Any?>>
        val overLimit = refused.first { it.str("name") == "request-over-limit" }
        val reply = steps(overLimit).last().bytes("response_hex")
        var failure: Exception? = null
        var answered = false
        FramedEndpointExchange(
            send = { _, cb -> cb(reply, null) },
            schedule = { _, action -> action() },
            now = { 0L },
            transferId = 2,
        ).run("{}".toByteArray()) { bytes, error ->
            answered = bytes != null
            failure = error
        }
        assertTrue(!answered)
        assertNotNull(failure)
    }

    @Test
    fun aDeviceThatNeverAnswersIsGivenUpOn() {
        var clock = 0L
        var failure: Exception? = null
        val pending = ProvisioningFrameCodec.Frame(ProvisioningFrameCodec.STATUS_PENDING, 7, 250, 0, 0).encode()
        FramedEndpointExchange(
            send = { _, cb -> cb(pending, null) },
            schedule = { delay, action -> clock += delay; action() },
            now = { clock },
            transferId = 7,
            pendingBudgetMillis = 2_000,
        ).run("{}".toByteArray()) { _, error -> failure = error }
        assertNotNull(failure)
        assertTrue(clock >= 2_000)
    }
}
