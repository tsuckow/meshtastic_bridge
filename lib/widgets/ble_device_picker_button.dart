import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_ble/universal_ble.dart';

/// Reusable button that opens a modal and scans for BLE devices with the given service UUID.
/// When a device is selected, [onDeviceSelected] is invoked with the deviceId.
class BleDevicePickerButton extends StatefulWidget {
  const BleDevicePickerButton({
    super.key,
    required this.onDeviceSelected,
    this.serviceUuid = '6ba1b218-15a8-461f-9fa8-5dcae273eafd',
    this.buttonLabel = 'Select device',
  });

  final void Function(String deviceId) onDeviceSelected;
  final String serviceUuid;
  final String buttonLabel;

  @override
  State<BleDevicePickerButton> createState() => _BleDevicePickerButtonState();

  /// Open the picker modal without rendering the button and return the selected deviceId.
  static Future<String?> pickDevice(
    BuildContext context, {
    String serviceUuid = '6ba1b218-15a8-461f-9fa8-5dcae273eafd',
    String? currentDeviceId,
    Future<void> Function()? onDisconnect,
  }) async {
    bool scanning = false;
    final List<BleDevice> devices = [];
    StreamSubscription<BleDevice>? scanSub;
    void Function(VoidCallback fn)? modalSetState;

    Future<bool> ensurePermissions() async {
      if (Theme.of(context).platform == TargetPlatform.android) {
        final statuses = await [
          Permission.bluetooth,
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.locationWhenInUse,
        ].request();
        final scanGranted =
            statuses[Permission.bluetoothScan]?.isGranted ?? false;
        final connectGranted =
            statuses[Permission.bluetoothConnect]?.isGranted ?? false;
        final bluetoothGranted =
            statuses[Permission.bluetooth]?.isGranted ?? false;
        final locationGranted =
            statuses[Permission.locationWhenInUse]?.isGranted ?? false;
        return scanGranted ||
            connectGranted ||
            bluetoothGranted ||
            locationGranted;
      }
      return true;
    }

    Future<void> startScan() async {
      if (scanning) return;
      final granted = await ensurePermissions();
      if (!granted) {
        scanning = false;
        modalSetState?.call(() {});
        return;
      }
      scanning = true;
      devices.clear();
      modalSetState?.call(() {});

      try {
        try {
          final systemDevices = await UniversalBle.getSystemDevices(
            withServices: [serviceUuid],
          );
          for (final d in systemDevices) {
            if (!devices.any((e) => e.deviceId == d.deviceId)) devices.add(d);
          }
        } catch (_) {}
        await UniversalBle.startScan(
          scanFilter: ScanFilter(withServices: [serviceUuid]),
        );
      } catch (_) {}

      scanSub = UniversalBle.scanStream.listen((device) {
        if (!devices.any((d) => d.deviceId == device.deviceId)) {
          devices.add(device);
          modalSetState?.call(() {});
        }
      }, onError: (_) {
        scanning = false;
        modalSetState?.call(() {});
      }, onDone: () {
        scanning = false;
        modalSetState?.call(() {});
      });
    }

    Future<void> stopScan() async {
      await UniversalBle.stopScan();
      try {
        await scanSub?.cancel();
        scanSub = null;
      } catch (_) {}
      scanning = false;
      modalSetState?.call(() {});
    }

    String? selected;

    // If a device is already selected for this slot, show a disconnect modal instead of scanning.
    if (currentDeviceId != null) {
      await showModalBottomSheet(
        context: context,
        builder: (_) {
          return SizedBox(
            height: 180,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Connected device',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(currentDeviceId,
                      style: Theme.of(context).textTheme.bodyMedium),
                  const Spacer(),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            try {
                              if (onDisconnect != null) {
                                await onDisconnect();
                              }
                            } finally {
                              Navigator.of(context).pop();
                            }
                          },
                          icon: const Icon(Icons.power_settings_new),
                          label: const Text('Disconnect'),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
      // No selection in disconnect flow
      return null;
    }

    // Begin scanning and open modal
    startScan();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            modalSetState = setModalState;
            return SizedBox(
              height: 400,
              child: Column(
                children: [
                  if (scanning)
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('Scanning...'),
                        ],
                      ),
                    ),
                  Expanded(
                    child: devices.isEmpty
                        ? Center(
                            child: Text(scanning
                                ? 'Scanning for devices...'
                                : 'No devices found.'))
                        : ListView.builder(
                            itemCount: devices.length,
                            itemBuilder: (context, idx) {
                              final d = devices[idx];
                              final title =
                                  (d.name != null && d.name!.isNotEmpty)
                                      ? d.name!
                                      : d.deviceId;
                              return ListTile(
                                title: Text(title),
                                subtitle: Text(d.deviceId),
                                onTap: () {
                                  selected = d.deviceId;
                                  Navigator.of(context).pop();
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
    await stopScan();
    return selected;
  }
}

class _BleDevicePickerButtonState extends State<BleDevicePickerButton> {
  bool _scanning = false;
  List<BleDevice> _devices = [];
  StreamSubscription<BleDevice>? _scanSub;
  void Function(VoidCallback fn)? _modalSetState;

  Future<bool> _ensurePermissions() async {
    // Only request Android-specific permissions; other platforms no-op.
    if (Theme.of(context).platform == TargetPlatform.android) {
      final statuses = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

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
    return true;
  }

  Future<void> _startScan() async {
    if (_scanning) return;
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
      // Preload system-known devices that match service UUID where supported
      try {
        final systemDevices = await UniversalBle.getSystemDevices(
          withServices: [widget.serviceUuid],
        );
        for (final d in systemDevices) {
          if (!_devices.any((e) => e.deviceId == d.deviceId)) _devices.add(d);
        }
      } catch (_) {}

      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [widget.serviceUuid]),
      );
    } catch (_) {}

    _scanSub = UniversalBle.scanStream.listen((device) {
      // Avoid double-filtering; rely on scan filter in startScan.
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

  Future<void> _stopScan() async {
    await UniversalBle.stopScan();
    try {
      await _scanSub?.cancel();
      _scanSub = null;
    } catch (_) {}
    setState(() => _scanning = false);
    _modalSetState?.call(() {});
  }

  Future<void> _openModal() async {
    // Kick off scanning then show modal.
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
                          SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('Scanning...'),
                        ],
                      ),
                    ),
                  Expanded(
                    child: _devices.isEmpty
                        ? Center(
                            child: Text(_scanning
                                ? 'Scanning for devices...'
                                : 'No devices found.'),
                          )
                        : ListView.builder(
                            itemCount: _devices.length,
                            itemBuilder: (context, idx) {
                              final d = _devices[idx];
                              final title =
                                  (d.name != null && d.name!.isNotEmpty)
                                      ? d.name!
                                      : d.deviceId;
                              return ListTile(
                                title: Text(title),
                                subtitle: Text(d.deviceId),
                                onTap: () async {
                                  Navigator.of(context).pop();
                                  widget.onDeviceSelected(d.deviceId);
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
    await _stopScan();
  }

  @override
  void dispose() {
    try {
      _scanSub?.cancel();
    } catch (_) {}
    UniversalBle.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: _openModal,
      child: Text(widget.buttonLabel),
    );
  }
}
