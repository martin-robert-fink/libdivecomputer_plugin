/// Status codes returned by libdivecomputer operations.
///
/// Maps directly to the native `dc_status_t` enum values.
/// Use [fromNative] to convert from the integer code returned by the
/// platform channel, and [message] for a human-readable description.
enum DcStatus {
  /// Operation completed successfully.
  success(0, 'Operation completed successfully'),

  /// Iterator exhausted — no more items.
  done(1, 'No more items'),

  /// Feature not supported by this device or backend.
  unsupported(-1, 'Feature not supported'),

  /// Invalid arguments were passed to the operation.
  invalidArgs(-2, 'Invalid arguments'),

  /// Memory allocation failed on the native side.
  nomemory(-3, 'Out of memory'),

  /// No dive computer device found.
  nodevice(-4, 'No device found'),

  /// Permission denied or device not accessible.
  noaccess(-5, 'Access denied'),

  /// I/O error during communication.
  io(-6, 'I/O error'),

  /// Communication timed out.
  timeout(-7, 'Communication timed out'),

  /// Protocol-level error in device communication.
  protocol(-8, 'Protocol error'),

  /// Received data could not be parsed.
  dataformat(-9, 'Data format error'),

  /// Operation was cancelled by the user.
  cancelled(-10, 'Operation cancelled');

  /// The native `dc_status_t` integer value.
  final int code;

  /// A human-readable description of this status.
  final String message;

  const DcStatus(this.code, this.message);

  /// Converts a native `dc_status_t` integer to the corresponding [DcStatus].
  ///
  /// Returns [DcStatus.unsupported] for unrecognised codes.
  static DcStatus fromNative(int code) {
    return switch (code) {
      0 => DcStatus.success,
      1 => DcStatus.done,
      -1 => DcStatus.unsupported,
      -2 => DcStatus.invalidArgs,
      -3 => DcStatus.nomemory,
      -4 => DcStatus.nodevice,
      -5 => DcStatus.noaccess,
      -6 => DcStatus.io,
      -7 => DcStatus.timeout,
      -8 => DcStatus.protocol,
      -9 => DcStatus.dataformat,
      -10 => DcStatus.cancelled,
      _ => DcStatus.unsupported,
    };
  }

  /// Whether this status represents an error condition.
  bool get isError => code < 0;

  /// Whether this status represents success (including [done]).
  bool get isSuccess => code >= 0;
}
