package com.example.dive_computer

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import android.util.Log

/**
 * Represents a BLE dive computer discovered during scanning.
 * Mirrors the Swift DiscoveredDevice struct.
 */
data class DiscoveredDevice(
    val bluetoothDevice: BluetoothDevice,
    val name: String,
    val address: String,
    val rssi: Int,
    val vendor: String,
    val product: String,
    val family: Int,
    val model: Int
) {
    fun toMap(): Map<String, Any> = mapOf(
        "name" to name,
        "address" to address,
        "rssi" to rssi,
        "vendor" to vendor,
        "product" to product,
        "family" to family,
        "model" to model
    )
}

/**
 * Cached descriptor info from libdivecomputer.
 */
data class DescriptorInfo(
    val vendor: String,
    val product: String,
    val family: Int,
    val model: Int,
    val transports: Int
)

/**
 * Manages Android BLE scanning, connection, and filtering of discovered
 * peripherals against libdivecomputer's known device descriptors.
 *
 * Mirrors iOS BLEManager.swift with Android-specific BLE APIs.
 *
 * Threading: BLE callbacks arrive on Binder threads. Scan results are
 * forwarded to the callback on the calling thread (typically main).
 * Connection callbacks happen on Binder threads and are dispatched
 * appropriately.
 */
@SuppressLint("MissingPermission") // Permissions checked at app level
class BleManager(
    private val context: Context,
    private val callback: Callback
) {

    companion object {
        private const val TAG = "BleManager"

        // BLE transport flag in libdivecomputer (DC_TRANSPORT_BLE = 0x10)
        private const val DC_TRANSPORT_BLE = 0x10
    }

    interface Callback {
        fun onDeviceDiscovered(device: DiscoveredDevice)
        fun onScanFailed(errorMessage: String)
    }

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        manager?.adapter
    }

    private var scanner: BluetoothLeScanner? = null
    private var isScanning = false
    private val discoveredAddresses = mutableSetOf<String>()

    // Cache of BLE-capable descriptors from libdivecomputer
    private val bleDescriptors = mutableListOf<DescriptorInfo>()

    // Negotiated MTU (updated from GATT callback, used by BleTransport)
    var negotiatedMtu: Int = 23
        private set

    // Connection state
    var connectedGatt: BluetoothGatt? = null
        private set
    private var connectCallback: ((Boolean, String?) -> Unit)? = null

    /** Transport that receives characteristic/descriptor callbacks after connection */
    var activeTransport: BleTransport? = null

    init {
        // Descriptors are loaded lazily via loadDescriptors()
    }

    // ── Descriptor loading ──────────────────────────────────────────────────

    /**
     * Loads BLE-capable descriptors from a list of all descriptors.
     * Called by DiveComputerPlugin after it retrieves descriptors via JNI.
     * This mirrors the Swift BLEManager.loadBLEDescriptors() method.
     */
    fun loadDescriptors(allDescriptors: Array<HashMap<String, Any>>) {
        bleDescriptors.clear()
        for (desc in allDescriptors) {
            val transports = (desc["transports"] as? Int) ?: 0
            if (transports and DC_TRANSPORT_BLE != 0) {
                bleDescriptors.add(
                    DescriptorInfo(
                        vendor = desc["vendor"] as? String ?: "",
                        product = desc["product"] as? String ?: "",
                        family = (desc["family"] as? Int) ?: 0,
                        model = (desc["model"] as? Int) ?: 0,
                        transports = transports
                    )
                )
            }
        }
        Log.i(TAG, "Loaded ${bleDescriptors.size} BLE descriptors")
    }

    // ── Scanning ────────────────────────────────────────────────────────────

    fun startScan() {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            callback.onScanFailed("Bluetooth is not enabled")
            return
        }

        discoveredAddresses.clear()
        scanner = adapter.bluetoothLeScanner

        if (scanner == null) {
            callback.onScanFailed("BLE scanner not available")
            return
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        scanner?.startScan(null, settings, scanCallback)
        isScanning = true
        Log.i(TAG, "BLE scan started")
    }

    fun stopScan() {
        if (isScanning) {
            try {
                scanner?.stopScan(scanCallback)
            } catch (e: Exception) {
                Log.w(TAG, "Error stopping scan", e)
            }
            isScanning = false
            Log.i(TAG, "BLE scan stopped")
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val address = device.address
            val name = result.scanRecord?.deviceName ?: device.name ?: return

            // Skip already-reported devices
            if (address in discoveredAddresses) return

            // Match against known BLE descriptors (same logic as iOS)
            val matched = matchDevice(name)
            if (matched != null) {
                discoveredAddresses.add(address)
                val discovered = DiscoveredDevice(
                    bluetoothDevice = device,
                    name = name,
                    address = address,
                    rssi = result.rssi,
                    vendor = matched.vendor,
                    product = matched.product,
                    family = matched.family,
                    model = matched.model
                )
                callback.onDeviceDiscovered(discovered)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "BLE scan failed: $errorCode")
            callback.onScanFailed("Scan failed with error code $errorCode")
        }
    }

    /**
     * Matches a BLE device name against known libdivecomputer descriptors.
     * Shearwater devices advertise as their product name (e.g., "Petrel 3").
     */
    private fun matchDevice(name: String): DescriptorInfo? {
        // Shearwater devices: advertised name contains the product name
        for (desc in bleDescriptors) {
            // Check if the advertised name starts with or contains the product name
            // Common patterns:
            //   "Petrel 3" matches descriptor "Petrel 3"
            //   "Peregrine" matches descriptor "Peregrine"
            //   "Petrel 12345" matches descriptor "Petrel" (serial appended)
            if (name.startsWith(desc.product, ignoreCase = true) ||
                desc.product.startsWith(name.take(desc.product.length), ignoreCase = true)) {
                return desc
            }
        }
        return null
    }

    /**
     * Finds a descriptor by vendor and product name.
     * Used during connection to get the family/model for dc_device_open.
     */
    fun findDescriptor(vendor: String, product: String): DescriptorInfo? {
        return bleDescriptors.find {
            it.vendor.equals(vendor, ignoreCase = true) &&
                it.product.equals(product, ignoreCase = true)
        }
    }

    // ── Connection ──────────────────────────────────────────────────────────

    fun connect(device: BluetoothDevice, completion: (Boolean, String?) -> Unit) {
        connectCallback = completion

        // Stop scanning before connecting
        stopScan()

        Log.i(TAG, "Connecting to ${device.address}")

        // Use TRANSPORT_LE for BLE devices
        connectedGatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, gattCallback)
        }
    }

    fun disconnect() {
        connectedGatt?.let { gatt ->
            gatt.disconnect()
            gatt.close()
        }
        connectedGatt = null
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothGatt.STATE_CONNECTED -> {
                    Log.i(TAG, "GATT connected, requesting MTU")
                    // Request large MTU for BLE data transfer
                    gatt.requestMtu(512)
                }
                BluetoothGatt.STATE_DISCONNECTED -> {
                    Log.i(TAG, "GATT disconnected (status=$status)")
                    val cb = connectCallback
                    connectCallback = null
                    if (cb != null) {
                        cb(false, "Disconnected (status=$status)")
                    }
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            Log.i(TAG, "MTU changed to $mtu (status=$status)")
            negotiatedMtu = mtu

            // Request high-priority connection interval (~7.5ms instead of ~30ms+)
            // This dramatically improves BLE throughput on Android
            gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)

            // Now discover services
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.i(TAG, "Services discovered: ${gatt.services.map { it.uuid }}")
                val cb = connectCallback
                connectCallback = null
                cb?.invoke(true, null)
            } else {
                Log.e(TAG, "Service discovery failed: $status")
                val cb = connectCallback
                connectCallback = null
                cb?.invoke(false, "Service discovery failed (status=$status)")
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            activeTransport?.onCharacteristicWrite(gatt, characteristic, status)
        }

        @Deprecated("Deprecated in API 33, keeping for backward compat")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            // Pre-API 33 callback (value is in characteristic.value)
            val value = characteristic.value ?: return
            activeTransport?.onCharacteristicChanged(gatt, characteristic, value)
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            activeTransport?.onDescriptorWrite(gatt, descriptor, status)
        }
    }

    // ── Cleanup ─────────────────────────────────────────────────────────────

    fun destroy() {
        stopScan()
        disconnect()
    }
}