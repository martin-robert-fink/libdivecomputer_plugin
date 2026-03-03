import Foundation
import LibDiveComputer

/// Snapshot of download progress, safe to read from any thread.
struct DownloadProgress {
    let isActive: Bool
    let progressFraction: Double
    let diveCount: Int
    let estimatedTotalDives: Int?
    let serial: UInt32?
    let firmware: UInt32?
    /// nil while active; "success", "done", or "error(N)" when finished
    let status: String?

    func toMap() -> [String: Any?] {
        return [
            "isActive": isActive,
            "progressFraction": progressFraction,
            "diveCount": diveCount,
            "estimatedTotalDives": estimatedTotalDives,
            "serial": serial != nil ? Int(serial!) : nil,
            "firmware": firmware != nil ? Int(firmware!) : nil,
            "status": status,
        ]
    }
}

/// Raw dive data stored during download, parsed after BLE transfer completes.
private struct RawDiveData {
    let data: Data
    let fingerprint: Data?
}

/// Manages the dive download process using libdivecomputer's
/// dc_device_foreach and dc_parser APIs. Runs entirely on a
/// background DispatchQueue to avoid blocking the main thread.
///
/// Design (matching Subsurface):
/// - All BLE work happens on a background thread with NO parsing
/// - Raw dive bytes are stored in memory during download
/// - Parsing happens AFTER dc_device_foreach completes (BLE is done)
/// - Progress is written to shared properties (no main queue dispatches)
/// - The UI polls progress via a MethodChannel timer
class DiveDownloader {

    private let device: OpaquePointer     // dc_device_t*
    private let forceDownload: Bool
    private let completion: (DownloadProgress) -> Void

    // MARK: - Shared State (written from background, read from main)

    private let stateLock = NSLock()

    private var _progressFraction: Double = 0
    private var _diveCount: Int = 0
    private var _estimatedTotalDives: Int? = nil
    private var _serial: UInt32? = nil
    private var _firmware: UInt32? = nil
    private var _isActive: Bool = true
    private var _status: String? = nil

    /// Raw dive data accumulated during download (pre-parsing).
    private var _rawDives: [RawDiveData] = []

    /// Full parsed dive data, populated after download completes.
    private var _downloadedDives: [[String: Any]] = []

    fileprivate var isCancelled = false

    /// Track progress state for dive count estimation
    fileprivate var lastProgressCurrent: Int = 0
    fileprivate var lastProgressMaximum: Int = 0

    /// Whether we've received devinfo (and set fingerprint)
    fileprivate var devInfoReceived = false

    init(device: OpaquePointer, forceDownload: Bool = false,
         completion: @escaping (DownloadProgress) -> Void) {
        self.device = device
        self.forceDownload = forceDownload
        self.completion = completion
    }

