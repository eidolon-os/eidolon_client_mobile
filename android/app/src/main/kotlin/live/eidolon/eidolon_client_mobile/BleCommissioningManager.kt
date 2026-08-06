package live.eidolon.eidolon_client_mobile

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothDevice
import android.content.Context
import android.os.Build
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLEngineResult
import javax.net.ssl.TrustManager

private val INFO_UUID: UUID = UUID.fromString("30af68fb-163b-581f-a94c-1488e8b3b4fd")
private val RX_UUID: UUID = UUID.fromString("518d55c5-5433-5312-9099-a0a03c90f003")
private val TX_UUID: UUID = UUID.fromString("c8a3ab33-7e3a-5827-adf0-f4358a0cfe38")
private val CCC_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
private const val MAX_GATT_VALUE_BYTES = 512
private const val ANDROID_GATT_ERROR = 133
private const val MAX_CONNECT_ATTEMPTS = 2
private const val CONNECT_RETRY_DELAY_MS = 400L
private const val LOG_TAG = "EidolonBleSetup"

/** One Android-central BLE link. GATT is transport; SSLEngine owns security. */
@SuppressLint("MissingPermission")
class BleCommissioningManager(
    private val context: Context,
    private val mainHandler: Handler,
) {
    private val executor = Executors.newSingleThreadExecutor()
    private val encryptedIncoming = ArrayBlockingQueue<ByteArray>(512)
    private val closed = AtomicBoolean(false)
    private var gatt: BluetoothGatt? = null
    private var pendingDevice: BluetoothDevice? = null
    private var connectAttempt = 0
    private var serviceUuid: UUID? = null
    private var rx: BluetoothGattCharacteristic? = null
    private var tx: BluetoothGattCharacteristic? = null
    private var negotiatedMtu = 23
    private var openResult: MethodChannel.Result? = null
    private var secureResult: MethodChannel.Result? = null
    private var writeLatch: CountDownLatch? = null
    private var writeStatus: Int = BluetoothGatt.GATT_FAILURE
    private var tls: BleTlsClient? = null
    private var endpointReadStarted = false

    fun open(address: String, requestedServiceUuid: String, result: MethodChannel.Result) {
        if (gatt != null || openResult != null) {
            result.error("LINK_BUSY", "A commissioning link is already open", null)
            return
        }
        try {
            serviceUuid = UUID.fromString(requestedServiceUuid)
            val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            val device = manager.adapter?.getRemoteDevice(address)
                ?: error("Bluetooth adapter is unavailable")
            openResult = result
            pendingDevice = device
            connectPendingDevice()
        } catch (error: Exception) {
            failOpen(error.message ?: "Could not connect to the Eidolon Host")
        }
    }

    private fun connectPendingDevice() {
        val device = pendingDevice ?: error("Bluetooth Host is unavailable")
        connectAttempt += 1
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
    }

    fun secure(expectedSpkiFingerprint: String, result: MethodChannel.Result) {
        val currentGatt = gatt
        val currentTx = tx
        if (currentGatt == null || currentTx == null || rx == null) {
            result.error("LINK_NOT_READY", "Read and verify the Host endpoint first", null)
            return
        }
        if (secureResult != null || tls != null) {
            result.error("TLS_BUSY", "The commissioning TLS session is already active", null)
            return
        }
        val descriptor = currentTx.getDescriptor(CCC_UUID)
        if (descriptor == null) {
            result.error("GATT_INCOMPATIBLE", "TX indication descriptor is missing", null)
            return
        }
        secureResult = result
        pendingFingerprint = expectedSpkiFingerprint
        if (!currentGatt.setCharacteristicNotification(currentTx, true)) {
            failSecure("Could not subscribe to Host indications")
            return
        }
        val started = if (Build.VERSION.SDK_INT >= 33) {
            currentGatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_INDICATION_VALUE) ==
                android.bluetooth.BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            @Suppress("DEPRECATION")
            currentGatt.writeDescriptor(descriptor)
        }
        if (!started) failSecure("Could not enable Host indications")
    }

    fun request(requestJson: String, result: MethodChannel.Result) {
        val currentTls = tls
        if (currentTls == null) {
            result.error("TLS_NOT_READY", "The secure commissioning session is not ready", null)
            return
        }
        executor.execute {
            try {
                currentTls.writeLine(requestJson)
                val response = currentTls.readLine()
                mainHandler.post { result.success(response) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("COMMISSIONING_REQUEST_FAILED", safeMessage(error), null)
                }
            }
        }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        encryptedIncoming.offer(ByteArray(0))
        executor.shutdownNow()
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        pendingDevice = null
        failOpen("BLE commissioning link closed")
        failSecure("BLE commissioning link closed")
    }

    private var pendingFingerprint: String? = null

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                if (!gatt.discoverServices()) failOpen("Could not discover Host GATT service")
                return
            }
            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (this@BleCommissioningManager.gatt === gatt) {
                    this@BleCommissioningManager.gatt = null
                }
                gatt.close()
                rx = null
                tx = null
                negotiatedMtu = 23
                endpointReadStarted = false
                val canRetry = status == ANDROID_GATT_ERROR &&
                    openResult != null &&
                    connectAttempt < MAX_CONNECT_ATTEMPTS &&
                    !closed.get()
                if (canRetry) {
                    Log.w(LOG_TAG, "GATT status 133; retrying connection once")
                    mainHandler.postDelayed(
                        {
                            if (openResult != null && !closed.get()) {
                                try {
                                    connectPendingDevice()
                                } catch (error: Exception) {
                                    failOpen(error.message ?: "Could not retry Bluetooth connection")
                                }
                            }
                        },
                        CONNECT_RETRY_DELAY_MS,
                    )
                    return
                }
                encryptedIncoming.offer(ByteArray(0))
                if (openResult != null) {
                    val message = if (status == ANDROID_GATT_ERROR) {
                        "Bluetooth could not connect after one retry. Move closer to the Host and try again."
                    } else {
                        "Bluetooth connection to the Host failed (status $status)"
                    }
                    failOpen(message)
                }
                failSecure("Host disconnected during secure Setup")
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failOpen("Host GATT service discovery failed")
                return
            }
            val service: BluetoothGattService? = gatt.getService(serviceUuid)
            val info = service?.getCharacteristic(INFO_UUID)
            rx = service?.getCharacteristic(RX_UUID)
            tx = service?.getCharacteristic(TX_UUID)
            if (info == null || rx == null || tx == null) {
                failOpen("Host commissioning GATT contract is incomplete")
                return
            }
            if (!gatt.requestMtu(247)) readEndpoint(gatt, info)
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) negotiatedMtu = mtu
            val info = gatt.getService(serviceUuid)?.getCharacteristic(INFO_UUID)
            if (info != null) readEndpoint(gatt, info)
        }

        private fun readEndpoint(gatt: BluetoothGatt, info: BluetoothGattCharacteristic) {
            if (endpointReadStarted) return
            endpointReadStarted = true
            if (!gatt.readCharacteristic(info)) failOpen("Could not read Host endpoint identity")
        }

        @Deprecated("Used below Android 13")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            @Suppress("DEPRECATION")
            finishEndpointRead(characteristic, characteristic.value ?: ByteArray(0), status)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) = finishEndpointRead(characteristic, value, status)

        private fun finishEndpointRead(
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            if (characteristic.uuid != INFO_UUID) return
            if (status != BluetoothGatt.GATT_SUCCESS || value.isEmpty()) {
                failOpen("Could not read Host endpoint identity")
                return
            }
            val result = openResult ?: return
            openResult = null
            mainHandler.post { result.success(String(value, StandardCharsets.UTF_8)) }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid != CCC_UUID) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failSecure("Could not enable reliable Host indications")
                return
            }
            val fingerprint = pendingFingerprint
            if (fingerprint == null) {
                failSecure("Pinned Host TLS identity is missing")
                return
            }
            executor.execute {
                try {
                    val client = BleTlsClient(fingerprint, encryptedIncoming, ::writeEncrypted)
                    client.handshake()
                    tls = client
                    val result = secureResult
                    secureResult = null
                    mainHandler.post { result?.success(null) }
                } catch (error: Exception) {
                    mainHandler.post { failSecure(safeMessage(error)) }
                }
            }
        }

        @Deprecated("Used below Android 13")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            if (characteristic.uuid == TX_UUID) encryptedIncoming.offer(characteristic.value ?: ByteArray(0))
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (characteristic.uuid == TX_UUID) encryptedIncoming.offer(value)
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (characteristic.uuid != RX_UUID) return
            writeStatus = status
            writeLatch?.countDown()
        }
    }

    private fun writeEncrypted(data: ByteArray) {
        val currentGatt = gatt ?: error("BLE link is closed")
        val currentRx = rx ?: error("BLE RX characteristic is missing")
        val maximum = minOf(MAX_GATT_VALUE_BYTES, maxOf(20, negotiatedMtu - 3))
        var offset = 0
        while (offset < data.size) {
            val chunk = data.copyOfRange(offset, minOf(data.size, offset + maximum))
            val latch = CountDownLatch(1)
            writeLatch = latch
            writeStatus = BluetoothGatt.GATT_FAILURE
            val started = if (Build.VERSION.SDK_INT >= 33) {
                currentGatt.writeCharacteristic(
                    currentRx,
                    chunk,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == android.bluetooth.BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                currentRx.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                currentRx.value = chunk
                @Suppress("DEPRECATION")
                currentGatt.writeCharacteristic(currentRx)
            }
            if (!started || !latch.await(8, TimeUnit.SECONDS) || writeStatus != BluetoothGatt.GATT_SUCCESS) {
                writeLatch = null
                error("BLE write failed")
            }
            writeLatch = null
            offset += chunk.size
        }
    }

    private fun failOpen(message: String) {
        val result = openResult ?: return
        openResult = null
        pendingDevice = null
        mainHandler.post { result.error("LINK_FAILED", message, null) }
    }

    private fun failSecure(message: String) {
        val result = secureResult ?: return
        secureResult = null
        mainHandler.post { result.error("TLS_FAILED", message, null) }
    }

    private fun safeMessage(error: Throwable): String =
        error.message?.take(180) ?: "Secure BLE Setup failed"
}

