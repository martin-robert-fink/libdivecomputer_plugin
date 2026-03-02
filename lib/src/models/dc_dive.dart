import 'dc_dive_mode.dart';
import 'dc_gas_mix.dart';
import 'dc_sample.dart';
import 'dc_tank.dart';

/// A single dive record downloaded from a dive computer.
///
/// Contains header information (depth, time, temperature, gas mixes)
/// and the full depth-profile [samples] recorded during the dive.
class DcDive {
  /// Sequential dive number as reported by libdivecomputer during download.
  final int number;

  /// Date and time the dive started, if available.
  final DateTime? dateTime;

  /// Maximum depth reached during the dive, in metres.
  final double? maxDepth;

  /// Average depth during the dive, in metres.
  final double? avgDepth;

  /// Total dive duration.
  final Duration? diveTime;

  /// Minimum water temperature recorded, in °C.
  final double? minTemperature;

  /// Maximum water temperature recorded, in °C.
  final double? maxTemperature;

  /// Surface temperature at the start of the dive, in °C.
  final double? surfaceTemperature;

  /// The dive mode used for this dive.
  final DcDiveMode? diveMode;

  /// Atmospheric pressure at the surface, in bar.
  final double? atmospheric;

  /// Breathing gas mixes configured for this dive.
  final List<DcGasMix>? gasMixes;

  /// Tank (cylinder) information for this dive.
  final List<DcTank>? tanks;

  /// The full depth-profile sample data.
  final List<DcSample>? samples;

  /// Total number of sample points. Provided separately because the
  /// native side may report a count even when full sample data is
  /// elided for performance.
  final int? sampleCount;

  /// The dive fingerprint — a unique identifier used by libdivecomputer
  /// to detect which dives have already been downloaded.
  final String? fingerprint;

  /// An error message if parsing this dive's data failed on the native
  /// side. When present, other fields may be incomplete.
  final String? error;

  const DcDive({
    required this.number,
    this.dateTime,
    this.maxDepth,
    this.avgDepth,
    this.diveTime,
    this.minTemperature,
    this.maxTemperature,
    this.surfaceTemperature,
    this.diveMode,
    this.atmospheric,
    this.gasMixes,
    this.tanks,
    this.samples,
    this.sampleCount,
    this.fingerprint,
    this.error,
  });

  /// Deserialises from the map sent over the platform channel.
  factory DcDive.fromMap(Map<String, dynamic> map) {
    return DcDive(
      number: map['number'] as int? ?? 0,
      dateTime: map['dateTime'] != null
          ? DateTime.tryParse(map['dateTime'] as String)
          : null,
      maxDepth: (map['maxDepth'] as num?)?.toDouble(),
      avgDepth: (map['avgDepth'] as num?)?.toDouble(),
      diveTime: map['diveTime'] != null
          ? Duration(seconds: map['diveTime'] as int)
          : null,
      minTemperature: (map['minTemperature'] as num?)?.toDouble(),
      maxTemperature: (map['maxTemperature'] as num?)?.toDouble(),
      surfaceTemperature: (map['surfaceTemperature'] as num?)?.toDouble(),
      diveMode: map['diveMode'] != null
          ? DcDiveMode.fromNative(map['diveMode'] as String?)
          : null,
      atmospheric: (map['atmospheric'] as num?)?.toDouble(),
      gasMixes: (map['gasMixes'] as List?)
          ?.map((m) => DcGasMix.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList(),
      tanks: (map['tanks'] as List?)
          ?.map((m) => DcTank.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList(),
      samples: (map['samples'] as List?)
          ?.map((m) => DcSample.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList(),
      sampleCount:
          map['sampleCount'] as int? ?? (map['samples'] as List?)?.length,
      fingerprint: map['fingerprint'] as String?,
      error: map['error'] as String?,
    );
  }

  /// Serialises to a map suitable for platform channel transport or
  /// JSON serialisation.
  Map<String, dynamic> toMap() => {
    'number': number,
    if (dateTime != null) 'dateTime': dateTime!.toIso8601String(),
    if (maxDepth != null) 'maxDepth': maxDepth,
    if (avgDepth != null) 'avgDepth': avgDepth,
    if (diveTime != null) 'diveTime': diveTime!.inSeconds,
    if (minTemperature != null) 'minTemperature': minTemperature,
    if (maxTemperature != null) 'maxTemperature': maxTemperature,
    if (surfaceTemperature != null) 'surfaceTemperature': surfaceTemperature,
    if (diveMode != null) 'diveMode': diveMode!.nativeValue,
    if (atmospheric != null) 'atmospheric': atmospheric,
    if (gasMixes != null) 'gasMixes': gasMixes!.map((g) => g.toMap()).toList(),
    if (tanks != null) 'tanks': tanks!.map((t) => t.toMap()).toList(),
    if (samples != null) 'samples': samples!.map((s) => s.toMap()).toList(),
    if (sampleCount != null) 'sampleCount': sampleCount,
    if (fingerprint != null) 'fingerprint': fingerprint,
    if (error != null) 'error': error,
  };

  /// The total number of sample points — prefers the explicit [sampleCount]
  /// field, falls back to the length of [samples].
  int get totalSampleCount => sampleCount ?? samples?.length ?? 0;

  /// Whether this dive record has a parse error.
  bool get hasError => error != null;

  // ---------------------------------------------------------------------------
  // Display helpers
  // ---------------------------------------------------------------------------

  /// Formatted max depth string (e.g. `"32.5m"`).
  String get depthStr =>
      maxDepth != null ? '${maxDepth!.toStringAsFixed(1)}m' : '?m';

  /// Formatted dive time string (e.g. `"45min"` or `"3m 20s"`).
  String get timeStr {
    if (diveTime == null) return '?';
    final mins = diveTime!.inMinutes;
    final secs = diveTime!.inSeconds % 60;
    return secs > 0 ? '${mins}m ${secs}s' : '${mins}min';
  }

  /// Formatted minimum temperature string (e.g. `"18.2°C"`), or empty.
  String get tempStr =>
      minTemperature != null ? '${minTemperature!.toStringAsFixed(1)}°C' : '';

  /// Formatted gas mix summary (e.g. `"Air"`, `"EAN32"`, `"21/35, EAN50"`).
  String get gasStr => gasMixes != null && gasMixes!.isNotEmpty
      ? gasMixes!.map((g) => g.label).join(', ')
      : '';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DcDive &&
          number == other.number &&
          fingerprint == other.fingerprint;

  @override
  int get hashCode => Object.hash(number, fingerprint);

  @override
  String toString() => 'DcDive(#$number: $depthStr, $timeStr, $dateTime)';
}