    /// Start the download on a background thread.
    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performDownload()
        }
    }

    func cancel() {
        isCancelled = true
    }

    // MARK: - Progress Snapshot (thread-safe read)

    /// Returns a snapshot of the current download state.
    /// Safe to call from any thread (main thread for MethodChannel).
    func getProgress() -> DownloadProgress {
        stateLock.lock()
        let progress = DownloadProgress(
            isActive: _isActive,
            progressFraction: _progressFraction,
            diveCount: _diveCount,
            estimatedTotalDives: _estimatedTotalDives,
            serial: _serial,
            firmware: _firmware,
            status: _status
        )
        stateLock.unlock()
        return progress
    }

    /// Returns all downloaded dive data. Call only after download completes.
    func getDownloadedDives() -> [[String: Any]] {
        return _downloadedDives
    }

    // MARK: - State Updates (called from background thread)

    fileprivate func updateProgress(fraction: Double) {
        stateLock.lock()
        _progressFraction = fraction
        stateLock.unlock()
    }

    fileprivate func updateDiveCount(_ count: Int) {
        stateLock.lock()
        _diveCount = count
        stateLock.unlock()
    }

    fileprivate func updateEstimatedTotal(_ total: Int) {
        stateLock.lock()
        _estimatedTotalDives = total
        stateLock.unlock()
    }

    fileprivate func updateDevInfo(serial: UInt32, firmware: UInt32) {
        stateLock.lock()
        _serial = serial
        _firmware = firmware
        stateLock.unlock()
    }

    private func finish(status: String) {
        stateLock.lock()
        _isActive = false
        _status = status
        _progressFraction = 1.0
        stateLock.unlock()

        let finalProgress = getProgress()
        NSLog("[DiveDownloader] Download finished: \(status), \(_diveCount) dives")

        // Single callback on main thread when complete
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.completion(finalProgress)
        }
    }

    // MARK: - Download

    private func performDownload() {
        NSLog("[DiveDownloader] Starting dive download")

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Register for progress and devinfo events
        dc_device_set_events(device,
                             UInt32(DC_EVENT_PROGRESS.rawValue | DC_EVENT_DEVINFO.rawValue),
                             deviceEventCallback,
                             selfPtr)

        // Set cancel callback
        dc_device_set_cancel(device, deviceCancelCallback, selfPtr)

        // Enumerate dives — raw bytes only, NO parsing during BLE transfer
        let status = dc_device_foreach(device, diveCallback, selfPtr)

        let statusName: String
        switch status {
        case DC_STATUS_SUCCESS: statusName = "success"
        case DC_STATUS_DONE:    statusName = "done"
        default:                statusName = "error(\(status.rawValue))"
        }

        NSLog("[DiveDownloader] BLE transfer complete (\(statusName)), parsing \(_rawDives.count) dives...")

        // Parse all dives AFTER BLE transfer is complete
        parseAllDives()

        finish(status: statusName)
    }

    // MARK: - Raw Dive Storage (called during BLE download)

    /// Stores raw dive bytes during download. No parsing happens here.
    fileprivate func storeRawDive(data: UnsafePointer<UInt8>, size: UInt32,
                                   fingerprint: UnsafePointer<UInt8>?, fpSize: UInt32) -> Bool {

        stateLock.lock()
        _diveCount += 1
        let diveNumber = _diveCount
        stateLock.unlock()

        // Estimate total dives when the first dive arrives
        if diveNumber == 1 && lastProgressMaximum > 0 {
            let totalSteps = lastProgressMaximum / 10000
            if totalSteps > 0 {
                updateEstimatedTotal(totalSteps)
                NSLog("[DiveDownloader] Estimated total dives: ~\(totalSteps) (from progress max=\(lastProgressMaximum))")
            }
        }

        // Save fingerprint from the first (newest) dive
        let fpData: Data?
        if let fp = fingerprint, fpSize > 0 {
            fpData = Data(bytes: fp, count: Int(fpSize))
        } else {
            fpData = nil
        }

        if diveNumber == 1, let fpData = fpData {
            stateLock.lock()
            let serial = _serial
            stateLock.unlock()

            if let serial = serial {
                saveFingerprint(fpData, serial: serial)
            }
        }

        // Store raw bytes — parsing deferred until after download
        let rawData = Data(bytes: data, count: Int(size))
        _rawDives.append(RawDiveData(data: rawData, fingerprint: fpData))

        NSLog("[DiveDownloader] Stored raw dive #\(diveNumber) (\(size) bytes)")
        return true
    }

    // MARK: - Deferred Parsing (runs after BLE transfer completes)

    private func parseAllDives() {
        stateLock.lock()
        let total = _estimatedTotalDives
        stateLock.unlock()

        for (index, rawDive) in _rawDives.enumerated() {
            let diveNumber = index + 1

            var parser: OpaquePointer?
            let status = rawDive.data.withUnsafeBytes { ptr -> dc_status_t in
                guard let baseAddress = ptr.baseAddress else { return DC_STATUS_INVALIDARGS }
                return dc_parser_new(&parser, device,
                                     baseAddress.assumingMemoryBound(to: UInt8.self),
                                     rawDive.data.count)
            }

            guard status == DC_STATUS_SUCCESS, let parser = parser else {
                NSLog("[DiveDownloader] Failed to create parser for dive \(diveNumber): \(status.rawValue)")
                _downloadedDives.append([
                    "number": diveNumber,
                    "error": "Parser creation failed (\(status.rawValue))",
                ])
                continue
            }

            defer { dc_parser_destroy(parser) }

            var diveEvent: [String: Any] = [
                "number": diveNumber,
            ]

            if let total = total {
                diveEvent["totalDives"] = total
            }

            // DateTime
            var datetime = dc_datetime_t()
            if dc_parser_get_datetime(parser, &datetime) == DC_STATUS_SUCCESS {
                let dateStr = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                                     datetime.year, datetime.month, datetime.day,
                                     datetime.hour, datetime.minute, datetime.second)
                diveEvent["dateTime"] = dateStr
            }

            // Dive time (seconds)
            var divetime: UInt32 = 0
            if dc_parser_get_field(parser, DC_FIELD_DIVETIME, 0, &divetime) == DC_STATUS_SUCCESS {
                diveEvent["diveTime"] = Int(divetime)
            }

            // Max depth (meters)
            var maxdepth: Double = 0
            if dc_parser_get_field(parser, DC_FIELD_MAXDEPTH, 0, &maxdepth) == DC_STATUS_SUCCESS {
                diveEvent["maxDepth"] = maxdepth
            }

            // Avg depth (meters)
            var avgdepth: Double = 0
            if dc_parser_get_field(parser, DC_FIELD_AVGDEPTH, 0, &avgdepth) == DC_STATUS_SUCCESS {
                diveEvent["avgDepth"] = avgdepth
            }

            // Temperature (minimum)
            var minTemp: Double = 0
            if dc_parser_get_field(parser, DC_FIELD_TEMPERATURE_MINIMUM, 0, &minTemp) == DC_STATUS_SUCCESS {
                diveEvent["minTemperature"] = minTemp
            }

            // Temperature (maximum)
            var maxTemp: Double = 0
            if dc_parser_get_field(parser, DC_FIELD_TEMPERATURE_MAXIMUM, 0, &maxTemp) == DC_STATUS_SUCCESS {
                diveEvent["maxTemperature"] = maxTemp
            }

            // Surface temperature
            var surfTemp: Double = 0
            if dc_parser_get_field(parser, DC_FIELD_TEMPERATURE_SURFACE, 0, &surfTemp) == DC_STATUS_SUCCESS {
                diveEvent["surfaceTemperature"] = surfTemp
            }

            // Dive mode
            var divemode = DC_DIVEMODE_OC
            if dc_parser_get_field(parser, DC_FIELD_DIVEMODE, 0, &divemode) == DC_STATUS_SUCCESS {
                let modeStr: String
                switch divemode {
                case DC_DIVEMODE_FREEDIVE: modeStr = "freedive"
                case DC_DIVEMODE_GAUGE:    modeStr = "gauge"
                case DC_DIVEMODE_OC:       modeStr = "OC"
                case DC_DIVEMODE_CCR:      modeStr = "CCR"
                case DC_DIVEMODE_SCR:      modeStr = "SCR"
                default:                   modeStr = "unknown"
                }
                diveEvent["diveMode"] = modeStr
            }

            // Atmospheric pressure
            var atmospheric: Double = 0
            if dc_parser_get_field(parser, DC_FIELD_ATMOSPHERIC, 0, &atmospheric) == DC_STATUS_SUCCESS {
                diveEvent["atmospheric"] = atmospheric
            }

            // Gas mixes
            var gasmixCount: UInt32 = 0
            if dc_parser_get_field(parser, DC_FIELD_GASMIX_COUNT, 0, &gasmixCount) == DC_STATUS_SUCCESS,
               gasmixCount > 0 {
                var mixes: [[String: Any]] = []
                for i in 0..<gasmixCount {
                    var gasmix = dc_gasmix_t()
                    if dc_parser_get_field(parser, DC_FIELD_GASMIX, i, &gasmix) == DC_STATUS_SUCCESS {
                        mixes.append([
                            "oxygen": gasmix.oxygen,
                            "helium": gasmix.helium,
                            "nitrogen": gasmix.nitrogen,
                        ])
                    }
                }
                if !mixes.isEmpty {
                    diveEvent["gasMixes"] = mixes
                }
            }

            // Tank info
            var tankCount: UInt32 = 0
            if dc_parser_get_field(parser, DC_FIELD_TANK_COUNT, 0, &tankCount) == DC_STATUS_SUCCESS,
               tankCount > 0 {
                var tanks: [[String: Any]] = []
                for i in 0..<tankCount {
                    var tank = dc_tank_t()
                    if dc_parser_get_field(parser, DC_FIELD_TANK, i, &tank) == DC_STATUS_SUCCESS {
                        var tankMap: [String: Any] = [
                            "beginPressure": tank.beginpressure,
                            "endPressure": tank.endpressure,
                        ]
                        if tank.volume > 0 {
                            tankMap["volume"] = tank.volume
                        }
                        if tank.workpressure > 0 {
                            tankMap["workPressure"] = tank.workpressure
                        }
                        if tank.gasmix != DC_GASMIX_UNKNOWN {
                            tankMap["gasmix"] = Int(tank.gasmix)
                        }
                        tanks.append(tankMap)
                    }
                }
                if !tanks.isEmpty {
                    diveEvent["tanks"] = tanks
                }
            }

            // Depth profile samples
            let sampleCollector = SampleCollector()
            let samplePtr = Unmanaged.passUnretained(sampleCollector).toOpaque()
            dc_parser_samples_foreach(parser, sampleCallback, samplePtr)
            sampleCollector.flush()

            if !sampleCollector.samples.isEmpty {
                diveEvent["samples"] = sampleCollector.samples
                diveEvent["sampleCount"] = sampleCollector.samples.count
            }

            // Fingerprint
            if let fpData = rawDive.fingerprint {
                diveEvent["fingerprint"] = fpData.map { String(format: "%02x", $0) }.joined()
            }

            NSLog("[DiveDownloader] Parsed dive #\(diveNumber)\(total != nil ? "/\(total!)" : ""): " +
                  "depth=\(diveEvent["maxDepth"] ?? "?")m, " +
                  "time=\(diveEvent["diveTime"] ?? "?")s, samples=\(sampleCollector.samples.count)")

            _downloadedDives.append(diveEvent)
        }

        NSLog("[DiveDownloader] Parsing complete: \(_downloadedDives.count) dives parsed")
    }

    // MARK: - Fingerprint Persistence

    fileprivate func loadAndSetFingerprint(serial: UInt32) {
        if forceDownload {
            NSLog("[DiveDownloader] Force download — skipping saved fingerprint")
            return
        }

        guard let fpData = FingerprintStore.load(serial: serial) else {
            NSLog("[DiveDownloader] No saved fingerprint for serial \(serial)")
            return
        }

        let status = fpData.withUnsafeBytes { ptr -> dc_status_t in
            guard let baseAddress = ptr.baseAddress else { return DC_STATUS_INVALIDARGS }
            return dc_device_set_fingerprint(
                device,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt32(fpData.count)
            )
        }

        if status == DC_STATUS_SUCCESS {
            NSLog("[DiveDownloader] Loaded fingerprint for serial \(serial): \(fpData.map { String(format: "%02x", $0) }.joined())")
        } else {
            NSLog("[DiveDownloader] Failed to set fingerprint: \(status.rawValue)")
        }
    }

    fileprivate func saveFingerprint(_ data: Data, serial: UInt32) {
        FingerprintStore.save(serial: serial, fingerprint: data)
        NSLog("[DiveDownloader] Saved fingerprint for serial \(serial): \(data.map { String(format: "%02x", $0) }.joined())")
    }
}

