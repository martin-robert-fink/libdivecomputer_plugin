/// Tank (cylinder) information reported by the dive computer.
///
/// Pressures are in bar. Volume is in litres. The [gasmix] index
/// references the corresponding entry in [DcDive.gasMixes].
class DcTank {
  /// Tank pressure at the start of the dive (bar).
  final double beginPressure;

  /// Tank pressure at the end of the dive (bar).
  final double endPressure;

  /// Tank volume in litres, if reported.
  final double? volume;

  /// Tank rated working pressure in bar, if reported.
  final double? workPressure;

  /// Index into the dive's gas mix list, if reported.
  final int? gasmix;

  const DcTank({
    required this.beginPressure,
    required this.endPressure,
    this.volume,
    this.workPressure,
    this.gasmix,
  });

  /// Deserialises from the map sent over the platform channel.
  factory DcTank.fromMap(Map<String, dynamic> map) {
    return DcTank(
      beginPressure: (map['beginPressure'] as num?)?.toDouble() ?? 0,
      endPressure: (map['endPressure'] as num?)?.toDouble() ?? 0,
      volume: (map['volume'] as num?)?.toDouble(),
      workPressure: (map['workPressure'] as num?)?.toDouble(),
      gasmix: map['gasmix'] as int?,
    );
  }

  /// Serialises to a map suitable for platform channel transport.
  Map<String, dynamic> toMap() => {
    'beginPressure': beginPressure,
    'endPressure': endPressure,
    if (volume != null) 'volume': volume,
    if (workPressure != null) 'workPressure': workPressure,
    if (gasmix != null) 'gasmix': gasmix,
  };

  /// Gas consumed in bar.
  double get consumed => beginPressure - endPressure;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DcTank &&
          beginPressure == other.beginPressure &&
          endPressure == other.endPressure &&
          volume == other.volume &&
          workPressure == other.workPressure &&
          gasmix == other.gasmix;

  @override
  int get hashCode =>
      Object.hash(beginPressure, endPressure, volume, workPressure, gasmix);

  @override
  String toString() => '${beginPressure.round()}→${endPressure.round()} bar';
}
