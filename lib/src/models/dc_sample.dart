/// A single sample point from a dive computer's depth profile.
///
/// Each sample represents one data point recorded during the dive.
/// Not all fields will be present in every sample — the dive computer
/// only records fields that changed or are relevant to that sample type.
///
/// The [time] field is the elapsed time in seconds from the start of the
/// dive and is present on virtually every sample.
class DcSample {
  /// Elapsed time in seconds since dive start.
  final int? time;

  /// Current depth in metres.
  final double? depth;

  /// Water temperature in °C at this sample point.
  final double? temperature;

  /// Tank pressure in bar.
  final double? pressure;

  /// Tank index for [pressure] readings (0-based).
  final int? tank;

  /// CCR/SCR setpoint in bar.
  final double? setpoint;

  /// Partial pressure of oxygen in bar.
  final double? ppo2;

  /// Central nervous system oxygen toxicity (0.0–1.0 fraction).
  final double? cns;

  /// Decompression obligation type (libdivecomputer enum value).
  final int? decoType;

  /// Decompression stop depth in metres.
  final double? decoDepth;

  /// Decompression stop time in seconds.
  final int? decoTime;

  /// Time-to-surface in seconds.
  final int? tts;

  /// Heart rate in beats per minute.
  final int? heartbeat;

  /// Active gas mix index (0-based into the dive's gas mix list).
  final int? gasmix;

  const DcSample({
    this.time,
    this.depth,
    this.temperature,
    this.pressure,
    this.tank,
    this.setpoint,
    this.ppo2,
    this.cns,
    this.decoType,
    this.decoDepth,
    this.decoTime,
    this.tts,
    this.heartbeat,
    this.gasmix,
  });

  /// Deserialises from the map sent over the platform channel.
  factory DcSample.fromMap(Map<String, dynamic> map) {
    return DcSample(
      time: map['time'] as int?,
      depth: (map['depth'] as num?)?.toDouble(),
      temperature: (map['temperature'] as num?)?.toDouble(),
      pressure: (map['pressure'] as num?)?.toDouble(),
      tank: map['tank'] as int?,
      setpoint: (map['setpoint'] as num?)?.toDouble(),
      ppo2: (map['ppo2'] as num?)?.toDouble(),
      cns: (map['cns'] as num?)?.toDouble(),
      decoType: map['decoType'] as int?,
      decoDepth: (map['decoDepth'] as num?)?.toDouble(),
      decoTime: map['decoTime'] as int?,
      tts: map['tts'] as int?,
      heartbeat: map['heartbeat'] as int?,
      gasmix: map['gasmix'] as int?,
    );
  }

  /// Serialises to a map suitable for platform channel transport.
  Map<String, dynamic> toMap() => {
    if (time != null) 'time': time,
    if (depth != null) 'depth': depth,
    if (temperature != null) 'temperature': temperature,
    if (pressure != null) 'pressure': pressure,
    if (tank != null) 'tank': tank,
    if (setpoint != null) 'setpoint': setpoint,
    if (ppo2 != null) 'ppo2': ppo2,
    if (cns != null) 'cns': cns,
    if (decoType != null) 'decoType': decoType,
    if (decoDepth != null) 'decoDepth': decoDepth,
    if (decoTime != null) 'decoTime': decoTime,
    if (tts != null) 'tts': tts,
    if (heartbeat != null) 'heartbeat': heartbeat,
    if (gasmix != null) 'gasmix': gasmix,
  };

  /// Whether this sample includes a depth reading.
  bool get hasDepth => depth != null;

  /// Whether this sample includes decompression data.
  bool get hasDeco => decoType != null;

  /// Whether this sample includes pressure data.
  bool get hasPressure => pressure != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DcSample &&
          time == other.time &&
          depth == other.depth &&
          temperature == other.temperature &&
          pressure == other.pressure &&
          tank == other.tank &&
          setpoint == other.setpoint &&
          ppo2 == other.ppo2 &&
          cns == other.cns &&
          decoType == other.decoType &&
          decoDepth == other.decoDepth &&
          decoTime == other.decoTime &&
          tts == other.tts &&
          heartbeat == other.heartbeat &&
          gasmix == other.gasmix;

  @override
  int get hashCode => Object.hash(
    time,
    depth,
    temperature,
    pressure,
    tank,
    setpoint,
    ppo2,
    cns,
    decoType,
    decoDepth,
    decoTime,
    tts,
    heartbeat,
    gasmix,
  );

  @override
  String toString() {
    final parts = <String>[];
    if (time != null) parts.add('${time}s');
    if (depth != null) parts.add('${depth!.toStringAsFixed(1)}m');
    if (temperature != null) parts.add('${temperature!.toStringAsFixed(1)}°C');
    if (pressure != null) parts.add('${pressure!.round()}bar');
    return 'DcSample(${parts.join(', ')})';
  }
}
