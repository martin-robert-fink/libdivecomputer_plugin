package com.example.libdivecomputer_plugin

import android.bluetooth.BluetoothDevice
import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

/**
 * Android implementation of the dive_computer Flutter plugin.
 *
 * Architecture mirrors the iOS/macOS Swift plugin:
 * - MethodChannel for request/response calls
 * - EventChannel for BLE scan events
 * - Polling-based download progress (no main-thread work during BLE)
 * - All libdivecomputer operations via JNI on a background thread
 */
class DiveComputerPlugin : FlutterPlugin, MethodCallHandler {

    companion object {
        private const val TAG = "DiveComputerPlugin"

        init {
            // libdivecomputer is statically linked into dive_computer_jni
            System.loadLibrary("libdivecomputer_plugin_jni")
        }
    }

    // Flutter channels
    private lateinit var methodChannel: MethodChannel
    private lateinit var scanEventChannel: EventChannel
    private var scanEventSink: EventChannel.EventSink? = null

    // Application context (for BLE and file storage)
    private lateinit var appContext: Context

    // BLE scanning & connection
    private lateinit var bleManager: BleManager
    private val discoveredDevices = mutableMapOf<String, BluetoothDevice>()
    private val discoveredDeviceNames = mutableMapOf<String, String>()

    // Active connection state
    private var bleTransport: BleTransport? = null
    private var dcContextPtr: Long = 0      // dc_context_t*
    private var dcDevicePtr: Long = 0       // dc_device_t*

    // Active download
    private var diveDownloader: DiveDownloader? = null

    // ── FlutterPlugin lifecycle ─────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext

        methodChannel = MethodChannel(
            binding.binaryMessenger,
            "com.example.libdivecomputer_plugin/methods"
        )
        methodChannel.setMethodCallHandler(this)

        scanEventChannel = EventChannel(
            binding.binaryMessenger,
            "com.example.libdivecomputer_plugin/scan"
        )
        scanEventChannel.setStreamHandler(ScanStreamHandler())

        bleManager = BleManager(appContext, bleManagerCallback)

        // Load libdivecomputer descriptors and pass to BLE manager
        try {
            val descriptors = nativeGetDescriptors()
            bleManager.loadDescriptors(descriptors)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load descriptors", e)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        scanEventChannel.setStreamHandler(null)
        bleManager.destroy()
    }

