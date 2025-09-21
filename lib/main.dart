import 'dart:async';

import 'package:flutter/material.dart';
import 'widgets/ble_device_picker_button.dart';
import 'services/managed_meshtastic_device.dart';

// Meshtastic BLE service UUID is defined in the reusable picker.

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meshtastic Bridge',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
      ),
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _selectorKey = GlobalKey<_BleDeviceSelectorState>();

  @override
  Widget build(BuildContext context) {
    final selector = BleDeviceSelector(key: _selectorKey);
    return Scaffold(
      appBar: AppBar(
        title: Text('Meshtastic Bridge'),
        actions: [
          // Compact action for Device 1
          IconButton(
            tooltip: 'Select Device 1',
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: () async {
              final keyState = _selectorKey.currentState;
              if (keyState == null) return;
              final id = await BleDevicePickerButton.pickDevice(
                context,
                currentDeviceId: keyState._dev1.selectedDeviceId,
                onDisconnect: () async {
                  await keyState._dev1.disconnect(clearSaved: true);
                },
              );
              if (id != null) {
                await keyState._dev1.ensurePermissions();
                await keyState._dev1.connectTo(id);
                keyState.setState(() {});
              } else {
                keyState.setState(() {});
              }
            },
          ),
          // Compact action for Device 2
          IconButton(
            tooltip: 'Select Device 2',
            icon: const Icon(Icons.bluetooth_searching_outlined),
            onPressed: () async {
              final keyState = _selectorKey.currentState;
              if (keyState == null) return;
              final id = await BleDevicePickerButton.pickDevice(
                context,
                currentDeviceId: keyState._dev2.selectedDeviceId,
                onDisconnect: () async {
                  await keyState._dev2.disconnect(clearSaved: true);
                },
              );
              if (id != null) {
                await keyState._dev2.ensurePermissions();
                await keyState._dev2.connectTo(id);
                keyState.setState(() {});
              } else {
                keyState.setState(() {});
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: selector,
      ),
    );
  }
}

class BleDeviceSelector extends StatefulWidget {
  const BleDeviceSelector({super.key});
  @override
  State<BleDeviceSelector> createState() => _BleDeviceSelectorState();
}

class _BleDeviceSelectorState extends State<BleDeviceSelector> {
  List<String> _logs = [];
  late final ManagedMeshtasticDevice _dev1;
  late final ManagedMeshtasticDevice _dev2;
  StreamSubscription<String>? _dev1LogSub;
  StreamSubscription<String>? _dev2LogSub;
  final ScrollController _logScrollController = ScrollController();
  static const _prefsKey1 = 'selectedDeviceId1';
  static const _prefsKey2 = 'selectedDeviceId2';

  @override
  void initState() {
    super.initState();
    _dev1 = ManagedMeshtasticDevice(prefsKey: _prefsKey1, label: 'Device 1');
    _dev2 = ManagedMeshtasticDevice(prefsKey: _prefsKey2, label: 'Device 2');

    // Merge device logs into UI log pane
    _dev1LogSub = _dev1.logs.listen(_appendLog);
    _dev2LogSub = _dev2.logs.listen(_appendLog);

    // Auto-connect saved devices (no await to avoid delaying first build)
    _dev1.loadSavedAndAutoConnect();
    _dev2.loadSavedAndAutoConnect();
  }

  void _appendLog(String line) {
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
  }

  String _shortId(String? id) {
    if (id == null || id.isEmpty) return 'not selected';
    final s = id.replaceAll(':', '');
    if (s.length <= 4) return s;
    return '...${s.substring(s.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Optional: current device IDs summary
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            Chip(
              label: Text('Device 1: ${_shortId(_dev1.selectedDeviceId)}'),
            ),
            Chip(
              label: Text('Device 2: ${_shortId(_dev2.selectedDeviceId)}'),
            ),
          ],
        ),
        SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Logs:'),
            TextButton.icon(
              onPressed: () => setState(() => _logs.clear()),
              icon: const Icon(Icons.clear),
              label: const Text('Clear'),
            ),
          ],
        ),
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
    _dev1LogSub?.cancel();
    _dev2LogSub?.cancel();
    _dev1.dispose();
    _dev2.dispose();
    super.dispose();
  }
}
