package live.eidolon.eidolon_client_mobile

/**
 * ES256 signatures in the two encodings this app has to move between.
 *
 * The JCA speaks DER: `Signature.getInstance("SHA256withECDSA")` both produces
 * and expects an ASN.1 `SEQUENCE { INTEGER r, INTEGER s }`. Every Eidolon
 * contract speaks P1363 — 64 raw bytes of `r || s`, base64url — which is what
 * `golden/es256-vectors.json` calls
 * `64-byte-r-concat-s-base64url-no-padding` and what an ESP32 and a Hub
 * exchange.
 *
 * Both directions live here because both are needed and they are one rule:
 * verifying an Owner Domain descriptor converts P1363 to DER, and signing an
 * enrollment's evidence converts DER back. The DER half already existed as a
 * private function inside `OwnerDomainDescriptorVerifier`, which is where a
 * second copy would have gone the moment signing needed the inverse.
 *
 * No Android imports, so the conversion can be held to vectors on the JVM. The
 * edge cases here are not hypothetical: an `r` whose leading byte is zero and
 * an `r` whose high bit is set are both ordinary — roughly one signature in 256
 * has each — and both are exactly where a hand-rolled converter drops or adds a
 * byte. A round-trip test would not notice; a vector does.
 */
object EcdsaSignatureEncoding {
    /** P-256: `r` and `s` are 32 bytes each. */
    private const val COORDINATE_LENGTH = 32

    private const val P1363_LENGTH = COORDINATE_LENGTH * 2

    private const val DER_SEQUENCE: Byte = 0x30
    private const val DER_INTEGER: Byte = 0x02

    /** `r || s` to `SEQUENCE { INTEGER r, INTEGER s }`. */
    fun p1363ToDer(raw: ByteArray): ByteArray {
        require(raw.size == P1363_LENGTH) {
            "ES256 P1363 signature must be $P1363_LENGTH bytes, got ${raw.size}"
        }
        val body =
            derInteger(raw.copyOfRange(0, COORDINATE_LENGTH)) +
                derInteger(raw.copyOfRange(COORDINATE_LENGTH, P1363_LENGTH))
        // A P-256 signature's DER body never reaches 128 bytes, so the short
        // length form is always correct here. Checked rather than assumed
        // because the long form would need a different header and this would
        // silently emit a malformed one.
        require(body.size < 0x80) { "ES256 DER body is unexpectedly long" }
        return byteArrayOf(DER_SEQUENCE, body.size.toByte()) + body
    }

    /** `SEQUENCE { INTEGER r, INTEGER s }` to `r || s`. */
    fun derToP1363(der: ByteArray): ByteArray {
        var index = 0
        fun read(): Int {
            require(index < der.size) { "ES256 DER signature ended early" }
            return der[index++].toInt() and 0xFF
        }

        require(read() == (DER_SEQUENCE.toInt() and 0xFF)) {
            "ES256 DER signature must be a SEQUENCE"
        }
        val declared = readLength(der) { read() }
        require(index + declared == der.size) {
            "ES256 DER signature length does not match its contents"
        }

        val out = ByteArray(P1363_LENGTH)
        for (offset in intArrayOf(0, COORDINATE_LENGTH)) {
            require(read() == (DER_INTEGER.toInt() and 0xFF)) {
                "ES256 DER signature component must be an INTEGER"
            }
            val length = readLength(der) { read() }
            var start = index
            var remaining = length
            // DER INTEGERs are signed, so a component whose high bit is set
            // carries a leading zero that is padding, not magnitude.
            while (remaining > COORDINATE_LENGTH && der[start] == 0.toByte()) {
                start += 1
                remaining -= 1
            }
            require(remaining in 1..COORDINATE_LENGTH) {
                "ES256 DER signature component does not fit P-256"
            }
            // Right-align: a component shorter than 32 bytes is left-padded
            // with zeroes, never truncated. Dropping this is how a signature
            // that verifies on one side is rejected on the other about once in
            // every 256 attempts.
            der.copyInto(out, offset + COORDINATE_LENGTH - remaining, start, start + remaining)
            index += length
        }
        return out
    }

    private inline fun readLength(der: ByteArray, read: () -> Int): Int {
        val first = read()
        if (first < 0x80) return first
        val count = first and 0x7F
        require(count in 1..4) { "ES256 DER length is not supported" }
        var value = 0
        repeat(count) { value = (value shl 8) or read() }
        require(value >= 0 && value <= der.size) { "ES256 DER length is out of range" }
        return value
    }

    private fun derInteger(component: ByteArray): ByteArray {
        val firstNonZero =
            component.indexOfFirst { it.toInt() != 0 }.let { if (it < 0) component.lastIndex else it }
        val magnitude = component.copyOfRange(firstNonZero, component.size)
        val positive =
            if ((magnitude[0].toInt() and 0x80) != 0) byteArrayOf(0) + magnitude else magnitude
        return byteArrayOf(DER_INTEGER, positive.size.toByte()) + positive
    }
}
