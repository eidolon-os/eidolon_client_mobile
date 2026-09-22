package live.eidolon.eidolon_client_mobile

import com.espressif.provisioning.listeners.ResponseListener
import com.espressif.provisioning.utils.MessengeHelper
import espressif.Constants
import espressif.NetworkScan
import java.io.IOException

/** The vendor's start/status/result protocol, with bounded non-blocking scans. */
internal class ProvisioningScan(
    private val send: (ByteArray, ResponseListener) -> Unit,
    private val schedule: (Long, () -> Unit) -> Unit,
    private val now: () -> Long,
    private val complete: (List<NetworkScan.WiFiScanResult>?, Exception?) -> Unit,
) {
    private val deadline = now() + 15_000
    private var finished = false
    private val results = mutableListOf<NetworkScan.WiFiScanResult>()

    fun start() {
        schedule(15_000) { finish(null, IOException("Device Wi-Fi scan deadline exceeded")) }
        val command = NetworkScan.NetworkScanPayload.newBuilder()
            .setMsg(NetworkScan.NetworkScanMsgType.TypeCmdScanWifiStart)
            .setCmdScanWifiStart(NetworkScan.CmdScanWifiStart.newBuilder()
                .setBlocking(false).setPassive(false).setGroupChannels(4).setPeriodMs(120))
            .build().toByteArray()
        request(command) {
            check(it.hasRespScanWifiStart()) { "Unexpected scan start response" }
            poll()
        }
    }

    private fun poll() {
        if (finished) return
        if (now() >= deadline) { finish(null, IOException("Device Wi-Fi scan deadline exceeded")); return }
        request(MessengeHelper.prepareGetWiFiScanStatusMsg()) {
            check(it.hasRespScanWifiStatus()) { "Unexpected scan status response" }
            val status = it.respScanWifiStatus
            if (!status.scanFinished) schedule(250) { poll() }
            else {
                check(status.resultCount in 0..256) { "Invalid scan result count" }
                fetch(status.resultCount)
            }
        }
    }

    private fun fetch(total: Int) {
        if (results.size == total) { finish(results.toList(), null); return }
        val count = minOf(4, total - results.size)
        request(MessengeHelper.prepareGetWiFiScanListMsg(results.size, count)) {
            check(it.hasRespScanWifiResult() && it.respScanWifiResult.entriesCount == count) {
                "Incomplete scan results"
            }
            results.addAll(it.respScanWifiResult.entriesList)
            fetch(total)
        }
    }

    private fun request(data: ByteArray, accept: (NetworkScan.NetworkScanPayload) -> Unit) {
        if (finished) return
        if (now() >= deadline) { finish(null, IOException("Device Wi-Fi scan deadline exceeded")); return }
        send(data, object : ResponseListener {
            override fun onSuccess(bytes: ByteArray?) {
                if (finished) return
                try {
                    val response = NetworkScan.NetworkScanPayload.parseFrom(bytes ?: byteArrayOf())
                    check(response.status == Constants.Status.Success) { "Device rejected Wi-Fi scan" }
                    accept(response)
                } catch (e: Exception) { finish(null, e) }
            }
            override fun onFailure(e: Exception?) { finish(null, e ?: IOException("Wi-Fi scan failed")) }
        })
    }

    fun cancel() { finish(null, IOException("Wi-Fi scan cancelled")) }
    private fun finish(value: List<NetworkScan.WiFiScanResult>?, error: Exception?) {
        if (finished) return
        finished = true
        complete(value, error)
    }
}