private class BleTlsClient(
    expectedFingerprint: String,
    private val encryptedIncoming: ArrayBlockingQueue<ByteArray>,
    private val encryptedSender: (ByteArray) -> Unit,
) {
    private val engine: SSLEngine
    private val networkIn = ByteBuffer.allocate(128 * 1024)
    private val networkOut = ByteBuffer.allocate(64 * 1024)
    private val applicationOut = ByteBuffer.allocate(64 * 1024)
    private val plaintext = ByteArrayOutputStream()

    init {
        val context = SSLContext.getInstance("TLS")
        context.init(
            null,
            arrayOf<TrustManager>(PinnedSpkiTrustManager(expectedFingerprint)),
            SecureRandom(),
        )
        engine = context.createSSLEngine("eidolon-bootstrap", 0).apply {
            useClientMode = true
            enabledProtocols = supportedProtocols.filter { it == "TLSv1.3" || it == "TLSv1.2" }.toTypedArray()
        }
    }

    fun handshake() {
        engine.beginHandshake()
        var status = engine.handshakeStatus
        while (status != SSLEngineResult.HandshakeStatus.FINISHED &&
            status != SSLEngineResult.HandshakeStatus.NOT_HANDSHAKING
        ) {
            status = when (status) {
                SSLEngineResult.HandshakeStatus.NEED_WRAP -> {
                    networkOut.clear()
                    val result = engine.wrap(ByteBuffer.allocate(0), networkOut)
                    requireOk(result)
                    sendBuffer(networkOut)
                    result.handshakeStatus
                }
                SSLEngineResult.HandshakeStatus.NEED_UNWRAP -> unwrapHandshake()
                SSLEngineResult.HandshakeStatus.NEED_TASK -> {
                    while (true) {
                        val task = engine.delegatedTask ?: break
                        task.run()
                    }
                    engine.handshakeStatus
                }
                else -> status
            }
        }
    }

    fun writeLine(value: String) {
        val input = ByteBuffer.wrap((value + "\n").toByteArray(StandardCharsets.UTF_8))
        while (input.hasRemaining()) {
            networkOut.clear()
            val result = engine.wrap(input, networkOut)
            requireOk(result)
            runTasks(result.handshakeStatus)
            sendBuffer(networkOut)
        }
    }

    fun readLine(): String {
        while (true) {
            val current = plaintext.toByteArray()
            val newline = current.indexOf(10)
            if (newline >= 0) {
                val line = current.copyOfRange(0, newline)
                plaintext.reset()
                if (newline + 1 < current.size) plaintext.write(current, newline + 1, current.size - newline - 1)
                return String(line, StandardCharsets.UTF_8)
            }
            unwrapApplication()
        }
    }

    private fun unwrapHandshake(): SSLEngineResult.HandshakeStatus {
        while (true) {
            ensureEncryptedInput()
            networkIn.flip()
            applicationOut.clear()
            val result = engine.unwrap(networkIn, applicationOut)
            networkIn.compact()
            when (result.status) {
                SSLEngineResult.Status.OK -> return result.handshakeStatus
                SSLEngineResult.Status.BUFFER_UNDERFLOW -> receiveEncrypted()
                SSLEngineResult.Status.BUFFER_OVERFLOW -> error("TLS handshake payload overflow")
                SSLEngineResult.Status.CLOSED -> error("Host closed TLS during handshake")
            }
        }
    }

    private fun unwrapApplication() {
        while (true) {
            ensureEncryptedInput()
            networkIn.flip()
            applicationOut.clear()
            val result = engine.unwrap(networkIn, applicationOut)
            networkIn.compact()
            runTasks(result.handshakeStatus)
            when (result.status) {
                SSLEngineResult.Status.OK -> {
                    applicationOut.flip()
                    if (applicationOut.hasRemaining()) {
                        val bytes = ByteArray(applicationOut.remaining())
                        applicationOut.get(bytes)
                        plaintext.write(bytes)
                        return
                    }
                }
                SSLEngineResult.Status.BUFFER_UNDERFLOW -> receiveEncrypted()
                SSLEngineResult.Status.BUFFER_OVERFLOW -> error("TLS application payload overflow")
                SSLEngineResult.Status.CLOSED -> error("Host closed the TLS session")
            }
        }
    }

    private fun ensureEncryptedInput() {
        if (networkIn.position() > 0) return
        receiveEncrypted()
    }

    private fun receiveEncrypted() {
        val chunk = encryptedIncoming.poll(15, TimeUnit.SECONDS)
            ?: error("Timed out waiting for Host TLS data")
        if (chunk.isEmpty()) error("BLE link closed")
        require(chunk.size <= networkIn.remaining()) { "TLS input buffer overflow" }
        networkIn.put(chunk)
    }

    private fun sendBuffer(buffer: ByteBuffer) {
        buffer.flip()
        if (!buffer.hasRemaining()) return
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        encryptedSender(bytes)
    }

    private fun requireOk(result: SSLEngineResult) {
        when (result.status) {
            SSLEngineResult.Status.OK -> Unit
            SSLEngineResult.Status.BUFFER_OVERFLOW -> error("TLS output buffer overflow")
            SSLEngineResult.Status.BUFFER_UNDERFLOW -> error("Unexpected TLS output underflow")
            SSLEngineResult.Status.CLOSED -> error("TLS engine closed")
        }
    }

    private fun runTasks(status: SSLEngineResult.HandshakeStatus) {
        if (status != SSLEngineResult.HandshakeStatus.NEED_TASK) return
        while (true) {
            val task = engine.delegatedTask ?: break
            task.run()
        }
    }
}
