package live.eidolon.eidolon_client_mobile

/**
 * Chunked frames for the Eidolon setup endpoints, carried in the plaintext of
 * each Security 2 message (SDK golden/protocomm-endpoint-chunking.json,
 * DF-COMM-017).
 *
 * Over BLE one protocomm exchange is one characteristic write and one read,
 * at most 512 bytes, and the Owner trust handover is several kilobytes. The
 * frames split a request into PUTs and a response into GETs, every one still
 * encrypted by the session. SoftAP does not need them and does not get them
 * unless a debug build forces it.
 *
 * Header, 16 bytes, big-endian: magic E1 D0, version 1, op or status,
 * transfer id, length, total, offset.
 */
internal object ProvisioningFrameCodec {
    const val HEADER_BYTES = 16
    const val MAX_FRAME_BYTES = 448
    const val MAX_CHUNK_BYTES = MAX_FRAME_BYTES - HEADER_BYTES
    private const val MAGIC_0 = 0xE1
    private const val MAGIC_1 = 0xD0
    private const val VERSION = 1

    const val OP_PUT = 0x01
    const val OP_GET = 0x02
    const val OP_ABORT = 0x03

    const val STATUS_CONTINUE = 0x00
    const val STATUS_READY = 0x01
    const val STATUS_PENDING = 0x02
    const val STATUS_DATA = 0x03

    /** The endpoints that are framed; the SDK's own prov-* and proto-ver never are. */
    val FRAMED_ENDPOINTS = setOf(
        "eidolon-descriptor",
        "eidolon-status",
        "eidolon-terminal-ack",
        "eidolon-trust",
    )

    data class Frame(
        val code: Int,
        val transferId: Int,
        val length: Int,
        val total: Long,
        val offset: Long,
        val chunk: ByteArray = ByteArray(0),
    ) {
        fun encode(): ByteArray {
            val out = ByteArray(HEADER_BYTES + chunk.size)
            out[0] = MAGIC_0.toByte()
            out[1] = MAGIC_1.toByte()
            out[2] = VERSION.toByte()
            out[3] = code.toByte()
            putU16(out, 4, transferId)
            putU16(out, 6, length)
            putU32(out, 8, total)
            putU32(out, 12, offset)
            chunk.copyInto(out, HEADER_BYTES)
            return out
        }
    }

    class MalformedFrame(message: String) : Exception(message)

    fun put(transferId: Int, request: ByteArray, offset: Int, size: Int): ByteArray {
        val chunk = request.copyOfRange(offset, offset + size)
        return Frame(OP_PUT, transferId, chunk.size, request.size.toLong(), offset.toLong(), chunk).encode()
    }

    fun get(transferId: Int, offset: Long, accept: Int = MAX_CHUNK_BYTES): ByteArray =
        Frame(OP_GET, transferId, accept, 0, offset).encode()

    fun abort(transferId: Int): ByteArray = Frame(OP_ABORT, transferId, 0, 0, 0).encode()

    fun decode(bytes: ByteArray): Frame {
        if (bytes.size < HEADER_BYTES || bytes.size > MAX_FRAME_BYTES) {
            throw MalformedFrame("frame length ${bytes.size} out of range")
        }
        if ((bytes[0].toInt() and 0xff) != MAGIC_0 || (bytes[1].toInt() and 0xff) != MAGIC_1) {
            throw MalformedFrame("not a frame")
        }
        if ((bytes[2].toInt() and 0xff) != VERSION) throw MalformedFrame("unsupported frame version")
        return Frame(
            code = bytes[3].toInt() and 0xff,
            transferId = u16(bytes, 4),
            length = u16(bytes, 6),
            total = u32(bytes, 8),
            offset = u32(bytes, 12),
            chunk = bytes.copyOfRange(HEADER_BYTES, bytes.size),
        )
    }

    private fun u16(b: ByteArray, at: Int) = ((b[at].toInt() and 0xff) shl 8) or (b[at + 1].toInt() and 0xff)

    private fun u32(b: ByteArray, at: Int): Long =
        ((b[at].toLong() and 0xff) shl 24) or ((b[at + 1].toLong() and 0xff) shl 16) or
            ((b[at + 2].toLong() and 0xff) shl 8) or (b[at + 3].toLong() and 0xff)

    private fun putU16(out: ByteArray, at: Int, value: Int) {
        out[at] = (value shr 8).toByte()
        out[at + 1] = value.toByte()
    }

    private fun putU32(out: ByteArray, at: Int, value: Long) {
        for (i in 0 until 4) out[at + i] = (value shr (24 - 8 * i)).toByte()
    }
}

/**
 * One framed request, end to end: PUT the request in chunks, then GET the
 * response, waiting out PENDING. Every send goes through [send], one at a
 * time, so it rides the session's single exchange like any other request.
 *
 * Pure: the session, the clock and the scheduler are injected, so the JVM
 * tests can drive it against the SDK's scripted exchanges.
 */