// MARK: - Fingerprint Store

struct FingerprintStore {

    private static var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DiveComputer/fingerprints", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(serial: UInt32, fingerprint: Data) {
        let file = directory.appendingPathComponent("\(serial).fp")
        try? fingerprint.write(to: file)
    }

    static func load(serial: UInt32) -> Data? {
        let file = directory.appendingPathComponent("\(serial).fp")
        return try? Data(contentsOf: file)
    }

    static func delete(serial: UInt32) {
        let file = directory.appendingPathComponent("\(serial).fp")
        try? FileManager.default.removeItem(at: file)
    }

    static func deleteAll() {
        let dir = directory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "fp" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - Sample Collector

fileprivate class SampleCollector {
    var samples: [[String: Any]] = []
    var currentSample: [String: Any] = [:]

    func flush() {
        if !currentSample.isEmpty {
            samples.append(currentSample)
            currentSample = [:]
        }
    }
}

// MARK: - C Callbacks

private let deviceEventCallback: @convention(c)
    (OpaquePointer?, dc_event_type_t, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void =
{ _, event, data, userdata in
    guard let userdata = userdata, let data = data else { return }
    let downloader = Unmanaged<DiveDownloader>.fromOpaque(userdata).takeUnretainedValue()

    switch event {
    case DC_EVENT_PROGRESS:
        let progress = data.assumingMemoryBound(to: dc_event_progress_t.self).pointee
        let current = Int(progress.current)
        let maximum = Int(progress.maximum)

        downloader.lastProgressCurrent = current
        downloader.lastProgressMaximum = maximum

        // Just update a shared variable — no main queue dispatch
        if maximum > 0 {
            downloader.updateProgress(fraction: Double(current) / Double(maximum))
        }

    case DC_EVENT_DEVINFO:
        let devinfo = data.assumingMemoryBound(to: dc_event_devinfo_t.self).pointee
        let serial = devinfo.serial
        let firmware = devinfo.firmware
        NSLog("[DiveDownloader] DevInfo: model=\(devinfo.model) fw=\(firmware) serial=\(serial)")

        downloader.devInfoReceived = true
        downloader.updateDevInfo(serial: serial, firmware: firmware)
        downloader.loadAndSetFingerprint(serial: serial)

    default:
        break
    }
}

private let deviceCancelCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { userdata in
    guard let userdata = userdata else { return 0 }
    let downloader = Unmanaged<DiveDownloader>.fromOpaque(userdata).takeUnretainedValue()
    return downloader.isCancelled ? 1 : 0
}

private let diveCallback: @convention(c)
    (UnsafePointer<UInt8>?, UInt32, UnsafePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?) -> Int32 =
{ data, size, fingerprint, fpSize, userdata in
    guard let userdata = userdata, let data = data, size > 0 else { return 1 }
    let downloader = Unmanaged<DiveDownloader>.fromOpaque(userdata).takeUnretainedValue()

    // Store raw bytes only — NO parsing during BLE transfer
    let shouldContinue = downloader.storeRawDive(data: data, size: size,
                                                  fingerprint: fingerprint, fpSize: fpSize)
    return shouldContinue ? 1 : 0
}

private let sampleCallback: @convention(c)
    (dc_sample_type_t, UnsafePointer<dc_sample_value_t>?, UnsafeMutableRawPointer?) -> Void =
{ type, value, userdata in
    guard let userdata = userdata, let value = value else { return }
    let collector = Unmanaged<SampleCollector>.fromOpaque(userdata).takeUnretainedValue()

    switch type {
    case DC_SAMPLE_TIME:
        collector.flush()
        collector.currentSample["time"] = Int(value.pointee.time)

    case DC_SAMPLE_DEPTH:
        collector.currentSample["depth"] = value.pointee.depth

    case DC_SAMPLE_TEMPERATURE:
        collector.currentSample["temperature"] = value.pointee.temperature

    case DC_SAMPLE_PRESSURE:
        collector.currentSample["pressure"] = value.pointee.pressure.value
        collector.currentSample["tank"] = Int(value.pointee.pressure.tank)

    case DC_SAMPLE_SETPOINT:
        collector.currentSample["setpoint"] = value.pointee.setpoint

    case DC_SAMPLE_PPO2:
        collector.currentSample["ppo2"] = value.pointee.ppo2.value

    case DC_SAMPLE_CNS:
        collector.currentSample["cns"] = value.pointee.cns

    case DC_SAMPLE_DECO:
        collector.currentSample["decoType"] = Int(value.pointee.deco.type)
        collector.currentSample["decoDepth"] = value.pointee.deco.depth
        collector.currentSample["decoTime"] = Int(value.pointee.deco.time)
        collector.currentSample["tts"] = Int(value.pointee.deco.tts)

    case DC_SAMPLE_HEARTBEAT:
        collector.currentSample["heartbeat"] = Int(value.pointee.heartbeat)

    case DC_SAMPLE_GASMIX:
        collector.currentSample["gasmix"] = Int(value.pointee.gasmix)

    default:
        break
    }
}