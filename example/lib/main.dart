import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dive_computer/dive_computer.dart';

void main() {
  runApp(const DiveComputerExampleApp());
}

class DiveComputerExampleApp extends StatelessWidget {
  const DiveComputerExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dive Computer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _plugin = DiveComputerPlugin.instance;

  String _libraryVersion = 'Loading...';
  String _statusMessage = '';

  // BLE scan state
  bool _isScanning = false;
  final List<DcDeviceInfo> _discoveredDevices = [];
  StreamSubscription<DcDeviceInfo>? _scanSubscription;

  // Connection state
  bool _isConnecting = false;
  bool _isConnected = false;
  DcDeviceInfo? _connectedDevice;

  // Download state
  bool _isDownloading = false;
  bool _forceDownload = false;
  double _downloadProgress = 0;
  int _downloadedDiveCount = 0;
  final List<DcDive> _dives = [];
  Timer? _progressTimer;
  int? _devInfoSerial;
  int? _devInfoFirmware;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _stopScan();
    _progressTimer?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final version = await _plugin.getLibraryVersion();
      setState(() => _libraryVersion = version);
    } on DiveComputerException catch (e) {
      setState(() => _statusMessage = 'Error: ${e.message}');
    }
  }

  // MARK: - Scanning

  void _startScan() {
    setState(() {
      _isScanning = true;
      _discoveredDevices.clear();
    });

    _scanSubscription = _plugin.scanForDevices().listen(
      (device) {
        setState(() {
          final idx = _discoveredDevices.indexWhere(
            (d) => d.address == device.address,
          );
          if (idx >= 0) {
            _discoveredDevices[idx] = device;
          } else {
            _discoveredDevices.add(device);
          }
        });
      },
      onError: (error) {
        setState(() {
          _isScanning = false;
          _statusMessage = error is DiveComputerException
              ? 'Scan error: ${error.message}'
              : 'Scan error: $error';
        });
      },
      onDone: () => setState(() => _isScanning = false),
    );
  }

  Future<void> _stopScan() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await _plugin.stopScan();
    } catch (_) {}
    if (mounted) setState(() => _isScanning = false);
  }

  // MARK: - Connection

  Future<void> _connectToDevice(DcDeviceInfo device) async {
    await _stopScan();

    setState(() {
      _isConnecting = true;
      _statusMessage = 'Connecting to ${device.displayName}...';
    });

    try {
      final success = await _plugin.connectToDevice(device);

      setState(() {
        _isConnecting = false;
        if (success) {
          _isConnected = true;
          _connectedDevice = device;
          _statusMessage = 'Connected to ${device.displayName}!';
        } else {
          _statusMessage = 'Connection failed';
        }
      });
    } on DiveComputerException catch (e) {
      setState(() {
        _isConnecting = false;
        _statusMessage = e.isTimeout
            ? 'Connection timed out'
            : 'Connection error: ${e.message}';
      });
    }
  }

  Future<void> _disconnect() async {
    _progressTimer?.cancel();
    _progressTimer = null;
    setState(() => _statusMessage = 'Disconnecting...');

    try {
      await _plugin.disconnect();
    } catch (_) {}

    setState(() {
      _isConnected = false;
      _isDownloading = false;
      _connectedDevice = null;
      _dives.clear();
      _downloadProgress = 0;
      _downloadedDiveCount = 0;
      _devInfoSerial = null;
      _devInfoFirmware = null;
      _statusMessage = 'Disconnected';
    });
  }

  // MARK: - Download (polling model)

  bool _cancelRequested = false;

  void _cancelDownload() {
    _plugin.cancelDownload();
    _cancelRequested = true;
    setState(() {
      _statusMessage = 'Cancelling download...';
    });
  }

  Future<void> _resetFingerprint() async {
    try {
      await _plugin.resetFingerprint();
      setState(() {
        _statusMessage =
            'Fingerprint reset — next download will fetch all dives';
      });
    } on DiveComputerException catch (e) {
      setState(() => _statusMessage = 'Reset error: ${e.message}');
    }
  }

  void _startDownload() {
    _cancelRequested = false;
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _downloadedDiveCount = 0;
      _dives.clear();
      _devInfoSerial = null;
      _devInfoFirmware = null;
      _statusMessage = 'Downloading dives...';
    });

    _plugin.startDownload(forceDownload: _forceDownload);

    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _pollProgress(),
    );
  }

  Future<void> _pollProgress() async {
    try {
      final progress = await _plugin.getDownloadProgress();

      if (!mounted) return;

      setState(() {
        if (progress.progressFraction > _downloadProgress) {
          _downloadProgress = progress.progressFraction;
        }
        _downloadedDiveCount = progress.diveCount;
        if (progress.serial != null) _devInfoSerial = progress.serial;
        if (progress.firmware != null) _devInfoFirmware = progress.firmware;

        if (progress.isActive) {
          final pct = progress.progressPercent;
          _statusMessage = progress.diveCount > 0
              ? 'Downloading... $pct% — ${progress.diveCount} dives'
              : 'Downloading... $pct%';
        }
      });

      if (progress.isComplete) {
        _progressTimer?.cancel();
        _progressTimer = null;
        await _retrieveDownloadedDives(progress);
      }
    } catch (e) {
      debugPrint('Progress poll error: $e');
    }
  }

  Future<void> _retrieveDownloadedDives(DcDownloadProgress progress) async {
    final wasCancelled = _cancelRequested;
    _cancelRequested = false;

    setState(() {
      _statusMessage = wasCancelled
          ? 'Cancelled — loading downloaded dives...'
          : progress.isError
          ? 'Download error — loading partial dives...'
          : 'Download complete — loading dive data...';
    });

    try {
      final dives = await _plugin.getDownloadedDives();

      if (!mounted) return;

      setState(() {
        _dives.clear();
        _dives.addAll(dives);
        _isDownloading = false;
        _downloadProgress = 1.0;
        _statusMessage = wasCancelled
            ? 'Cancelled: ${dives.length} dives retrieved'
            : 'Download complete: ${dives.length} dives';
      });
    } on DiveComputerException catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _statusMessage = 'Error loading dives: ${e.message}';
      });
    }
  }

  // MARK: - Build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dive Computer')),
      body: SafeArea(
        child: _isConnected ? _buildConnectedView() : _buildScanView(),
      ),
    );
  }

  // MARK: - Scan View

  Widget _buildScanView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLibraryStatusCard(),
              if (_statusMessage.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildStatusCard(),
              ],
              const SizedBox(height: 16),
              _buildScanHeader(),
              const SizedBox(height: 8),
            ],
          ),
        ),
        Expanded(
          child: _discoveredDevices.isEmpty
              ? Center(
                  child: Text(
                    _isScanning
                        ? 'Scanning for dive computers...'
                        : 'Tap Scan to search for dive computers',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _discoveredDevices.length,
                  itemBuilder: (context, index) =>
                      _buildDeviceCard(_discoveredDevices[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildScanHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('Devices', style: Theme.of(context).textTheme.titleMedium),
        if (_isScanning)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        FilledButton.icon(
          onPressed: _isConnecting
              ? null
              : (_isScanning ? _stopScan : _startScan),
          icon: Icon(_isScanning ? Icons.stop : Icons.bluetooth_searching),
          label: Text(_isScanning ? 'Stop' : 'Scan'),
        ),
      ],
    );
  }

  Widget _buildDeviceCard(DcDeviceInfo device) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth_connected, color: Colors.blue),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        device.displayName,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        'RSSI: ${device.rssi} dBm',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _isConnecting
                    ? null
                    : () => _connectToDevice(device),
                child: _isConnecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Connect'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // MARK: - Connected View

  Widget _buildConnectedView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildConnectedDeviceCard(),
              const SizedBox(height: 8),
              if (_statusMessage.isNotEmpty) ...[
                _buildStatusCard(),
                const SizedBox(height: 8),
              ],
              _buildDownloadControls(),
              if (_isDownloading || _downloadProgress > 0) ...[
                const SizedBox(height: 8),
                _buildProgressBar(),
              ],
              const SizedBox(height: 8),
              _buildDownloadOptions(),
              if (_dives.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Dives (${_dives.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
              const SizedBox(height: 4),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _dives.length,
            itemBuilder: (context, index) => _buildDiveCard(_dives[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildConnectedDeviceCard() {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.bluetooth_connected,
                  color: Colors.green,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _connectedDevice!.displayName,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        _connectedDevice!.address,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (_devInfoSerial != null)
                        Text(
                          'S/N: $_devInfoSerial  FW: $_devInfoFirmware',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: _isDownloading ? null : _disconnect,
                child: const Text('Disconnect'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadControls() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: _isDownloading ? null : _startDownload,
          icon: Icon(_isDownloading ? Icons.hourglass_top : Icons.download),
          label: Text(
            _isDownloading
                ? (_cancelRequested ? 'Cancelling...' : 'Downloading...')
                : _dives.isEmpty
                ? 'Download Dives'
                : 'Re-download',
          ),
        ),
        if (_isDownloading)
          OutlinedButton.icon(
            onPressed: _cancelRequested ? null : _cancelDownload,
            icon: const Icon(Icons.cancel),
            label: Text(_cancelRequested ? 'Cancelling...' : 'Cancel'),
          ),
      ],
    );
  }

  Widget _buildProgressBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: _isDownloading ? _downloadProgress : 1.0,
        ),
        const SizedBox(height: 4),
        Text(
          _isDownloading
              ? '${(_downloadProgress * 100).toInt()}%  •  '
                    '$_downloadedDiveCount dives'
              : '${_dives.length} dives downloaded',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildDownloadOptions() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          height: 32,
          child: FilterChip(
            label: const Text('Force full download'),
            selected: _forceDownload,
            onSelected: _isDownloading
                ? null
                : (value) => setState(() => _forceDownload = value),
          ),
        ),
        TextButton.icon(
          onPressed: _isDownloading ? null : _resetFingerprint,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Reset Fingerprint'),
        ),
      ],
    );
  }

  // MARK: - Shared Cards

  Widget _buildLibraryStatusCard() {
    final isOk = _libraryVersion.contains('libdivecomputer');
    return Card(
      child: ListTile(
        leading: Icon(
          isOk ? Icons.check_circle : Icons.error,
          color: isOk ? Colors.green : Colors.red,
        ),
        title: const Text('Library Status'),
        subtitle: Text(_libraryVersion),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      color: _isConnected ? Colors.green.shade50 : null,
      child: ListTile(
        leading: Icon(
          _isConnected
              ? Icons.bluetooth_connected
              : _isConnecting
              ? Icons.bluetooth_searching
              : Icons.info_outline,
          color: _isConnected ? Colors.green : null,
        ),
        title: Text(_isConnected ? 'Connected' : 'Status'),
        subtitle: Text(_statusMessage),
        trailing: _isConnecting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
    );
  }

  // MARK: - Dive Card

  Widget _buildDiveCard(DcDive dive) {
    final dateStr = dive.dateTime != null
        ? '${dive.dateTime!.year}-'
              '${dive.dateTime!.month.toString().padLeft(2, '0')}-'
              '${dive.dateTime!.day.toString().padLeft(2, '0')}  '
              '${dive.dateTime!.hour.toString().padLeft(2, '0')}:'
              '${dive.dateTime!.minute.toString().padLeft(2, '0')}'
        : 'Unknown date';

    final details = <String>[
      dive.depthStr,
      dive.timeStr,
      if (dive.tempStr.isNotEmpty) dive.tempStr,
      if (dive.diveMode != null) dive.diveMode!.label,
      if (dive.gasStr.isNotEmpty) dive.gasStr,
    ];

    return Card(
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: Colors.blue.shade100,
          child: Text(
            '${dive.number}',
            style: TextStyle(
              color: Colors.blue.shade800,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(dateStr),
        subtitle: Text(details.join('  •  ')),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailRow('Max Depth', dive.depthStr),
                if (dive.avgDepth != null)
                  _detailRow(
                    'Avg Depth',
                    '${dive.avgDepth!.toStringAsFixed(1)}m',
                  ),
                _detailRow('Duration', dive.timeStr),
                if (dive.diveMode != null)
                  _detailRow('Mode', dive.diveMode!.label),
                if (dive.minTemperature != null)
                  _detailRow(
                    'Min Temp',
                    '${dive.minTemperature!.toStringAsFixed(1)}°C',
                  ),
                if (dive.maxTemperature != null)
                  _detailRow(
                    'Max Temp',
                    '${dive.maxTemperature!.toStringAsFixed(1)}°C',
                  ),
                if (dive.gasMixes != null && dive.gasMixes!.isNotEmpty)
                  _detailRow('Gas', dive.gasStr),
                if (dive.tanks != null && dive.tanks!.isNotEmpty)
                  ...dive.tanks!.asMap().entries.map(
                    (e) => _detailRow('Tank ${e.key + 1}', e.value.toString()),
                  ),
                _detailRow('Samples', '${dive.totalSampleCount} points'),
                if (dive.fingerprint != null)
                  _detailRow(
                    'Fingerprint',
                    '${dive.fingerprint!.substring(0, dive.fingerprint!.length > 16 ? 16 : dive.fingerprint!.length)}...',
                  ),
                if (dive.hasError)
                  _detailRow('Error', dive.error!, isError: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, {bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: isError ? Colors.red : null),
            ),
          ),
        ],
      ),
    );
  }
}
