package live.eidolon.eidolon_client_mobile

import org.json.JSONObject

/**
 * Declared in `proto-ver` by a device that draws a code per setup window and
 * shows it on its screen (SDK golden/ble-provisioning-transport.json).
 */
internal const val CAPABILITY_SETUP_CODE = "setup-code"

/** Declared by a device that carries the Eidolon endpoints in chunked frames. */
internal const val CAPABILITY_FRAMES = "frame-v1"

/** The device shows a code and this visit was opened without one. */
internal class SetupCodeRequiredException : Exception("This device shows a setup code")

/** The handshake failed with a code supplied: the code is wrong or stale. */
internal class SetupCodeRejectedException(cause: Exception?) :
    Exception("The setup code was not accepted", cause)

/**
 * What an Eidolon device says it can do, read from the `eidolon` entry the
 * provisioning manager adds beside `prov` in `proto-ver`:
 * `{"eidolon":{"ver":"1","cap":["setup-code"]},"prov":{...}}`. A device that
 * predates the entry declares nothing, which is the answer for it.
 */
internal object EidolonCapabilities {
    fun of(version: JSONObject): Set<String> {
        val capabilities = version.optJSONObject("eidolon")?.optJSONArray("cap") ?: return emptySet()
        return (0 until capabilities.length()).mapNotNull { capabilities.optString(it, null) }.toSet()
    }
}
