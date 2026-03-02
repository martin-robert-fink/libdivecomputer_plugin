/// Dive mode reported by the dive computer.
///
/// Maps to libdivecomputer's `dc_divemode_t` values as serialised by
/// the native plugin layer.
enum DcDiveMode {
  /// Open-circuit scuba.
  openCircuit('OC'),

  /// Closed-circuit rebreather.
  closedCircuit('CCR'),

  /// Semi-closed rebreather.
  semiClosed('SCR'),

  /// Gauge / bottom-timer mode.
  gauge('gauge'),

  /// Freediving mode.
  freedive('freedive'),

  /// Unknown or unrecognised dive mode.
  unknown('unknown');

  /// The string identifier used by the native platform channel.
  final String nativeValue;

  const DcDiveMode(this.nativeValue);

  /// Parses the string value sent from the native side.
  ///
  /// Returns [DcDiveMode.unknown] for unrecognised values or `null`.
  static DcDiveMode fromNative(String? value) {
    if (value == null) return DcDiveMode.unknown;
    for (final mode in values) {
      if (mode.nativeValue == value) return mode;
    }
    return DcDiveMode.unknown;
  }

  /// Human-readable label for display.
  String get label => switch (this) {
        DcDiveMode.openCircuit => 'Open Circuit',
        DcDiveMode.closedCircuit => 'CCR',
        DcDiveMode.semiClosed => 'SCR',
        DcDiveMode.gauge => 'Gauge',
        DcDiveMode.freedive => 'Freedive',
        DcDiveMode.unknown => 'Unknown',
      };

  @override
  String toString() => label;
}