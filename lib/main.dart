import 'dart:async';

import 'package:english_words/english_words.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/ble_service.dart' as meshtastic_ble;

const String meshtasticServiceUuid = '6ba1b218-15a8-461f-9fa8-5dcae273eafd';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => MyAppState(),
      child: MaterialApp(
        title: 'Namer App',
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
      body: Column(
        children: [
          Text('A random idea:'),
          Text(appState.current.asLowerCase),
          SizedBox(height: 32),
          Text('Select a BLE device:'),
          BleDeviceSelector(),
        ],
      ),
    );
  }
}

class BleDeviceSelector extends StatefulWidget {
  @override
  State<BleDeviceSelector> createState() => _BleDeviceSelectorState();
}

class _BleDeviceSelectorState extends State<BleDeviceSelector> {
  late final StreamSubscription<BleDevice> _scanSub;
  List<BleDevice> _devices = [];
  bool _scanning = false;
  String? _selectedDeviceId;
  meshtastic_ble.BleService? _bleService;
  List<String> _logs = [];
  StreamSubscription<String>? _logSub;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  void _startScan() async {
    // Request runtime permissions before scanning
    final granted = await _ensurePermissions();
    if (!granted) {
      // Permissions not granted: update state and return
      setState(() {
        _scanning = false;
      });
      return;
    }
    setState(() {
      _scanning = true;
      _devices = [];
    });
    // start scan and listen to the package's scanStream
    try {
      // Populate any already-known/system devices advertising the Meshtastic service
      try {
        final systemDevices = await UniversalBle.getSystemDevices(
            withServices: [meshtasticServiceUuid]);
        for (final d in systemDevices) {
          if (!_devices.any((e) => e.deviceId == d.deviceId)) {
            _devices.add(d);
          }
        }
      } catch (_) {
        // ignore; not all platforms may support getSystemDevices
      }
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [meshtasticServiceUuid]),
      );
    } catch (e) {
      // ignore start errors for now
    }

    _scanSub = UniversalBle.scanStream.listen((device) {
      // Filter to Meshtastic devices: check advertised services for our UUID.
      final services = device.services.map((s) => s.toLowerCase()).toList();
      if (!services.contains(meshtasticServiceUuid.toLowerCase())) {
        return; // ignore non-meshtastic devices
      }

      if (!_devices.any((d) => d.deviceId == device.deviceId)) {
        setState(() {
          _devices.add(device);
        });
      }
    }, onError: (err) {
      // handle scan errors if needed
    }, onDone: () {
      setState(() {
        _scanning = false;
      });
    });
  }

  Future<bool> _ensurePermissions() async {
    // On Android 12+ we need BLUETOOTH_SCAN and BLUETOOTH_CONNECT. On older devices, location
    // permission may be required for scans.
    if (Theme.of(context).platform == TargetPlatform.android) {
      final statuses = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      // Check at least scan/connect granted
      final scanGranted =
          statuses[Permission.bluetoothScan]?.isGranted ?? false;
      final connectGranted =
          statuses[Permission.bluetoothConnect]?.isGranted ?? false;
      final bluetoothGranted =
          statuses[Permission.bluetooth]?.isGranted ?? false;
      final locationGranted =
          statuses[Permission.locationWhenInUse]?.isGranted ?? false;

      return scanGranted ||
          bluetoothGranted ||
          locationGranted ||
          connectGranted;
    }

    // On other platforms, permissions are typically not required here
    return true;
  }

  void _stopScan() async {
    await UniversalBle.stopScan();
    await _scanSub.cancel();
    setState(() {
      _scanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _scanning
            ? Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 12),
                  ElevatedButton(onPressed: _stopScan, child: Text('Stop')),
                ],
              )
            : ElevatedButton(
                onPressed: _startScan,
                child: Text('Scan'),
              ),
        SizedBox(height: 16),
        _devices.isEmpty
            ? Text('No devices found.')
            : ListView.builder(
                shrinkWrap: true,
                itemCount: _devices.length,
                itemBuilder: (context, index) {
                  final device = _devices[index];
                  return ListTile(
                    title: Text(device.name != null && device.name!.isNotEmpty
                        ? device.name!
                        : device.deviceId),
                    subtitle: Text(device.deviceId),
                    trailing: _selectedDeviceId == device.deviceId
                        ? Icon(Icons.check, color: Colors.green)
                        : null,
                    onTap: () {
                      setState(() {
                        _selectedDeviceId = device.deviceId;
                        _logs = [];
                      });

                      // Connect using BleService
                      _bleService?.dispose();
                      _logSub?.cancel();
                      _bleService = meshtastic_ble.BleService(device.deviceId);

                      // Attach log listener before connecting so we capture logs emitted
                      // during the connection procedure (service discovery / first writes).
                      _logSub = _bleService!.logs.listen((line) {
                        setState(() {
                          _logs.add(line);
                          if (_logs.length > 500) _logs.removeAt(0);
                        });
                      });

                      _bleService!.connect().catchError((e) {
                        setState(() {
                          _logs.add('Connect error: $e');
                        });
                      });
                    },
                  );
                },
              ),
        SizedBox(height: 16),
        Text('Logs:'),
        Container(
          height: 200,
          decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
          child: _logs.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('No logs yet.'),
                )
              : ListView.builder(
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
      _scanSub.cancel();
    } catch (_) {}
    UniversalBle.stopScan();
    super.dispose();
  }
}
