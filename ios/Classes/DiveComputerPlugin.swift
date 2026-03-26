import Flutter
import UIKit
import CoreBluetooth
import LibDiveComputer

public class DiveComputerPlugin: NSObject, FlutterPlugin {

    private let methodChannel: FlutterMethodChannel
    private var scanEventSink: FlutterEventSink?
    lazy var bleManager: BLEManager = {
        let manager = BLEManager()
        manager.delegate = self
        return manager
    }()

    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private var discoveredDeviceNames: [String: String] = [:]

    // Active connection state
    private var bleTransport: BLETransport?
    private var dcContext: OpaquePointer?
    private var dcDevice: OpaquePointer?
    private var dcDescriptor: OpaquePointer?

    // Active download
    private var diveDownloader: DiveDownloader?

    init(channel: FlutterMethodChannel) {
        self.methodChannel = channel
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.example.libdivecomputer_plugin/methods",
            binaryMessenger: registrar.messenger()
        )

        let scanChannel = FlutterEventChannel(
            name: "com.example.libdivecomputer_plugin/scan",
            binaryMessenger: registrar.messenger()
        )

        let instance = DiveComputerPlugin(channel: methodChannel)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        scanChannel.setStreamHandler(ScanStreamHandler(plugin: instance))
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getLibraryVersion":
            result(getLibraryVersion())
        case "getSupportedDescriptors":
            result(getSupportedDescriptors())
        case "stopScan":
            bleManager.stopScan()
            result(nil)
        case "connectToDevice":
            handleConnect(call: call, result: result)
        case "disconnect":
            handleDisconnect(result: result)
        case "resetFingerprint":
            handleResetFingerprint(result: result)
        case "startDownload":
            handleStartDownload(call: call, result: result)
        case "cancelDownload":
            handleCancelDownload(result: result)
        case "getDownloadProgress":
            handleGetDownloadProgress(result: result)
        case "getDownloadedDives":
            handleGetDownloadedDives(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - libdivecomputer queries

    private func getLibraryVersion() -> String {
        var version = dc_version_t()
        dc_version(&version)
        return "libdivecomputer \(version.major).\(version.minor).\(version.micro)"
    }

    private func getSupportedDescriptors() -> [[String: Any]] {
        var descriptors: [[String: Any]] = []
        var iterator: OpaquePointer?
        guard dc_descriptor_iterator_new(&iterator, nil) == DC_STATUS_SUCCESS else {
            return descriptors
        }
        var descriptor: OpaquePointer?
        while dc_iterator_next(iterator, &descriptor) == DC_STATUS_SUCCESS {
            guard let desc = descriptor else { continue }
            let vendor = String(cString: dc_descriptor_get_vendor(desc))
            let product = String(cString: dc_descriptor_get_product(desc))
            let family = dc_descriptor_get_type(desc)
            let model = dc_descriptor_get_model(desc)
            let transports = dc_descriptor_get_transports(desc)
            descriptors.append([
                "vendor": vendor,
                "product": product,
                "family": family.rawValue,
                "model": model,
                "transports": transports,
            ])
            dc_descriptor_free(desc)
        }
        dc_iterator_free(iterator)
        return descriptors
    }

    // MARK: - Connection

    private func handleConnect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let address = args["address"] as? String,
              let vendor = args["vendor"] as? String,
              let product = args["product"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing address, vendor, or product", details: nil))
            return
        }

        guard let peripheral = discoveredPeripherals[address] else {
            result(FlutterError(code: "NO_DEVICE", message: "Device not found. Try scanning again.", details: nil))
            return
        }

        let deviceName = discoveredDeviceNames[address] ?? peripheral.name ?? "Unknown"

        guard let descriptor = bleManager.findDescriptor(vendor: vendor, product: product) else {
            result(FlutterError(code: "NO_DESCRIPTOR", message: "No libdivecomputer descriptor for \(vendor) \(product)", details: nil))
            return
        }
        self.dcDescriptor = descriptor

        NSLog("[Plugin] Connecting to \(vendor) \(product) (\(deviceName)) at \(address)")

        bleManager.connect(peripheral: peripheral) { [weak self] success, error in
            guard let self = self else { return }

            guard success else {
                self.cleanupConnection()
                result(FlutterError(code: "CONNECT_FAILED", message: error ?? "Connection failed", details: nil))
                return
            }

            let transport = BLETransport(peripheral: peripheral, name: deviceName)
            self.bleTransport = transport

            transport.setup(context: nil) { [weak self] ready, setupError in
                guard let self = self else { return }

                guard ready else {
                    self.cleanupConnection()
                    result(FlutterError(code: "SETUP_FAILED", message: setupError ?? "BLE setup failed", details: nil))
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    let openResult = self.openDiveComputerDevice(descriptor: descriptor, transport: transport)

                    DispatchQueue.main.async {
                        if openResult {
                            NSLog("[Plugin] Device opened successfully!")
                            result(true)
                        } else {
                            self.cleanupConnection()
                            result(FlutterError(code: "DEVICE_OPEN_FAILED",
                                                message: "Failed to open dive computer device",
                                                details: nil))
                        }
                    }
                }
            }
        }
    }

