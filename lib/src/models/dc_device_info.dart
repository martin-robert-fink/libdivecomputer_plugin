/// Information about a dive computer discovered during BLE scanning.
///
/// Instances are created from scan events received via the platform
/// event channel. The [address] is the BLE peripheral UUID and is
/// used as the stable device identifier for connection.
class DcDeviceInfo {
  /// The BLE advertised device name (may differ from [product]).
  final String name;

  /// The BLE peripheral address / UUID — used to identify the device
  /// when calling [DiveComputerPlugin.connectToDevice].
  final String address;

  /// Received signal strength indicator in dBm.
  final int rssi;

  /// The dive computer vendor name (e.g. `"Shearwater"`), matched
  /// from the libdivecomputer descriptor table.
  final String vendor;

  /// The dive computer product name (e.g. `"Petrel 3"`), matched
  /// from the libdivecomputer descriptor table.
  final String product;

  /// The libdivecomputer device family identifier.
  final int family;

  /// The libdivecomputer device model identifier.
  final int model;

  const DcDeviceInfo({
    required this.name,
    required this.address,
    required this.rssi,
    this.vendor = '',
    this.product = '',
    this.family = 0,
    this.model = 0,
  });

  /// Deserialises from the map sent over the platform event channel.
  factory DcDeviceInfo.fromMap(Map<String, dynamic> map) {
    return DcDeviceInfo(
      name: map['name'] as String? ?? 'Unknown',
      address: map['address'] as String? ?? '',
      rssi: map['rssi'] as int? ?? 0,
      vendor: map['vendor'] as String? ?? '',
      product: map['product'] as String? ?? '',
      family: map['family'] as int? ?? 0,
      model: map['model'] as int? ?? 0,
    );
  }

  /// Serialises to a map suitable for platform channel transport.
  Map<String, dynamic> toMap() => {
    'name': name,
    'address': address,
    'rssi': rssi,
    'vendor': vendor,
    'product': product,
    'family': family,
    'model': model,
  };

  /// Whether the device was matched to a known libdivecomputer descriptor.
  bool get isIdentified => vendor.isNotEmpty;

  /// Display-friendly device description.
  String get displayName => isIdentified ? '$vendor $product' : name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DcDeviceInfo && address == other.address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => isIdentified ? '$vendor $product ($name)' : name;
}