    // ── MethodChannel dispatch ──────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getLibraryVersion"     -> result.success(nativeGetVersion())
            "getSupportedDescriptors" -> handleGetDescriptors(result)
            "stopScan"              -> { bleManager.stopScan(); result.success(null) }
            "connectToDevice"       -> handleConnect(call, result)
            "disconnect"            -> handleDisconnect(result)
            "resetFingerprint"      -> handleResetFingerprint(result)
            "startDownload"         -> handleStartDownload(call, result)
            "cancelDownload"        -> handleCancelDownload(result)
            "getDownloadProgress"   -> handleGetDownloadProgress(result)
            "getDownloadedDives"    -> handleGetDownloadedDives(result)
            else -> result.notImplemented()
        }
    }

    // ── Library info (JNI) ──────────────────────────────────────────────────

    private external fun nativeGetVersion(): String
    private external fun nativeGetDescriptors(): Array<HashMap<String, Any>>
    private external fun nativeCreateContext(): Long
    private external fun nativeFreeContext(contextPtr: Long)
    private external fun nativeOpenDevice(
        contextPtr: Long, family: Int, model: Int, iostreamPtr: Long
    ): Long
    private external fun nativeCloseDevice(devicePtr: Long)

    private fun handleGetDescriptors(result: MethodChannel.Result) {
        try {
            val descriptors = nativeGetDescriptors()
            result.success(descriptors.toList())
        } catch (e: Exception) {
            Log.e(TAG, "getSupportedDescriptors failed", e)
            result.error("NATIVE_ERROR", e.message, null)
        }
    }

    // ── Connection ──────────────────────────────────────────────────────────

    private fun handleConnect(call: MethodCall, result: MethodChannel.Result) {
        val address = call.argument<String>("address")
        val vendor = call.argument<String>("vendor")
        val product = call.argument<String>("product")

        if (address == null || vendor == null || product == null) {
            result.error("INVALID_ARGS", "Missing address, vendor, or product", null)
            return
        }

        val device = discoveredDevices[address]
        if (device == null) {
            result.error("NO_DEVICE", "Device not found. Try scanning again.", null)
            return
        }

        val deviceName = discoveredDeviceNames[address] ?: device.name ?: "Unknown"
        val descriptorInfo = bleManager.findDescriptor(vendor, product)
        if (descriptorInfo == null) {
            result.error(
                "NO_DESCRIPTOR",
                "No libdivecomputer descriptor for $vendor $product",
                null
            )
            return
        }

        Log.i(TAG, "Connecting to $vendor $product ($deviceName) at $address")

        bleManager.connect(device) { success, error ->
            if (!success) {
                cleanupConnection()
                result.error("CONNECT_FAILED", error ?: "Connection failed", null)
                return@connect
            }

            // Create BLE transport and discover services
            val transport = BleTransport(bleManager, device, deviceName)
            bleTransport = transport
            bleManager.activeTransport = transport

            transport.setup { ready, setupError ->
                if (!ready) {
                    cleanupConnection()
                    result.error("SETUP_FAILED", setupError ?: "BLE setup failed", null)
                    return@setup
                }

                // Open device on a background thread (libdivecomputer is blocking)
                Thread {
                    val openResult = openDiveComputerDevice(
                        descriptorInfo.family, descriptorInfo.model, transport
                    )
                    // Return result on main thread
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        if (openResult) {
                            Log.i(TAG, "Device opened successfully!")
                            result.success(true)
                        } else {
                            cleanupConnection()
                            result.error(
                                "DEVICE_OPEN_FAILED",
                                "Failed to open dive computer device",
                                null
                            )
                        }
                    }
                }.start()
            }
        }
    }

    private fun openDiveComputerDevice(
        family: Int, model: Int, transport: BleTransport
    ): Boolean {
        val contextPtr = nativeCreateContext()
        if (contextPtr == 0L) {
            Log.e(TAG, "nativeCreateContext failed")
            return false
        }
        dcContextPtr = contextPtr

        val iostreamPtr = transport.createIostream(contextPtr)
        if (iostreamPtr == 0L) {
            Log.e(TAG, "createIostream failed")
            return false
        }

        val devicePtr = nativeOpenDevice(contextPtr, family, model, iostreamPtr)
        if (devicePtr == 0L) {
            Log.e(TAG, "nativeOpenDevice failed")
            return false
        }
        dcDevicePtr = devicePtr

        Log.i(TAG, "dc_device_open succeeded")
        return true
    }

    // ── Download (polling model) ────────────────────────────────────────────

    private fun handleStartDownload(call: MethodCall, result: MethodChannel.Result) {
        if (dcDevicePtr == 0L) {
            result.error("NO_DEVICE", "No dive computer connected", null)
            return
        }

        val forceDownload = call.argument<Boolean>("forceDownload") ?: false
        Log.i(TAG, "Starting dive download (forceDownload=$forceDownload)")

        bleTransport?.prepareForNewOperation()

        val downloader = DiveDownloader(
            appContext, dcDevicePtr, forceDownload
        )
        diveDownloader = downloader
        downloader.start()
        result.success(null)
    }

    private fun handleCancelDownload(result: MethodChannel.Result) {
        diveDownloader?.cancel()
        result.success(null)
    }

    private fun handleGetDownloadProgress(result: MethodChannel.Result) {
        val downloader = diveDownloader
        if (downloader == null) {
            result.success(
                mapOf(
                    "isActive" to false,
                    "progressFraction" to 0.0,
                    "diveCount" to 0
                )
            )
            return
        }
        result.success(downloader.getProgress())
    }

    private fun handleGetDownloadedDives(result: MethodChannel.Result) {
        val downloader = diveDownloader
        if (downloader == null) {
            result.success(emptyList<Map<String, Any>>())
            return
        }
        result.success(downloader.getDownloadedDives())
    }

    // ── Fingerprint management ──────────────────────────────────────────────

    private fun handleResetFingerprint(result: MethodChannel.Result) {
        FingerprintStore.deleteAll(appContext)
        Log.i(TAG, "All saved fingerprints deleted")
        result.success(true)
    }

    // ── Disconnection ───────────────────────────────────────────────────────

    private fun handleDisconnect(result: MethodChannel.Result) {
        diveDownloader?.cancel()
        diveDownloader = null
        cleanupConnection()
        bleManager.disconnect()
        result.success(null)
    }

    private fun cleanupConnection() {
        if (dcDevicePtr != 0L) {
            nativeCloseDevice(dcDevicePtr)
            dcDevicePtr = 0
            Log.i(TAG, "dc_device closed")
        }

        bleTransport?.close()
        bleTransport = null
        bleManager.activeTransport = null

        if (dcContextPtr != 0L) {
            nativeFreeContext(dcContextPtr)
            dcContextPtr = 0
        }
    }

    // ── BLE Manager callback ────────────────────────────────────────────────

    private val bleManagerCallback = object : BleManager.Callback {
        override fun onDeviceDiscovered(device: DiscoveredDevice) {
            discoveredDevices[device.address] = device.bluetoothDevice
            discoveredDeviceNames[device.address] = device.name
            // Send to Flutter via EventChannel (on main thread)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                scanEventSink?.success(device.toMap())
            }
        }

        override fun onScanFailed(errorMessage: String) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                scanEventSink?.error("BLE_ERROR", errorMessage, null)
            }
        }
    }

    // ── Scan Stream Handler ─────────────────────────────────────────────────

    private inner class ScanStreamHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            scanEventSink = events
            discoveredDevices.clear()
            discoveredDeviceNames.clear()
            bleManager.startScan()
        }

        override fun onCancel(arguments: Any?) {
            bleManager.stopScan()
            scanEventSink = null
        }
    }
}
