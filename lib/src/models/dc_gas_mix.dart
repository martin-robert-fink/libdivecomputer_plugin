/// A breathing gas mixture reported by the dive computer.
///
/// Fractions are expressed as values between 0.0 and 1.0
/// (e.g. 0.21 for 21% oxygen in air).
class DcGasMix {
  /// Oxygen fraction (0.0–1.0).
  final double oxygen;

  /// Helium fraction (0.0–1.0).
  final double helium;

  /// Nitrogen fraction (0.0–1.0).
  final double nitrogen;

  const DcGasMix({
    required this.oxygen,
    required this.helium,
    required this.nitrogen,
  });

  /// Deserialises from the map sent over the platform channel.
  factory DcGasMix.fromMap(Map<String, dynamic> map) {
    return DcGasMix(
      oxygen: (map['oxygen'] as num?)?.toDouble() ?? 0,
      helium: (map['helium'] as num?)?.toDouble() ?? 0,
      nitrogen: (map['nitrogen'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Serialises to a map suitable for platform channel transport.
  Map<String, dynamic> toMap() => {
    'oxygen': oxygen,
    'helium': helium,
    'nitrogen': nitrogen,
  };

  /// Human-readable gas label.
  ///
  /// Returns `"Air"` for 21/0, `"EAN32"` for nitrox, or `"21/35"` for trimix.
  String get label {
    final o2 = (oxygen * 100).round();
    final he = (helium * 100).round();
    if (he > 0) return '$o2/$he';
    if (o2 == 21) return 'Air';
    return 'EAN$o2';
  }

  /// Whether this is a trimix (contains helium).
  bool get isTrimix => helium > 0;

  /// Whether this is standard air (21% O₂, no helium).
  bool get isAir => (oxygen * 100).round() == 21 && !isTrimix;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DcGasMix &&
          oxygen == other.oxygen &&
          helium == other.helium &&
          nitrogen == other.nitrogen;

  @override
  int get hashCode => Object.hash(oxygen, helium, nitrogen);

  @override
  String toString() => label;
}
