import 'dart:async';

import 'package:english_words/english_words.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/ble_service.dart' as meshtastic_ble;

const String meshtasticServiceUuid = '6ba1b218-15a8-461f-9fa8-5dcae273eafd';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => MyAppState(),
      child: MaterialApp(
        title: 'Meshtastic Bridge',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        ),
        home: MyHomePage(),
      ),
    );
  }
}

class MyAppState extends ChangeNotifier {
  var current = WordPair.random();
}

class MyHomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();

    return Scaffold(
      appBar: AppBar(title: Text('Meshtastic Bridge')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('A random idea:'),
            Text(appState.current.asLowerCase),
            SizedBox(height: 24),
            Text('Select a BLE device:'),
            BleDeviceSelector(),
          ],
        ),
      ),
    );
  }
}

class BleDeviceSelector extends StatefulWidget {
  @override
  State<BleDeviceSelector> createState() => _BleDeviceSelectorState();
}

class _BleDeviceSelectorState extends State<BleDeviceSelector> {
  StreamSubscription<BleDevice>? _scanSub;
  List<BleDevice> _devices = [];
  bool _scanning = false;
  String? _selectedDeviceId;
  meshtastic_ble.BleService? _bleService;
  List<String> _logs = [];
  StreamSubscription<String>? _logSub;
  final ScrollController _logScrollController = ScrollController();
  void Function(VoidCallback fn)? _modalSetState;

  static const _prefsKeySelectedDevice = 'selectedDeviceId';

  @override
  void initState() {
    super.initState();
    _maybeAutoConnect();
  }

  Future<void> _saveSelectedDevice(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_prefsKeySelectedDevice);
    } else {
      await prefs.setString(_prefsKeySelectedDevice, id);
    }
  }

  Future<void> _maybeAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_prefsKeySelectedDevice);
    if (id != null) {
      setState(() {
        _selectedDeviceId = id;
        _logs = [];
      });

      final granted = await _ensurePermissions();
      if (!granted) return;

      _bleService?.dispose();
      _logSub?.cancel();
      _bleService = meshtastic_ble.BleService(id);
      _attachLogListener(_bleService!);

      try {
        await _bleService!.connect();
      } catch (e) {
        setState(() => _logs.add('Auto-connect error: $e'));
      }
    }
  }

  void _attachLogListener(meshtastic_ble.BleService svc) {
    _logSub = svc.logs.listen((line) {
      setState(() {
        _logs.add(line);
        if (_logs.length > 500) _logs.removeAt(0);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScrollController.hasClients) {
          _logScrollController.animateTo(
            _logScrollController.position.maxScrollExtent,
            duration: Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  Future<void> _startScan() async {
    if (_scanning) return; // already scanning
    final granted = await _ensurePermissions();
    if (!granted) {
      setState(() => _scanning = false);
      _modalSetState?.call(() {});
      return;
    }
    setState(() {
      _scanning = true;
      _devices = [];
    });
    _modalSetState?.call(() {});

    try {
      try {
        final systemDevices = await UniversalBle.getSystemDevices(
            withServices: [meshtasticServiceUuid]);
        for (final d in systemDevices) {
          if (!_devices.any((e) => e.deviceId == d.deviceId)) _devices.add(d);
        }
      } catch (_) {}
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [meshtasticServiceUuid]),
      );
    } catch (_) {}

    _scanSub = UniversalBle.scanStream.listen((device) {
      // Rely on startScan filter by service; don't double-filter here as some platforms
      // don't populate advertisement services consistently.
      if (!_devices.any((d) => d.deviceId == device.deviceId)) {
        setState(() => _devices.add(device));
        _modalSetState?.call(() {});
      }
    }, onError: (_) {
      setState(() => _scanning = false);
      _modalSetState?.call(() {});
    }, onDone: () {
      setState(() => _scanning = false);
      _modalSetState?.call(() {});
    });
  }

  Future<bool> _ensurePermissions() async {
    if (Theme.of(context).platform == TargetPlatform.android) {
      final statuses = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      final scanGranted = statuses[Permission.bluetoothScan]?.isGranted ?? false;
      final connectGranted = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
      final bluetoothGranted = statuses[Permission.bluetooth]?.isGranted ?? false;
      final locationGranted = statuses[Permission.locationWhenInUse]?.isGranted ?? false;

      return scanGranted || bluetoothGranted || locationGranted || connectGranted;
    }
    return true;
  }

  Future<void> _stopScan() async {
    await UniversalBle.stopScan();
    try {
      await _scanSub?.cancel();
      _scanSub = null;
    } catch (_) {}
    setState(() => _scanning = false);
    _modalSetState?.call(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _selectedDeviceId == null
                  ? ElevatedButton(onPressed: _showDevicePicker, child: Text('Select device'))
                  : ElevatedButton.icon(
                      onPressed: () async {
                        try {
                          await _bleService?.disconnect();
                        } catch (_) {}
                        _bleService?.dispose();
                        await _logSub?.cancel();
                        setState(() {
                          _selectedDeviceId = null;
                          _logs = [];
                        });
                        await _saveSelectedDevice(null);
                      },
                      icon: Icon(Icons.power_settings_new),
                      label: Text('Disconnect'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                    ),
            ),
          ],
        ),
        SizedBox(height: 16),
        Text('Logs:'),
        Container(
          height: 200,
          decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
          child: _logs.isEmpty
              ? Padding(padding: EdgeInsets.all(8), child: Text('No logs yet.'))
              : ListView.builder(
                  controller: _logScrollController,
                  itemCount: _logs.length,
                  itemBuilder: (context, idx) => Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(_logs[idx]),
                  ),
                ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    try {
      _scanSub?.cancel();
    } catch (_) {}
    UniversalBle.stopScan();
    _logScrollController.dispose();
    _logSub?.cancel();
    _bleService?.dispose();
    super.dispose();
  }

  void _showDevicePicker() async {
    // Begin scanning, then show the modal.
    _startScan();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            _modalSetState = setModalState;
            return SizedBox(
              height: 400,
              child: Column(
                children: [
                  if (_scanning)
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('Scanning...')
                        ],
                      ),
                    ),
                  Expanded(
                    child: _devices.isEmpty
                        ? Center(child: Text(_scanning ? 'Scanning for devices...' : 'No devices found.'))
                        : ListView.builder(
                            itemCount: _devices.length,
                            itemBuilder: (context, idx) {
                              final d = _devices[idx];
                              final title = (d.name != null && d.name!.isNotEmpty) ? d.name! : d.deviceId;
                              return ListTile(
                                title: Text(title),
                                subtitle: Text(d.deviceId),
                                onTap: () async {
                                  Navigator.of(context).pop();
                                  await _connectToDeviceId(d.deviceId);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    // Stop scanning when the modal closes.
    await _stopScan();
  }

  Future<void> _connectToDeviceId(String id) async {
    setState(() {
      _selectedDeviceId = id;
      _logs = [];
    });

    await _saveSelectedDevice(id);

    _bleService?.dispose();
    await _logSub?.cancel();
    _bleService = meshtastic_ble.BleService(id);
    _attachLogListener(_bleService!);

    try {
      await _bleService!.connect();
    } catch (e) {
      setState(() => _logs.add('Connect error: $e'));
    }
  }
}

