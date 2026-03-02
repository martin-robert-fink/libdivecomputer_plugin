import 'dc_download_status.dart';
import 'dc_status.dart';

/// Snapshot of a dive download operation's progress.
///
/// Returned by [DiveComputerPlugin.getDownloadProgress]. Poll this on a
/// timer (e.g. every 250 ms) after calling [DiveComputerPlugin.startDownload]
/// to track the download state.
///
/// ```dart
/// final progress = await plugin.getDownloadProgress();
/// if (!progress.isActive && progress.downloadStatus != null) {
///   // Download finished — retrieve dives
///   final dives = await plugin.getDownloadedDives();
/// }
/// ```
class DcDownloadProgress {
  /// Whether the download is still actively running.
  ///
  /// Once this becomes `false`, check [downloadStatus] and then call
  /// [DiveComputerPlugin.getDownloadedDives] to retrieve the data.
  final bool isActive;

  /// Progress fraction from 0.0 (just started) to 1.0 (complete).
  ///
  /// Note: libdivecomputer may reset progress between phases (manifest
  /// vs. dive data), so callers should use `max(current, previous)` to
  /// prevent the UI from jumping backwards.
  final double progressFraction;

  /// Number of dives downloaded so far.
  final int diveCount;

  /// Estimated total dives on the device, if known.
  final int? estimatedTotalDives;

  /// Device serial number, populated once the device info event fires.
  final int? serial;

  /// Device firmware version, populated once the device info event fires.
  final int? firmware;

  /// The completion status, or `null` while the download is still active.
  final DcDownloadStatus? downloadStatus;

  /// The raw status string from the native side (e.g. `"success"`,
  /// `"error(-7)"`). Useful for logging.
  final String? rawStatus;

  /// If [downloadStatus] is [DcDownloadStatus.error], the libdivecomputer
  /// error code. `null` otherwise.
  final int? errorCode;

  const DcDownloadProgress({
    required this.isActive,
    required this.progressFraction,
    required this.diveCount,
    this.estimatedTotalDives,
    this.serial,
    this.firmware,
    this.downloadStatus,
    this.rawStatus,
    this.errorCode,
  });

  /// Deserialises from the map returned by the `getDownloadProgress`
  /// method channel call.
  factory DcDownloadProgress.fromMap(Map<String, dynamic> map) {
    final rawStatus = map['status'] as String?;
    final errorCode = DcDownloadStatus.errorCodeFromNative(rawStatus);
    return DcDownloadProgress(
      isActive: map['isActive'] as bool? ?? false,
      progressFraction: (map['progressFraction'] as num?)?.toDouble() ?? 0.0,
      diveCount: map['diveCount'] as int? ?? 0,
      estimatedTotalDives: map['estimatedTotalDives'] as int?,
      serial: map['serial'] as int?,
      firmware: map['firmware'] as int?,
      downloadStatus: DcDownloadStatus.fromNative(rawStatus),
      rawStatus: rawStatus,
      errorCode: errorCode,
    );
  }

  /// A default "idle" progress snapshot for when no download is running.
  static const idle = DcDownloadProgress(
    isActive: false,
    progressFraction: 0.0,
    diveCount: 0,
  );

  /// Whether the download completed successfully.
  bool get isSuccess => downloadStatus?.isSuccess ?? false;

  /// Whether the download finished with an error.
  bool get isError => downloadStatus?.isError ?? false;

  /// Whether the download is complete (regardless of success or failure).
  bool get isComplete => !isActive && downloadStatus != null;

  /// The typed [DcStatus] for error downloads, derived from [errorCode].
  DcStatus? get dcStatus =>
      errorCode != null ? DcStatus.fromNative(errorCode!) : null;

  /// Progress as a percentage integer (0–100).
  int get progressPercent => (progressFraction * 100).round();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DcDownloadProgress &&
          isActive == other.isActive &&
          progressFraction == other.progressFraction &&
          diveCount == other.diveCount &&
          estimatedTotalDives == other.estimatedTotalDives &&
          serial == other.serial &&
          firmware == other.firmware &&
          downloadStatus == other.downloadStatus;

  @override
  int get hashCode => Object.hash(
    isActive,
    progressFraction,
    diveCount,
    estimatedTotalDives,
    serial,
    firmware,
    downloadStatus,
  );

  @override
  String toString() {
    if (isActive) {
      return 'DcDownloadProgress('
          '$progressPercent%, '
          '$diveCount dives'
          '${estimatedTotalDives != null ? '/$estimatedTotalDives' : ''}'
          ')';
    }
    return 'DcDownloadProgress(complete: $downloadStatus, $diveCount dives)';
  }
}
