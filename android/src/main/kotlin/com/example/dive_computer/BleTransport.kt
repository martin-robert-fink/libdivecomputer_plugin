package com.example.dive_computer

import android.annotation.SuppressLint
import android.bluetooth.*
import android.util.Log
import java.util.LinkedList
import java.util.UUID
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

/**
 * Bridges a connected Android BLE device into a libdivecomputer
 * `dc_iostream_t` via the JNI custom iostream API (dc_custom_open).
 *
 * Threading model (mirrors iOS BLETransport):
 * - libdivecomputer calls our JNI callbacks from a background thread
 * - Android BLE callbacks arrive on Binder threads
 * - We use semaphores to block the libdivecomputer thread until BLE completes
 * - The packet queue is protected by a ReentrantLock for thread safety
 *
 * I/O model (packet-based, matching DC_TRANSPORT_BLE expectations):
 * - Each BLE notification is stored as a separate packet (not merged)
 * - Each read() returns exactly one BLE notification packet
 * - This preserves the packet framing that DC_TRANSPORT_BLE requires
 */
@SuppressLint("MissingPermission")
class BleTransport(
    private val bleManager: BleManager,
    private val device: BluetoothDevice,
    private val deviceName: String
) {

    companion object {
        private const val TAG = "BleTransport"

        // Shearwater BLE service and characteristic UUIDs
        // These are the standard UUIDs used by Shearwater dive computers
        private val SHEARWATER_SERVICE = UUID.fromString("fe25c237-0ece-443c-b0aa-e02033e7029d")
        private val SHEARWATER_TX_CHAR = UUID.fromString("27b7570b-359e-45a3-91bb-cf7e70049bd2") // Write (phone → DC)
        private val SHEARWATER_RX_CHAR = UUID.fromString("27b7570b-359e-45a3-91bb-cf7e70049bd3") // Notify (DC → phone)

        // Client Characteristic Configuration Descriptor
        private val CCC_DESCRIPTOR = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        // DC_STATUS constants matching libdivecomputer
        private const val STATUS_SUCCESS = 0
        private const val STATUS_TIMEOUT = 6
        private const val STATUS_IO = 5
    }

    // The libdivecomputer iostream pointer (set after createIostream)
    private var iostreamPtr: Long = 0

    // BLE characteristics
    private var txCharacteristic: BluetoothGattCharacteristic? = null
    private var rxCharacteristic: BluetoothGattCharacteristic? = null

    // Packet-based receive queue (each BLE notification is one packet)
    private val receivedPackets = LinkedList<ByteArray>()
    private val packetLock = ReentrantLock()
    private val packetAvailable = Semaphore(0)

    // Write synchronization
    private val writeComplete = Semaphore(0)
    @Volatile private var writeError: Boolean = false

    // Timeout in milliseconds
    @Volatile private var readTimeoutMs: Int = 5000

    // Connection state
    @Volatile private var isClosed = false

    // BLE access code (Shearwater authentication)
    private var accessCode = ByteArray(0)

    // Setup completion
    private var setupCallback: ((Boolean, String?) -> Unit)? = null

    // Track characteristic setup progress
    private var notificationsEnabled = false

    // ── JNI native methods ──────────────────────────────────────────────────

    /**
     * Creates a dc_iostream_t via dc_custom_open in the JNI bridge.
     * The JNI bridge stores a reference to `this` and calls our native*
     * methods as callbacks from libdivecomputer.
     */
    external fun nativeCreateIostream(contextPtr: Long): Long
    external fun nativeCloseIostream(iostreamPtr: Long)

    // ── Public API ──────────────────────────────────────────────────────────

    /**
     * Creates the iostream. Called after BLE setup is complete.
     * Returns the iostream pointer or 0 on failure.
     */
    fun createIostream(contextPtr: Long): Long {
        iostreamPtr = nativeCreateIostream(contextPtr)
        return iostreamPtr
    }

    /**
     * Discovers services/characteristics and enables notifications.
     * Calls completion(true, null) when ready, or completion(false, error) on failure.
     */
    fun setup(completion: (Boolean, String?) -> Unit) {
        setupCallback = completion

        val gatt = bleManager.connectedGatt
        if (gatt == null) {
            completion(false, "No GATT connection")
            return
        }

        // Register our callback to receive characteristic notifications
        bleManager.connectedGatt?.let { g ->
            // Find Shearwater service and characteristics
            findCharacteristics(g)
        }
    }

    private fun findCharacteristics(gatt: BluetoothGatt) {
        // Look through all services for TX/RX characteristics
        for (service in gatt.services) {
            for (char in service.characteristics) {
                val uuid = char.uuid

                // Check for Shearwater-specific UUIDs
                if (uuid == SHEARWATER_TX_CHAR) {
                    txCharacteristic = char
                    Log.i(TAG, "Found TX characteristic: $uuid")
                } else if (uuid == SHEARWATER_RX_CHAR) {
                    rxCharacteristic = char
                    Log.i(TAG, "Found RX characteristic: $uuid")
                }
            }
        }

        // Fallback: look for any service with a write + notify characteristic pair
        if (txCharacteristic == null || rxCharacteristic == null) {
            for (service in gatt.services) {
                var writableChar: BluetoothGattCharacteristic? = null
                var notifiableChar: BluetoothGattCharacteristic? = null

                for (char in service.characteristics) {
                    val props = char.properties
                    if (props and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 ||
                        props and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
                        writableChar = char
                    }
                    if (props and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                        notifiableChar = char
                    }
                }

                if (writableChar != null && notifiableChar != null) {
                    txCharacteristic = txCharacteristic ?: writableChar
                    rxCharacteristic = rxCharacteristic ?: notifiableChar
                }
            }
        }

        if (txCharacteristic == null || rxCharacteristic == null) {
            setupCallback?.invoke(false, "Required BLE characteristics not found")
            setupCallback = null
            return
        }

        // Enable notifications on RX characteristic
        enableNotifications(gatt)
    }

    private fun enableNotifications(gatt: BluetoothGatt) {
        val rx = rxCharacteristic ?: return

        gatt.setCharacteristicNotification(rx, true)

        // Write to the CCC descriptor to enable notifications
        val descriptor = rx.getDescriptor(CCC_DESCRIPTOR)
        if (descriptor != null) {
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            gatt.writeDescriptor(descriptor)
            Log.i(TAG, "Enabling notifications on RX characteristic")
        } else {
            // Some devices don't need explicit CCC write
            Log.w(TAG, "No CCC descriptor found, notifications may already be enabled")
            onSetupComplete()
        }
    }

    private fun onSetupComplete() {
        Log.i(TAG, "BLE transport setup complete")
        notificationsEnabled = true
        setupCallback?.invoke(true, null)
        setupCallback = null
    }

    /**
     * Prepare for a new libdivecomputer operation.
     * Clears the packet queue so stale data doesn't interfere.
     */
    fun prepareForNewOperation() {
        packetLock.lock()
        try {
            receivedPackets.clear()
            packetAvailable.drainPermits()
        } finally {
            packetLock.unlock()
        }
    }

    fun close() {
        isClosed = true
        if (iostreamPtr != 0L) {
            nativeCloseIostream(iostreamPtr)
            iostreamPtr = 0
        }
    }

    // ── GATT callback handlers (called from BleManager's gattCallback) ──────

    /**
     * Must be called by BleManager when characteristic writes complete.
     */
    fun onCharacteristicWrite(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        status: Int
    ) {
        if (characteristic.uuid == txCharacteristic?.uuid) {
            writeError = status != BluetoothGatt.GATT_SUCCESS
            writeComplete.release()
        }
    }

    /**
     * Must be called by BleManager when notifications arrive.
     */
    fun onCharacteristicChanged(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray
    ) {
        if (characteristic.uuid == rxCharacteristic?.uuid) {
            packetLock.lock()
            try {
                receivedPackets.add(value.copyOf())
            } finally {
                packetLock.unlock()
            }
            packetAvailable.release()
        }
    }

    /**
     * Must be called by BleManager when descriptor writes complete.
     */
    fun onDescriptorWrite(
        gatt: BluetoothGatt,
        descriptor: BluetoothGattDescriptor,
        status: Int
    ) {
        if (descriptor.uuid == CCC_DESCRIPTOR) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                onSetupComplete()
            } else {
                setupCallback?.invoke(false, "Failed to enable notifications (status=$status)")
                setupCallback = null
            }
        }
    }

    // ── JNI callback methods ────────────────────────────────────────────────
    //
    // These methods are called from the JNI bridge (jni_bridge.cpp) when
    // libdivecomputer invokes the dc_custom_cbs_t callbacks.
    // They run on libdivecomputer's background thread.

    /**
     * Called by JNI when libdivecomputer wants to read data.
     * Returns one BLE notification packet, or null on timeout.
     */
    fun nativeRead(maxSize: Int): ByteArray? {
        if (isClosed) return null

        val timeoutMs = if (readTimeoutMs < 0) Long.MAX_VALUE else readTimeoutMs.toLong()
        val acquired = packetAvailable.tryAcquire(timeoutMs, TimeUnit.MILLISECONDS)

        if (!acquired || isClosed) return null

        packetLock.lock()
        try {
            return if (receivedPackets.isNotEmpty()) receivedPackets.poll() else null
        } finally {
            packetLock.unlock()
        }
    }

    /**
     * Called by JNI when libdivecomputer wants to write data.
     * Returns 0 (DC_STATUS_SUCCESS) or error status.
     */
    fun nativeWrite(data: ByteArray): Int {
        if (isClosed) return STATUS_IO

        val gatt = bleManager.connectedGatt ?: return STATUS_IO
        val tx = txCharacteristic ?: return STATUS_IO

        // Determine write type from characteristic properties
        val props = tx.properties
        val useResponse = props and BluetoothGattCharacteristic.PROPERTY_WRITE != 0

        // Use actual negotiated MTU minus 3 bytes ATT overhead
        val maxPayload = maxOf(bleManager.negotiatedMtu - 3, 20)
        var offset = 0

        while (offset < data.size) {
            val chunkSize = minOf(maxPayload, data.size - offset)
            val chunk = data.copyOfRange(offset, offset + chunkSize)

            tx.value = chunk
            tx.writeType = if (useResponse)
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            else
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE

            gatt.writeCharacteristic(tx)

            if (useResponse) {
                // Wait for write callback
                val completed = writeComplete.tryAcquire(5, TimeUnit.SECONDS)
                if (!completed) {
                    Log.e(TAG, "Write timeout")
                    return STATUS_TIMEOUT
                }
                if (writeError) {
                    Log.e(TAG, "Write error")
                    return STATUS_IO
                }
            }

            offset += chunkSize
        }

        return STATUS_SUCCESS
    }

    /** Called by JNI: return the device name for DC_IOCTL_BLE_GET_NAME */
    fun nativeGetName(): String = deviceName

    /** Called by JNI: return the stored access code */
    fun nativeGetAccessCode(): ByteArray = accessCode

    /** Called by JNI: store the access code from the device */
    fun nativeSetAccessCode(code: ByteArray) {
        accessCode = code.copyOf()
        Log.i(TAG, "Access code set (${code.size} bytes)")
    }

    /** Called by JNI: transport is being closed */
    fun nativeOnClose() {
        isClosed = true
        // Release any waiting semaphores
        packetAvailable.release()
        writeComplete.release()
    }

    /** Called by JNI: return number of available bytes */
    fun nativeGetAvailable(): Int {
        packetLock.lock()
        try {
            return receivedPackets.sumOf { it.size }
        } finally {
            packetLock.unlock()
        }
    }

    /** Called by JNI: set the read timeout */
    fun nativeSetTimeout(timeoutMs: Int) {
        readTimeoutMs = timeoutMs
    }

    /** Called by JNI: sleep for the specified duration */
    fun nativeOnSleep(milliseconds: Int) {
        try {
            Thread.sleep(milliseconds.toLong())
        } catch (_: InterruptedException) {
            // Ignore
        }
    }
}