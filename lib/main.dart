import 'dart:async';

import 'package:english_words/english_words.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:permission_handler/permission_handler.dart';

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
      await UniversalBle.startScan();
    } catch (e) {
      // ignore start errors for now
    }

    _scanSub = UniversalBle.scanStream.listen((device) {
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
                      });
                    },
                  );
                },
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
