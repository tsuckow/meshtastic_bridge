import 'dart:async';
import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_service.dart' as meshtastic_ble;

/// Manages a single Meshtastic BLE device connection, persistence, and logs.
/// Exposes a prefixed log stream suitable for display in a shared log pane.
class ManagedMeshtasticDevice {
  ManagedMeshtasticDevice({
    required this.prefsKey,
    required this.label,
  });

  final String prefsKey; // e.g., 'selectedDeviceId1'
  final String label; // e.g., 'Device 1'

  String? selectedDeviceId;
  meshtastic_ble.BleService? _ble;
  StreamSubscription<String>? _bleLogSub;
  StreamSubscription<bool>? _connSub;
  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  final StreamController<bool> _connectedController =
      StreamController<bool>.broadcast();
  bool _isConnected = false;

  Stream<String> get logs => _logController.stream;
  Stream<bool> get connected => _connectedController.stream;
  bool get isConnected => _isConnected;

  /// Ensure minimum permissions needed to connect on Android. No-ops elsewhere.
  Future<bool> ensurePermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetooth,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      final connectGranted =
          statuses[Permission.bluetoothConnect]?.isGranted ?? false;
      final bluetoothGranted =
          statuses[Permission.bluetooth]?.isGranted ?? false;
      final locationGranted =
          statuses[Permission.locationWhenInUse]?.isGranted ?? false;
      return connectGranted || bluetoothGranted || locationGranted;
    }
    return true;
  }

  Future<void> connectTo(String deviceId) async {
    await saveSelectedDevice(deviceId);
    selectedDeviceId = deviceId;
    _disposeBleOnly();
    _ble = meshtastic_ble.BleService(deviceId);

    // Forward logs with label prefix
    _bleLogSub = _ble!.logs.listen((line) {
      _logController.add('[$label] $line');
    });

    // Forward connection state
    _connSub = _ble!.connection.listen((c) {
      _isConnected = c;
      _connectedController.add(c);
      _logController.add('[$label] ${c ? 'Connected' : 'Disconnected'}');
    });

    try {
      await _ble!.connect();
    } catch (e) {
      _logController.add('[$label] Connect error: $e');
      rethrow;
    }
  }

  Future<void> disconnect({bool clearSaved = true}) async {
    if (_ble != null) {
      try {
        await _ble!.disconnect();
      } catch (_) {}
    }
    _disposeBleOnly();
    if (clearSaved) {
      await saveSelectedDevice(null);
      selectedDeviceId = null;
    }
    _logController.add('[$label] Disconnected');
  }

  void _disposeBleOnly() {
    try {
      _bleLogSub?.cancel();
    } catch (_) {}
    _bleLogSub = null;
    try {
      _connSub?.cancel();
    } catch (_) {}
    _connSub = null;
    _ble?.dispose();
    _ble = null;
  }

  Future<void> saveSelectedDevice(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(prefsKey);
    } else {
      await prefs.setString(prefsKey, id);
    }
  }

  Future<void> loadSavedAndAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(prefsKey);
    if (id == null) return;
    selectedDeviceId = id;
    final granted = await ensurePermissions();
    if (!granted) {
      _logController
          .add('[$label] Permissions not granted; skipping auto-connect');
      return;
    }
    await connectTo(id);
  }

  void dispose() {
    _disposeBleOnly();
    _logController.close();
    _connectedController.close();
  }
}
