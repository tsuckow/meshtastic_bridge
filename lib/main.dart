import 'dart:async';

import 'package:flutter/material.dart';
import 'widgets/ble_device_picker_button.dart';
import 'services/managed_meshtastic_device.dart';
import 'generated/protos/meshtastic/portnums.pbenum.dart' as portnums;

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
  StreamSubscription<bool>? _dev1Conn;
  StreamSubscription<bool>? _dev2Conn;
  bool _d1 = false;
  bool _d2 = false;

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
            icon: Icon(Icons.bluetooth_searching,
                color: _d1 ? Colors.green : null),
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
            icon: Icon(Icons.bluetooth_searching_outlined,
                color: _d2 ? Colors.green : null),
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
  StreamSubscription<void>? _dev1StatsSub;
  StreamSubscription<void>? _dev2StatsSub;
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

    // Bubble connection state to AppBar icons
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final home = context.findAncestorStateOfType<_MyHomePageState>();
      if (home != null) {
        home._dev1Conn?.cancel();
        home._dev2Conn?.cancel();
        home._dev1Conn = _dev1.connected.listen((c) {
          home.setState(() => home._d1 = c);
        });
        home._dev2Conn = _dev2.connected.listen((c) {
          home.setState(() => home._d2 = c);
        });
        // Also set initial values so icons reflect current state immediately
        home.setState(() {
          home._d1 = _dev1.isConnected;
          home._d2 = _dev2.isConnected;
        });
      }
    });

    // Auto-connect saved devices (no await to avoid delaying first build)
    _dev1.loadSavedAndAutoConnect();
    _dev2.loadSavedAndAutoConnect();

    // Stats listeners to refresh table
    _dev1StatsSub = _dev1.statsChanged.listen((_) => setState(() {}));
    _dev2StatsSub = _dev2.statsChanged.listen((_) => setState(() {}));
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

  // Removed _shortId helper (no longer used after switching to stats table)

  @override
  Widget build(BuildContext context) {
    final logTextStyle =
        Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildStatsTable(context),
        const SizedBox(height: 16),
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
              ? Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('No logs yet.', style: logTextStyle),
                )
              : ListView.builder(
                  controller: _logScrollController,
                  itemCount: _logs.length,
                  itemBuilder: (context, idx) => Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(_logs[idx], style: logTextStyle),
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
    _dev1StatsSub?.cancel();
    _dev2StatsSub?.cancel();
    _dev1.dispose();
    _dev2.dispose();
    // Also cancel AppBar listeners if set
    final home = context.findAncestorStateOfType<_MyHomePageState>();
    home?._dev1Conn?.cancel();
    home?._dev2Conn?.cancel();
    super.dispose();
  }

  Widget _buildStatsTable(BuildContext context) {
    // Combine ports across devices and sort
    final ports = <int>{}
      ..addAll(_dev1.portCounts.keys)
      ..addAll(_dev2.portCounts.keys);
    final sortedPorts = ports.toList()..sort();

    final headerStyle =
        Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12);
    final cellTextStyle =
        Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12);
    final cellPad = const EdgeInsets.symmetric(vertical: 4, horizontal: 8);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Packet statistics'),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            children: [
              Row(children: [
                Expanded(
                  flex: 6,
                  child: Padding(
                    padding: cellPad,
                    child: Text(
                      'Port',
                      style: headerStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: cellPad,
                    child: Text(
                      'Device 1',
                      style: headerStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: cellPad,
                    child: Text(
                      'Device 2',
                      style: headerStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
              ]),
              const Divider(height: 1),
              Row(children: [
                Expanded(
                  flex: 6,
                  child: Padding(
                    padding: cellPad,
                    child: Text(
                      'Encrypted (count)',
                      style: cellTextStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: cellPad,
                    child: Text(
                      '${_dev1.encryptedPacketCount}',
                      style: cellTextStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: cellPad,
                    child: Text(
                      '${_dev2.encryptedPacketCount}',
                      style: cellTextStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
              ]),
              const Divider(height: 1),
              if (sortedPorts.isEmpty)
                Padding(
                  padding: cellPad,
                  child: Text('No unencrypted packets observed yet.'),
                )
              else
                ...sortedPorts.map((port) {
                  final c1 = _dev1.portCounts[port] ?? 0;
                  final c2 = _dev2.portCounts[port] ?? 0;
                  final name =
                      portnums.PortNum.valueOf(port)?.name ?? 'PORT_$port';
                  return Column(
                    children: [
                      Row(children: [
                        Expanded(
                          flex: 6,
                          child: Padding(
                            padding: cellPad,
                            child: Text(
                              name,
                              style: cellTextStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Padding(
                            padding: cellPad,
                            child: Text(
                              '$c1',
                              style: cellTextStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Padding(
                            padding: cellPad,
                            child: Text(
                              '$c2',
                              style: cellTextStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                        ),
                      ]),
                      const Divider(height: 1),
                    ],
                  );
                }).toList(),
            ],
          ),
        ),
      ],
    );
  }
}
