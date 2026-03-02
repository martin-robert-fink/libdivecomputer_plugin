/// A dive computer model descriptor from the libdivecomputer database.
///
/// Returned by [DiveComputerPlugin.getSupportedDescriptors]. Each entry
/// describes one model of dive computer that libdivecomputer can
/// communicate with, along with its supported transport types.
class DcDiveComputer {
  /// Manufacturer name (e.g. `"Shearwater"`).
  final String vendor;

  /// Model name (e.g. `"Petrel 3"`).
  final String product;

  /// The libdivecomputer family identifier.
  final int family;

  /// The libdivecomputer model identifier.
  final int model;

  /// Bitmask of supported transport types.
  ///
  /// Use the convenience getters ([supportsBle], [supportsSerial], etc.)
  /// rather than inspecting this directly.
  final int transports;

  const DcDiveComputer({
    required this.vendor,
    required this.product,
    required this.family,
    required this.model,
    required this.transports,
  });

  /// Deserialises from the map sent over the platform channel.
  factory DcDiveComputer.fromMap(Map<String, dynamic> map) {
    return DcDiveComputer(
      vendor: map['vendor'] as String? ?? '',
      product: map['product'] as String? ?? '',
      family: map['family'] as int? ?? 0,
      model: map['model'] as int? ?? 0,
      transports: map['transports'] as int? ?? 0,
    );
  }

  /// Serialises to a map suitable for platform channel transport.
  Map<String, dynamic> toMap() => {
    'vendor': vendor,
    'product': product,
    'family': family,
    'model': model,
    'transports': transports,
  };

  // Transport bitmask constants from libdivecomputer's dc_transport_t.
  static const int _transportSerial = 0x01;
  static const int _transportUsb = 0x02;
  static const int _transportUsbhid = 0x04;
  static const int _transportIrda = 0x08;
  static const int _transportBluetooth = 0x10;
  static const int _transportBle = 0x20;

  /// Whether this model supports Bluetooth Low Energy communication.
  bool get supportsBle => (transports & _transportBle) != 0;

  /// Whether this model supports classic Bluetooth.
  bool get supportsBluetooth => (transports & _transportBluetooth) != 0;

  /// Whether this model supports serial communication.
  bool get supportsSerial => (transports & _transportSerial) != 0;

  /// Whether this model supports USB communication.
  bool get supportsUsb => (transports & _transportUsb) != 0;

  /// Whether this model supports USB HID communication.
  bool get supportsUsbHid => (transports & _transportUsbhid) != 0;

  /// Whether this model supports IrDA communication.
  bool get supportsIrda => (transports & _transportIrda) != 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DcDiveComputer &&
          vendor == other.vendor &&
          product == other.product &&
          family == other.family &&
          model == other.model;

  @override
  int get hashCode => Object.hash(vendor, product, family, model);

  @override
  String toString() => '$vendor $product';
}
