import 'package:flutter/services.dart';

import 'libdivecomputer_exception.dart';
import 'models/dc_device_info.dart';
import 'models/dc_dive.dart';
import 'models/dc_dive_computer.dart';
import 'models/dc_download_progress.dart';

/// Plugin interface for communicating with dive computers via libdivecomputer.
///
/// ## Scanning
///
/// Use [scanForDevices] to discover nearby BLE dive computers. The stream
/// emits typed [DcDeviceInfo] objects as they are found:
///
/// ```dart
/// final subscription = plugin.scanForDevices().listen((device) {
///   print('Found ${device.displayName}');
/// });
/// // Later:
/// await plugin.stopScan();
/// ```
///
/// ## Connecting
///
/// Call [connectToDevice] with the [DcDeviceInfo] returned from scanning:
///
/// ```dart
/// final connected = await plugin.connectToDevice(device);
/// ```
///
/// ## Downloading dives
///
/// Downloads use a polling model that avoids main-queue congestion on iOS
/// (matching the architecture used by Subsurface):
///
/// 1. Call [startDownload] to begin.
/// 2. Poll [getDownloadProgress] on a timer (e.g. every 250 ms).
/// 3. When [DcDownloadProgress.isComplete] becomes `true`, call
///    [getDownloadedDives] to retrieve the full dive data.
///
/// ## Error handling
///
/// All methods throw [DiveComputerException] on failure, which provides
/// structured access to the error [DiveComputerException.code] and an
/// optional typed [DiveComputerException.status].
class DiveComputerPlugin {
  DiveComputerPlugin._();

  /// The shared singleton instance.
  static final DiveComputerPlugin instance = DiveComputerPlugin._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.libdivecomputer_plugin/methods',
  );

  static const EventChannel _scanChannel = EventChannel(
    'com.example.libdivecomputer_plugin/scan',
  );

  // ---------------------------------------------------------------------------
  // Library info
  // ---------------------------------------------------------------------------

  /// Returns the libdivecomputer version string (e.g. `"libdivecomputer 0.10.0"`).
  ///
  /// Throws [DiveComputerException] if the native call fails.
  Future<String> getLibraryVersion() async {
    try {
      final version = await _channel.invokeMethod<String>('getLibraryVersion');
      return version ?? 'unknown';
    } on PlatformException catch (e) {
      throw DiveComputerException.fromPlatformException(e);
    }
  }

  /// Returns the list of all dive computer models supported by
  /// the bundled libdivecomputer build.
  ///
  /// Throws [DiveComputerException] if the native call fails.
  Future<List<DcDiveComputer>> getSupportedDescriptors() async {
    try {
      final result = await _channel.invokeMethod<List>(
        'getSupportedDescriptors',
      );
      if (result == null) return [];
      return result
          .cast<Map>()
          .map((m) => DcDiveComputer.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } on PlatformException catch (e) {
      throw DiveComputerException.fromPlatformException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  /// Starts a BLE scan and returns a stream of discovered [DcDeviceInfo].
  ///
  /// The stream is a broadcast stream backed by a platform EventChannel.
  /// Scanning begins when the stream is first listened to and stops when
  /// cancelled or when [stopScan] is called.
  ///
  /// Devices may be emitted multiple times as their RSSI updates.
  Stream<DcDeviceInfo> scanForDevices() {
    return _scanChannel.receiveBroadcastStream().map(
      (event) => DcDeviceInfo.fromMap(Map<String, dynamic>.from(event as Map)),
    );
  }

  /// Stops an active BLE scan.
  ///
  /// Safe to call even if no scan is running.
  Future<void> stopScan() async {
    try {
      await _channel.invokeMethod('stopScan');
    } on PlatformException catch (e) {
      throw DiveComputerException.fromPlatformException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  /// Connects to a previously discovered dive computer.
  ///
  /// Pass the [DcDeviceInfo] object received from [scanForDevices].
  /// Returns `true` if the connection succeeded.
  ///
  /// Throws [DiveComputerException] on connection failure (e.g. timeout,
  /// device not found, BLE setup failure).
  Future<bool> connectToDevice(DcDeviceInfo device) async {
    try {
      final result = await _channel.invokeMethod<bool>('connectToDevice', {
        'address': device.address,
        'vendor': device.vendor,
        'product': device.product,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      throw DiveComputerException.fromPlatformException(e);
    }
  }

  /// Disconnects from the currently connected dive computer.
  ///
  /// Safe to call even if no device is connected. Cleans up all native
  /// resources (iostream, device handle, BLE connection).
  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } on PlatformException catch (e) {
      throw DiveComputerException.fromPlatformException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Download
  // ---------------------------------------------------------------------------

  /// Starts downloading dives from the connected dive computer.
  ///
  /// Returns immediately. Use [getDownloadProgress] to poll for progress
  /// and [getDownloadedDives] to retrieve the dive data after completion.
  ///
  /// Set [forceDownload] to `true` to ignore the stored fingerprint and
  /// re-download all dives (equivalent to a full dump).
  ///
  /// Throws [DiveComputerException] if no device is connected.
  Future<void> startDownload({bool forceDownload = false}) async {
    try {
      await _channel.invokeMethod('startDownload', {
        'forceDownload': forceDownload,
      });
    } on PlatformException catch (e) {
      throw DiveComputerException.fromPlatformException(e);
    }
  }

  /// Cancels an active dive download.
  ///
  /// The cancellation is cooperative — the native side sets a flag that
  /// libdivecomputer checks on the next callback. The download will
  /// complete shortly after with a `cancelled` status. Continue polling
  /// [getDownloadProgress] until [DcDownloadProgress.isComplete].
  Future<void> cancelDownload() async {
    try {
      await _channel.invokeMethod('cancelDownload');
    } on PlatformException catch (e) {
      throw DiveComputerException.fromPlatformException(e);
    }
  }

  /// Returns the current download progress as a typed [DcDownloadProgress].
  ///
  /// Call this on a timer (recommended: every 250 ms) after [startDownload].
  /// Returns [DcDownloadProgress.idle] if no download state is available.
  Future<DcDownloadProgress> getDownloadProgress() async {
    try {
      final result = await _channel.invokeMethod<Map>('getDownloadProgress');
      if (result == null) return DcDownloadProgress.idle;
      return DcDownloadProgress.fromMap(Map<String, dynamic>.from(result));
    } on PlatformException catch (e) {
      throw DiveComputerException.fromPlatformException(e);
    }
  }

  /// Retrieves all dives downloaded during the current session.
  ///
  /// Call this after [getDownloadProgress] reports that the download is
  /// complete. Each [DcDive] includes full header data, gas mixes, tank
  /// info, and the complete depth-profile [DcDive.samples].
  ///
  /// Returns an empty list if no dives have been downloaded.
  Future<List<DcDive>> getDownloadedDives() async {
    try {
      final result = await _channel.invokeMethod<List>('getDownloadedDives');
      if (result == null) return [];
      return result
          .cast<Map>()
          .map((m) => DcDive.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } on PlatformException catch (e) {
      throw DiveComputerException.fromPlatformException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Fingerprint management
  // ---------------------------------------------------------------------------

  /// Resets the stored fingerprint for the connected device.
  ///
  /// The next download will behave as though no dives have been
  /// previously downloaded, fetching the full dive history.
  Future<void> resetFingerprint() async {
    try {
      await _channel.invokeMethod('resetFingerprint');
    } on PlatformException catch (e) {
      throw DiveComputerException.fromPlatformException(e);
    }
  }
}
