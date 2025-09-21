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

class MyHomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Meshtastic Bridge')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Select BLE devices:'),
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Device 1 controls
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Device 1'),
                  SizedBox(height: 6),
                  _dev1.selectedDeviceId == null
                      ? BleDevicePickerButton(
                          onDeviceSelected: (deviceId) async {
                            final ok = await _dev1.ensurePermissions();
                            if (!ok) return;
                            await _dev1.connectTo(deviceId);
                            setState(() {});
                          },
                        )
                      : ElevatedButton.icon(
                          onPressed: () async {
                            await _dev1.disconnect(clearSaved: true);
                            setState(() {});
                          },
                          icon: Icon(Icons.power_settings_new),
                          label: Text('Disconnect (${_dev1.selectedDeviceId})'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                          ),
                        ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 12),
        // Device 2 controls
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Device 2'),
                  SizedBox(height: 6),
                  _dev2.selectedDeviceId == null
                      ? BleDevicePickerButton(
                          onDeviceSelected: (deviceId) async {
                            final ok = await _dev2.ensurePermissions();
                            if (!ok) return;
                            await _dev2.connectTo(deviceId);
                            setState(() {});
                          },
                        )
                      : ElevatedButton.icon(
                          onPressed: () async {
                            await _dev2.disconnect(clearSaved: true);
                            setState(() {});
                          },
                          icon: Icon(Icons.power_settings_new),
                          label: Text('Disconnect (${_dev2.selectedDeviceId})'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                          ),
                        ),
                ],
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
    _dev1LogSub?.cancel();
    _dev2LogSub?.cancel();
    _dev1.dispose();
    _dev2.dispose();
    super.dispose();
  }
}
