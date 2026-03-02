/// The completion status of a dive download operation.
///
/// Reported by [DcDownloadProgress.downloadStatus] once the download
/// finishes (i.e. when [DcDownloadProgress.isActive] becomes `false`).
enum DcDownloadStatus {
  /// Download completed successfully with all dives retrieved.
  success,

  /// Download finished (equivalent to success in some backends).
  done,

  /// Download was cancelled by the user.
  cancelled,

  /// Download failed with a libdivecomputer error.
  error;

  /// The libdivecomputer error code if [this] is [error], or `null`.
  ///
  /// This is populated from the native status string format `"error(N)"`.
  /// Access it via [DcDownloadProgress.errorCode] for convenience.
  static final _errorPattern = RegExp(r'^error\((-?\d+)\)$');

  /// Parses the status string sent from the native side.
  ///
  /// Returns `null` if [value] is `null` (download still active).
  static DcDownloadStatus? fromNative(String? value) {
    if (value == null) return null;
    return switch (value) {
      'success' => DcDownloadStatus.success,
      'done' => DcDownloadStatus.done,
      'cancelled' => DcDownloadStatus.cancelled,
      _ when _errorPattern.hasMatch(value) => DcDownloadStatus.error,
      _ => DcDownloadStatus.error,
    };
  }

  /// Extracts the integer error code from a native status string like
  /// `"error(-7)"`. Returns `null` for non-error statuses.
  static int? errorCodeFromNative(String? value) {
    if (value == null) return null;
    final match = _errorPattern.firstMatch(value);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// Whether this represents a successful completion.
  bool get isSuccess =>
      this == DcDownloadStatus.success || this == DcDownloadStatus.done;

  /// Whether the download ended due to an error.
  bool get isError => this == DcDownloadStatus.error;
}
