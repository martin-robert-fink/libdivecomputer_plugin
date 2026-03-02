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

  /// Parses the status string sent from the native side.
  ///
  /// Returns `null` if [value] is `null` (download still active).
  static DcDownloadStatus? fromNative(String? value) {
    if (value == null) return null;
    return switch (value) {
      'success' => DcDownloadStatus.success,
      'done' => DcDownloadStatus.done,
      'cancelled' => DcDownloadStatus.cancelled,
      _ when value.startsWith('error') => DcDownloadStatus.error,
      _ => DcDownloadStatus.error,
    };
  }

  /// Extracts the integer error code from a native status string like
  /// `"error(-7)"`. Returns `null` for non-error statuses.
  static int? errorCodeFromNative(String? value) {
    if (value == null || !value.startsWith('error(')) return null;
    final start = value.indexOf('(');
    final end = value.indexOf(')');
    if (start < 0 || end < 0 || end <= start + 1) return null;
    return int.tryParse(value.substring(start + 1, end));
  }

  /// Whether this represents a successful completion.
  bool get isSuccess =>
      this == DcDownloadStatus.success || this == DcDownloadStatus.done;

  /// Whether the download ended due to an error.
  bool get isError => this == DcDownloadStatus.error;
}
