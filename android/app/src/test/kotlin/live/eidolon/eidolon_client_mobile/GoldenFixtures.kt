package live.eidolon.eidolon_client_mobile

import java.io.File

/**
 * Reading the device-foundation vectors this app vendors from the SDK.
 *
 * The vectors live at the Flutter project root (`test/fixtures/device_foundation`)
 * because Dart consumes them too; `tool/sync_device_foundation_v1.py`
 * copies them from a pinned SDK commit, `device_foundation_sdk.lock.json`
 * records the digest of each one, and `test/device_foundation_lock_test.dart`
 * checks both on every run. Nothing
 * here should ever transcribe a value out of one — a transcribed vector is one
 * more hand-written copy of the rule it was supposed to pin.
 *
 * The JSON reader is deliberately tiny and lives in test sources. `org.json` is
 * only a stub on the unit-test classpath (every call throws "not mocked"), and
 * pulling in a parser as a dependency to read a few flat objects would cost
 * more than it explains.
 */
object GoldenFixtures {
    fun load(name: String): Map<String, Any?> {
        val text = locate(name).readText(Charsets.UTF_8)
        val value = JsonReader(text).readValue()
        @Suppress("UNCHECKED_CAST")
        return value as? Map<String, Any?>
            ?: error("golden $name is not a JSON object")
    }

    /**
     * Walk up from the working directory rather than assuming it.
     *
     * The Android Gradle Plugin runs unit tests from the module directory
     * today, but that is its choice and not a contract; a test that silently
     * cannot find its vector is worse than one that says where it looked.
     */
    private fun locate(name: String): File {
        var directory: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val searched = mutableListOf<String>()
        while (directory != null) {
            val candidate = File(directory, "test/fixtures/device_foundation/$name")
            searched += candidate.path
            if (candidate.isFile) return candidate
            directory = directory.parentFile
        }
        error("golden $name not found; looked in:\n" + searched.joinToString("\n"))
    }
}

fun hex(value: String): ByteArray {
    require(value.length % 2 == 0) { "hex string has an odd length" }
    return ByteArray(value.length / 2) { index ->
        value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}

fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

@Suppress("UNCHECKED_CAST")
fun Map<String, Any?>.obj(key: String): Map<String, Any?> =
    this[key] as? Map<String, Any?> ?: error("golden field '$key' is not an object")

fun Map<String, Any?>.str(key: String): String =
    this[key] as? String ?: error("golden field '$key' is not a string")

fun Map<String, Any?>.bytes(key: String): ByteArray = hex(str(key))

fun Map<String, Any?>.long(key: String): Long =
    this[key] as? Long ?: error("golden field '$key' is not an integer")

/** Just enough JSON to read a vector: objects, arrays, strings, numbers, literals. */
private class JsonReader(private val source: String) {
    private var index = 0

    fun readValue(): Any? {
        skipWhitespace()
        return when (val character = peek()) {
            '{' -> readObject()
            '[' -> readArray()
            '"' -> readString()
            't', 'f' -> readBoolean()
            'n' -> readNull()
            else ->
                if (character == '-' || character.isDigit()) readNumber()
                else error("unexpected character '$character' at $index")
        }
    }

    private fun readObject(): Map<String, Any?> {
        expect('{')
        val entries = LinkedHashMap<String, Any?>()
        skipWhitespace()
        if (peek() == '}') {
            index += 1
            return entries
        }
        while (true) {
            skipWhitespace()
            val key = readString()
            expect(':')
            entries[key] = readValue()
            skipWhitespace()
            when (val separator = next()) {
                ',' -> Unit
                '}' -> return entries
                else -> error("unexpected '$separator' in object at $index")
            }
        }
    }

    private fun readArray(): List<Any?> {
        expect('[')
        val items = mutableListOf<Any?>()
        skipWhitespace()
        if (peek() == ']') {
            index += 1
            return items
        }
        while (true) {
            items += readValue()
            skipWhitespace()
            when (val separator = next()) {
                ',' -> Unit
                ']' -> return items
                else -> error("unexpected '$separator' in array at $index")
            }
        }
    }

    private fun readString(): String {
        expect('"')
        val builder = StringBuilder()
        while (true) {
            when (val character = next()) {
                '"' -> return builder.toString()
                '\\' -> builder.append(readEscape())
                else -> builder.append(character)
            }
        }
    }

    private fun readEscape(): Char =
        when (val character = next()) {
            '"', '\\', '/' -> character
            'b' -> '\b'
            'f' -> '\u000C'
            'n' -> '\n'
            'r' -> '\r'
            't' -> '\t'
            'u' -> {
                val code = source.substring(index, index + 4).toInt(16)
                index += 4
                code.toChar()
            }
            else -> error("unsupported escape at $index")
        }

    private fun readNumber(): Any {
        val start = index
        while (index < source.length && (source[index].isDigit() || source[index] in "-+.eE")) {
            index += 1
        }
        val text = source.substring(start, index)
        return text.toLongOrNull() ?: text.toDouble()
    }

    private fun readBoolean(): Boolean =
        when {
            source.startsWith("true", index) -> {
                index += 4
                true
            }
            source.startsWith("false", index) -> {
                index += 5
                false
            }
            else -> error("invalid literal at $index")
        }

    private fun readNull(): Any? {
        require(source.startsWith("null", index)) { "invalid literal at $index" }
        index += 4
        return null
    }

    private fun skipWhitespace() {
        while (index < source.length && source[index].isWhitespace()) index += 1
    }

    private fun peek(): Char = source[index]

    private fun next(): Char = source[index++]

    private fun expect(character: Char) {
        skipWhitespace()
        val actual = next()
        require(actual == character) { "expected '$character' but found '$actual' at $index" }
    }
}
