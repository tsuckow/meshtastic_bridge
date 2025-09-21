import 'dart:async';

import 'package:english_words/english_words.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/ble_service.dart' as meshtastic_ble;
import 'widgets/ble_device_picker_button.dart';

// Meshtastic BLE service UUID is defined in the reusable picker; not needed here directly.

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
  String? _selectedDeviceId;
  meshtastic_ble.BleService? _bleService;
  List<String> _logs = [];
  StreamSubscription<String>? _logSub;
  final ScrollController _logScrollController = ScrollController();

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

  Future<bool> _ensurePermissions() async {
    if (Theme.of(context).platform == TargetPlatform.android) {
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _selectedDeviceId == null
                  ? BleDevicePickerButton(
                      onDeviceSelected: (deviceId) async {
                        await _connectToDeviceId(deviceId);
                      },
                    )
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
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent),
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
    _logScrollController.dispose();
    _logSub?.cancel();
    _bleService?.dispose();
    super.dispose();
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