    private func openDiveComputerDevice(descriptor: OpaquePointer, transport: BLETransport) -> Bool {
        var context: OpaquePointer?
        var status = dc_context_new(&context)
        guard status == DC_STATUS_SUCCESS, let ctx = context else {
            NSLog("[Plugin] dc_context_new failed: \(status.rawValue)")
            return false
        }
        self.dcContext = ctx

        dc_context_set_loglevel(ctx, DC_LOGLEVEL_WARNING)
        dc_context_set_logfunc(ctx, { _, loglevel, file, line, function, message, _ in
            guard let message = message else { return }
            let msg = String(cString: message)
            let level: String
            switch loglevel {
            case DC_LOGLEVEL_ERROR:   level = "ERROR"
            case DC_LOGLEVEL_WARNING: level = "WARN"
            case DC_LOGLEVEL_INFO:    level = "INFO"
            case DC_LOGLEVEL_DEBUG:   level = "DEBUG"
            default:                  level = "???"
            }
            NSLog("[libdivecomputer] [\(level)] \(msg)")
        }, nil)

        guard let iostream = transport.iostream else {
            NSLog("[Plugin] No iostream available")
            return false
        }

        var device: OpaquePointer?
        status = dc_device_open(&device, ctx, descriptor, iostream)
        guard status == DC_STATUS_SUCCESS, device != nil else {
            NSLog("[Plugin] dc_device_open failed: \(status.rawValue)")
            return false
        }
        self.dcDevice = device

        NSLog("[Plugin] dc_device_open succeeded")
        return true
    }

    // MARK: - Download (polling model)

    private func handleStartDownload(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let device = dcDevice else {
            result(FlutterError(code: "NO_DEVICE", message: "No dive computer connected", details: nil))
            return
        }

        var forceDownload = false
        if let args = call.arguments as? [String: Any],
           let force = args["forceDownload"] as? Bool {
            forceDownload = force
        }

        NSLog("[Plugin] Starting dive download (forceDownload=\(forceDownload))")

        bleTransport?.prepareForNewOperation()

        let downloader = DiveDownloader(device: device, forceDownload: forceDownload) { [weak self] finalProgress in
            NSLog("[Plugin] Download complete: \(finalProgress.status ?? "unknown"), \(finalProgress.diveCount) dives")
            _ = self?.diveDownloader
        }

        self.diveDownloader = downloader
        downloader.start()
        result(nil)
    }

    private func handleCancelDownload(result: @escaping FlutterResult) {
        diveDownloader?.cancel()
        result(nil)
    }

    private func handleGetDownloadProgress(result: @escaping FlutterResult) {
        guard let downloader = diveDownloader else {
            result([
                "isActive": false,
                "progressFraction": 0.0,
                "diveCount": 0,
            ] as [String: Any])
            return
        }
        result(downloader.getProgress().toMap())
    }

    private func handleGetDownloadedDives(result: @escaping FlutterResult) {
        guard let downloader = diveDownloader else {
            result([])
            return
        }
        result(downloader.getDownloadedDives())
    }

    // MARK: - Fingerprint Management

    private func handleResetFingerprint(result: @escaping FlutterResult) {
        FingerprintStore.deleteAll()
        NSLog("[Plugin] All saved fingerprints deleted")
        result(true)
    }

    // MARK: - Disconnection

    private func handleDisconnect(result: @escaping FlutterResult) {
        diveDownloader?.cancel()
        diveDownloader = nil
        cleanupConnection()
        bleManager.disconnect {
            result(nil)
        }
    }

    private func cleanupConnection() {
        if let device = dcDevice {
            dc_device_close(device)
            dcDevice = nil
            NSLog("[Plugin] dc_device closed")
        }

        if let iostream = bleTransport?.iostream {
            dc_iostream_close(iostream)
        }
        bleTransport = nil

        if let context = dcContext {
            dc_context_free(context)
            dcContext = nil
        }

        if let descriptor = dcDescriptor {
            dc_descriptor_free(descriptor)
            dcDescriptor = nil
        }
    }

    // MARK: - Scan lifecycle

    func startScan() {
        discoveredPeripherals.removeAll()
        discoveredDeviceNames.removeAll()
        bleManager.startScan()
    }

    func setScanEventSink(_ sink: FlutterEventSink?) {
        self.scanEventSink = sink
    }
}

// MARK: - BLEManagerDelegate

extension DiveComputerPlugin: BLEManagerDelegate {

    func bleManager(_ manager: BLEManager, didDiscoverDevice device: DiscoveredDevice) {
        discoveredPeripherals[device.peripheral.identifier.uuidString] = device.peripheral
        discoveredDeviceNames[device.peripheral.identifier.uuidString] = device.name
        scanEventSink?(device.toMap)
    }

    func bleManager(_ manager: BLEManager, didUpdateState state: CBManagerState) {
        if state == .poweredOn {
            NSLog("[DiveComputerPlugin] Bluetooth ready")
        }
    }

    func bleManager(_ manager: BLEManager, didFailWithError message: String) {
        scanEventSink?(FlutterError(
            code: "BLE_ERROR",
            message: message,
            details: nil
        ))
    }
}

// MARK: - Stream Handlers

class ScanStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: DiveComputerPlugin?
    init(plugin: DiveComputerPlugin) { self.plugin = plugin }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.setScanEventSink(events)
        plugin?.startScan()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.bleManager.stopScan()
        plugin?.setScanEventSink(nil)
        return nil
    }
}