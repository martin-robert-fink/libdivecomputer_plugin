import 'package:flutter/services.dart';
import 'models/dc_status.dart';

/// Exception thrown by [DiveComputerPlugin] operations.
///
/// Wraps the underlying [PlatformException] from the method channel and
/// provides structured access to the error [code] string, a typed [status]
/// when the code maps to a known libdivecomputer status, and the
/// human-readable [message].
///
/// ```dart
/// try {
///   await plugin.connectToDevice(...);
/// } on DiveComputerException catch (e) {
///   if (e.status == DcStatus.timeout) {
///     // handle timeout specifically
///   }
///   print(e.message);
/// }
/// ```
class DiveComputerException implements Exception {
  /// The error code string from the platform channel (e.g. `"NO_DEVICE"`,
  /// `"CONNECT_FAILED"`, `"TIMEOUT"`).
  final String code;

  /// Human-readable error description.
  final String message;

  /// Additional error details from the platform side, if any.
  final dynamic details;

  /// The typed libdivecomputer status, if the error code maps to a known
  /// `dc_status_t` value. `null` for plugin-level errors that don't
  /// originate from libdivecomputer (e.g. `"NO_DEVICE"`, `"INVALID_ARGS"`).
  final DcStatus? status;

  const DiveComputerException({
    required this.code,
    required this.message,
    this.details,
    this.status,
  });

  /// Creates a [DiveComputerException] from a [PlatformException].
  ///
  /// Attempts to map the platform error code to a [DcStatus] for structured
  /// error handling. Falls back to `null` status for unrecognised codes.
  factory DiveComputerException.fromPlatformException(PlatformException e) {
    return DiveComputerException(
      code: e.code,
      message: e.message ?? 'Unknown error',
      details: e.details,
      status: _statusFromCode(e.code),
    );
  }

  /// Maps well-known platform error codes to [DcStatus] values.
  static DcStatus? _statusFromCode(String code) {
    return switch (code) {
      'TIMEOUT' => DcStatus.timeout,
      'IO_ERROR' => DcStatus.io,
      'PROTOCOL_ERROR' => DcStatus.protocol,
      'CANCELLED' => DcStatus.cancelled,
      'UNSUPPORTED' => DcStatus.unsupported,
      'NOACCESS' || 'BLE_ERROR' => DcStatus.noaccess,
      'NO_DEVICE' || 'NODEVICE' => DcStatus.nodevice,
      'INVALID_ARGS' => DcStatus.invalidArgs,
      'DATAFORMAT' => DcStatus.dataformat,
      _ => null,
    };
  }

  /// Whether this exception represents a communication timeout.
  bool get isTimeout => status == DcStatus.timeout;

  /// Whether this exception was caused by user cancellation.
  bool get isCancelled => status == DcStatus.cancelled;

  /// Whether this exception indicates the device was not found.
  bool get isDeviceNotFound => status == DcStatus.nodevice;

  @override
  String toString() => 'DiveComputerException($code): $message';
}
