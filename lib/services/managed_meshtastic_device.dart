import 'dart:async';
import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_service.dart' as meshtastic_ble;
import '../generated/protos/meshtastic/mesh.pb.dart' as mesh;
import '../generated/protos/meshtastic/portnums.pbenum.dart' as portnums;

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
  StreamSubscription<mesh.MeshPacket>? _pktSub;
  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  final StreamController<bool> _connectedController =
      StreamController<bool>.broadcast();
  bool _isConnected = false;
  bool _autoReconnectEnabled = false;
  bool _reconnectLoopRunning = false;
  int _reconnectAttempt = 0;
  bool _connecting = false;

  // Stats
  int _encryptedPackets = 0;
  final Map<int, int> _portCounts = <int, int>{};
  final StreamController<void> _statsController =
      StreamController<void>.broadcast();
  Stream<void> get statsChanged => _statsController.stream;
  int get encryptedPacketCount => _encryptedPackets;
  Map<int, int> get portCounts => Map.unmodifiable(_portCounts);

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
    _autoReconnectEnabled = true; // enable auto-reconnect for this selection
    _reconnectAttempt = 0; // reset backoff sequence for a new target

    // Forward logs with label prefix
    _bleLogSub = _ble!.logs.listen((line) {
      _logController.add('[$label] $line');
    });

    // Forward connection state
    _connSub = _ble!.connection.listen((c) {
      _isConnected = c;
      _connectedController.add(c);
      _logController.add('[$label] ${c ? 'Connected' : 'Disconnected'}');
      if (!c && _autoReconnectEnabled && selectedDeviceId != null) {
        _scheduleReconnect();
      }
    });

    // Packets for stats
    _pktSub = _ble!.packets.listen((pkt) {
      try {
        switch (pkt.whichPayloadVariant()) {
          case mesh.MeshPacket_PayloadVariant.encrypted:
            _encryptedPackets += 1;
            break;
          case mesh.MeshPacket_PayloadVariant.decoded:
            if (pkt.hasDecoded()) {
              final p = pkt.decoded;
              final port = p.hasPortnum()
                  ? p.portnum.value
                  : portnums.PortNum.UNKNOWN_APP.value;
              _portCounts.update(port, (v) => v + 1, ifAbsent: () => 1);
            }
            break;
          case mesh.MeshPacket_PayloadVariant.notSet:
            // ignore
            break;
        }
      } catch (_) {}
      // notify listeners
      try {
        _statsController.add(null);
      } catch (_) {}
    });

    try {
      _connecting = true;
      await _ble!.connect();
    } catch (e) {
      _logController.add('[$label] Connect error: $e');
      // Do not throw; schedule reconnect attempts
      if (_autoReconnectEnabled && selectedDeviceId != null) {
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  Future<void> disconnect({bool clearSaved = true}) async {
    // Manual disconnect should disable auto-reconnect
    _autoReconnectEnabled = false;
    _reconnectLoopRunning = false;
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
    try {
      _pktSub?.cancel();
    } catch (_) {}
    _pktSub = null;
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

  void _scheduleReconnect() {
    if (_reconnectLoopRunning) return;
    if (!_autoReconnectEnabled) return;
    if (selectedDeviceId == null) return;
    _reconnectLoopRunning = true;
    _reconnectAttempt = 0;
    _logController.add('[$label] Scheduling auto-reconnect');
    // fire and forget
    _runReconnectLoop();
  }

  Duration _backoffForAttempt(int attempt) {
    // 2s, 5s, 10s, 20s, max 30s
    final secs = [2, 5, 10, 20, 30];
    final idx = attempt < secs.length ? attempt : secs.length - 1;
    return Duration(seconds: secs[idx]);
  }

  Future<void> _runReconnectLoop() async {
    while (_reconnectLoopRunning && _autoReconnectEnabled) {
      if (_isConnected) break;
      if (selectedDeviceId == null) break;

      final delay = _backoffForAttempt(_reconnectAttempt++);
      _logController.add(
          '[$label] Reconnect attempt ${_reconnectAttempt}, waiting ${delay.inSeconds}s');
      await Future.delayed(delay);

      if (!_autoReconnectEnabled || selectedDeviceId == null || _isConnected) {
        break;
      }

      final granted = await ensurePermissions();
      if (!granted) {
        _logController.add('[$label] Permissions missing; will retry later');
        continue;
      }

      try {
        if (_connecting) {
          _logController
              .add('[$label] Already connecting; skipping this attempt');
          continue;
        }
        _connecting = true;
        if (_ble == null) {
          _logController
              .add('[$label] Recreating BLE service and reconnecting');
          _ble = meshtastic_ble.BleService(selectedDeviceId!);
          _bleLogSub = _ble!.logs.listen((line) {
            _logController.add('[$label] $line');
          });
          _connSub = _ble!.connection.listen((c) {
            _isConnected = c;
            _connectedController.add(c);
            _logController.add('[$label] ${c ? 'Connected' : 'Disconnected'}');
            if (!c && _autoReconnectEnabled && selectedDeviceId != null) {
              _scheduleReconnect();
            }
          });
        }
        _logController
            .add('[$label] Attempting reconnect to $selectedDeviceId');
        await _ble!.connect();
      } catch (e) {
        _logController.add('[$label] Reconnect failed: $e');
      } finally {
        _connecting = false;
      }
    }
    _reconnectLoopRunning = false;
    if (_isConnected) {
      _logController.add('[$label] Auto-reconnect succeeded');
    }
  }

  void dispose() {
    _disposeBleOnly();
    _logController.close();
    _connectedController.close();
    _statsController.close();
  }
}
