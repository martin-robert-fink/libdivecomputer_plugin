/// Flutter plugin for communicating with dive computers via libdivecomputer.
///
/// ## Quick start
///
/// ```dart
/// import 'package:libdivecomputer_plugin/libdivecomputer_plugin.dart';
///
/// final plugin = DiveComputerPlugin.instance;
///
/// // Scan for devices
/// plugin.scanForDevices().listen((device) {
///   print('Found: ${device.displayName}');
/// });
///
/// // Connect, download, retrieve
/// await plugin.connectToDevice(device);
/// await plugin.startDownload();
/// // ... poll getDownloadProgress() ...
/// final dives = await plugin.getDownloadedDives();
/// ```
library;

export 'src/libdivecomputer_exception.dart';
export 'src/libdivecomputer_plugin.dart';
export 'src/models/dc_device_info.dart';
export 'src/models/dc_dive.dart';
export 'src/models/dc_dive_computer.dart';
export 'src/models/dc_dive_mode.dart';
export 'src/models/dc_download_progress.dart';
export 'src/models/dc_download_status.dart';
export 'src/models/dc_gas_mix.dart';
export 'src/models/dc_sample.dart';
export 'src/models/dc_status.dart';
export 'src/models/dc_tank.dart';