internal class FramedEndpointExchange(
    private val send: (ByteArray, (ByteArray?, Exception?) -> Unit) -> Unit,
    private val schedule: (Long, () -> Unit) -> Unit,
    private val now: () -> Long,
    private val transferId: Int,
    private val chunkSize: Int = ProvisioningFrameCodec.MAX_CHUNK_BYTES,
    private val acceptSize: Int = ProvisioningFrameCodec.MAX_CHUNK_BYTES,
    private val pendingBudgetMillis: Long = 20_000,
) {
    fun run(request: ByteArray, done: (ByteArray?, Exception?) -> Unit) {
        val size = chunkSize.coerceIn(1, ProvisioningFrameCodec.MAX_CHUNK_BYTES)
        putFrom(request, 0, size, done)
    }

    private fun putFrom(request: ByteArray, offset: Int, size: Int, done: (ByteArray?, Exception?) -> Unit) {
        val length = minOf(size, request.size - offset)
        send(ProvisioningFrameCodec.put(transferId, request, offset, length)) { bytes, error ->
            val reply = decodeOrFail(bytes, error, done) ?: return@send
            val next = offset + length
            when (reply.code) {
                ProvisioningFrameCodec.STATUS_CONTINUE ->
                    if (next < request.size && reply.offset == next.toLong()) putFrom(request, next, size, done)
                    else done(null, ProvisioningFrameCodec.MalformedFrame("device lost the request at $next"))
                ProvisioningFrameCodec.STATUS_READY ->
                    if (next == request.size) getFrom(ByteArray(0), 0, reply.total, null, done)
                    else done(null, ProvisioningFrameCodec.MalformedFrame("device answered before the request ended"))
                ProvisioningFrameCodec.STATUS_PENDING ->
                    if (next == request.size) waitThenGet(reply.length.toLong(), now() + pendingBudgetMillis, done)
                    else done(null, ProvisioningFrameCodec.MalformedFrame("device pended before the request ended"))
                else -> done(null, refusal(reply))
            }
        }
    }

    private fun waitThenGet(retryAfterMillis: Long, deadline: Long, done: (ByteArray?, Exception?) -> Unit) {
        if (now() >= deadline) {
            done(null, ProvisioningFrameCodec.MalformedFrame("device did not answer in time"))
            return
        }
        schedule(retryAfterMillis.coerceIn(50, 2_000)) { getFrom(ByteArray(0), 0, -1, deadline, done) }
    }

    private fun getFrom(
        received: ByteArray,
        offset: Long,
        total: Long,
        deadline: Long?,
        done: (ByteArray?, Exception?) -> Unit,
    ) {
        if (total >= 0 && offset == total) {
            done(received, null)
            return
        }
        send(ProvisioningFrameCodec.get(transferId, offset, acceptSize)) { bytes, error ->
            val reply = decodeOrFail(bytes, error, done) ?: return@send
            when (reply.code) {
                ProvisioningFrameCodec.STATUS_PENDING ->
                    waitThenGet(reply.length.toLong(), deadline ?: (now() + pendingBudgetMillis), done)
                ProvisioningFrameCodec.STATUS_DATA -> {
                    if (reply.offset != offset || reply.chunk.size != reply.length ||
                        (total >= 0 && reply.total != total)) {
                        done(null, ProvisioningFrameCodec.MalformedFrame("device sent the response out of order"))
                        return@send
                    }
                    val grown = received + reply.chunk
                    val next = offset + reply.chunk.size
                    if (next == reply.total) done(grown, null)
                    else if (reply.chunk.isEmpty()) done(null, ProvisioningFrameCodec.MalformedFrame("empty chunk"))
                    else getFrom(grown, next, reply.total, deadline, done)
                }
                else -> done(null, refusal(reply))
            }
        }
    }

    private fun decodeOrFail(
        bytes: ByteArray?,
        error: Exception?,
        done: (ByteArray?, Exception?) -> Unit,
    ): ProvisioningFrameCodec.Frame? {
        if (error != null || bytes == null) {
            done(null, error ?: ProvisioningFrameCodec.MalformedFrame("no reply"))
            return null
        }
        val reply = try {
            ProvisioningFrameCodec.decode(bytes)
        } catch (malformed: ProvisioningFrameCodec.MalformedFrame) {
            done(null, malformed)
            return null
        }
        if (reply.transferId != transferId) {
            done(null, ProvisioningFrameCodec.MalformedFrame("reply for another transfer"))
            return null
        }
        return reply
    }

    private fun refusal(reply: ProvisioningFrameCodec.Frame) =
        ProvisioningFrameCodec.MalformedFrame("device refused the frame: status 0x%02x".format(reply.code))
}
