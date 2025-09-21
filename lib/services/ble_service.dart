import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';
// protobuf package is used indirectly via generated files; no direct import needed here

import '../generated/protos/meshtastic/mesh.pb.dart' as mesh;
import '../generated/protos/meshtastic/mqtt.pb.dart' as mqtt;

const String meshtasticServiceUuid = '6ba1b218-15a8-461f-9fa8-5dcae273eafd';
const String fromRadioChar = '2c55e69e-4993-11ed-b878-0242ac120002';
const String toRadioChar = 'f75c76d2-129e-4dad-a1dd-7866124401e7';
const String fromNumChar = 'ed9da18c-a800-4f66-a670-aa7547e34453';
const String logChar = '5a3d6e49-06e6-4423-9944-e9de8cdf9547';

class BleService {
  final String deviceId;
  StreamSubscription<Uint8List>? _fromRadioSub;
  StreamSubscription<Uint8List>? _fromNumSub;
  StreamSubscription<Uint8List>? _logSub;
  StreamSubscription<bool>? _connectionSub;

  final StreamController<String> _logController = StreamController.broadcast();

  Stream<String> get logs => _logController.stream;

  BleService(this.deviceId);

  Future<void> connect() async {
    _logController.add('connect: stopping scan');
    try {
      await UniversalBle.stopScan();
      _logController.add('connect: stopped scan');
    } catch (e) {
      _logController.add('connect: stopScan failed: $e');
    }

    _logController.add('connect: connecting to $deviceId');
    try {
      await UniversalBle.connect(deviceId);
      _logController.add('connect: connect() completed');
    } catch (e) {
      _logController.add('connect: connect() failed: $e');
      rethrow;
    }

    // discover services so we can subscribe
    _logController.add('connect: discovering services');
    try {
      await UniversalBle.discoverServices(deviceId);
      _logController.add('connect: discoverServices completed');
    } catch (e) {
      _logController.add('connect: discoverServices failed: $e');
      // continue even if discovery fails on some platforms
    }

    // request MTU (best effort)
    _logController.add('connect: requesting MTU');
    try {
      final mtu = await UniversalBle.requestMtu(deviceId, 512);
      _logController.add('connect: requestMtu completed (mtu=$mtu)');
    } catch (e) {
      _logController.add('connect: requestMtu failed: $e');
    }

    // Subscribe to FromNum notifications. When FromNum notifies, we need to read
    // the fromRadio mailbox characteristic and drain any available packets.
    _logController.add('connect: subscribing to FromNum char');
    try {
      await UniversalBle.subscribeNotifications(
          deviceId, meshtasticServiceUuid, fromNumChar);
      _logController.add('connect: subscribeNotifications(fromNum) ok');
    } catch (e) {
      _logController.add('connect: subscribeNotifications(fromNum) failed: $e');
    }

    _fromNumSub?.cancel();
    _fromNumSub = UniversalBle.characteristicValueStream(deviceId, fromNumChar)
        .listen((value) {
      _logController.add('FromNum notify: ${value.length} bytes');
      // Read and drain fromRadio mailbox
      _drainFromRadio();
    }, onError: (e) {
      _logController.add('FromNum stream error: $e');
    });

    // Subscribe to LOG notifications
    _logController.add('connect: subscribing to LOG char');
    try {
      await UniversalBle.subscribeNotifications(
          deviceId, meshtasticServiceUuid, logChar);
      _logController.add('connect: subscribeNotifications(log) ok');
    } catch (e) {
      _logController.add('connect: subscribeNotifications(log) failed: $e');
    }

    _logSub?.cancel();
    _logSub = UniversalBle.characteristicValueStream(deviceId, logChar).listen(
        (value) {
      // Log characteristic is UTF8 text in many devices
      try {
        final text = String.fromCharCodes(value);
        _logController.add('LOG: $text');
      } catch (e) {
        _logController.add('LOG (raw): $value');
      }
    }, onError: (e) {
      _logController.add('Log stream error: $e');
    });

    // Connection updates
    _connectionSub?.cancel();
    _connectionSub =
        UniversalBle.connectionStream(deviceId).listen((connected) {
      _logController
          .add('Connection state: ${connected ? 'connected' : 'disconnected'}');
    });

    // After establishing connection and subscribing, request the full config
    // by sending a ToRadio message with wantConfigId set to a random uint32.
    try {
      final rand = DateTime.now().millisecondsSinceEpoch & 0xffffffff;
      _logController.add('connect: preparing wantConfigId $rand');
      final toRadio = mesh.ToRadio(wantConfigId: rand);
      await writeToRadio(toRadio);
      _logController.add('Sent wantConfigId: $rand');
      // Attempt to immediately read any config packets now that we've requested them.
      try {
        _logController.add('connect: draining fromRadio after wantConfigId');
        await _drainFromRadio();
        _logController.add('connect: finished draining fromRadio');
      } catch (e) {
        _logController.add('connect: draining fromRadio failed: $e');
      }
    } catch (e) {
      _logController.add('Failed to send wantConfigId: $e');
    }
  }

  Future<void> disconnect() async {
    _logController.add('disconnect: cancelling subscriptions');
    _fromRadioSub?.cancel();
    _fromNumSub?.cancel();
    _logSub?.cancel();
    _connectionSub?.cancel();
    try {
      _logController.add('disconnect: unsubscribing from fromRadio');
      await UniversalBle.unsubscribe(
          deviceId, meshtasticServiceUuid, fromRadioChar);
    } catch (_) {}
    try {
      _logController.add('disconnect: unsubscribing from fromNum');
      await UniversalBle.unsubscribe(
          deviceId, meshtasticServiceUuid, fromNumChar);
    } catch (_) {}
    try {
      _logController.add('disconnect: unsubscribing from log');
      await UniversalBle.unsubscribe(deviceId, meshtasticServiceUuid, logChar);
    } catch (_) {}
    try {
      _logController.add('disconnect: calling disconnect()');
      await UniversalBle.disconnect(deviceId);
      _logController.add('disconnect: disconnect() completed');
    } catch (_) {}
    _logController.add('Disconnected');
  }

  void _handleFromRadio(Uint8List bytes) {
    if (bytes.isEmpty) return;
    try {
      final msg = mesh.FromRadio.fromBuffer(bytes);
      // Serialize the full FromRadio message to proto3 JSON for logging.
      try {
        final jsonMap = msg.toProto3Json();
        final jsonText = jsonEncode(jsonMap);
        _logController.add('FromRadio json: $jsonText');
      } catch (e) {
        _logController.add('FromRadio payload: ${msg.whichPayloadVariant()}');
      }

      if (msg.hasMqttClientProxyMessage()) {
        final v = msg.mqttClientProxyMessage;
        if (v.hasData()) {
          final env = mqtt.ServiceEnvelope.fromBuffer(v.data);
          try {
            _logController
                .add('MQTT envelope json: ${jsonEncode(env.toProto3Json())}');
          } catch (e) {
            _logController.add('MQTT envelope: ${env.packet}');
          }
        }
      }
    } catch (e) {
      _logController.add('Failed to decode FromRadio: $e');
    }
  }

  /// Read and drain the `fromRadio` mailbox characteristic.
  /// The device will return an empty packet when there's nothing to read.
  Future<void> _drainFromRadio() async {
    const int maxReads = 500; // safety cap
    int reads = 0;
    try {
      while (reads < maxReads) {
        reads += 1;
        _logController
            .add('drainFromRadio: reading fromRadio (attempt $reads)');
        Uint8List bytes;
        try {
          final v = await UniversalBle.read(
              deviceId, meshtasticServiceUuid, fromRadioChar);
          bytes = v;
        } catch (e) {
          _logController.add('drainFromRadio: read failed: $e');
          break;
        }

        if (bytes.isEmpty) {
          _logController.add('drainFromRadio: empty packet, done');
          return;
        }

        _logController.add('drainFromRadio: got ${bytes.length} bytes');
        try {
          _handleFromRadio(bytes);
        } catch (e) {
          _logController.add('drainFromRadio: decode error: $e');
        }
      }
    } catch (e) {
      _logController.add('drainFromRadio: unexpected error: $e');
    }
  }

  Future<void> writeToRadio(mesh.ToRadio toRadio) async {
    final bytes = toRadio.writeToBuffer();
    _logController.add(
        'writeToRadio: writing ${bytes.length} bytes to $toRadioChar (with response)');
    try {
      await UniversalBle.write(deviceId, meshtasticServiceUuid, toRadioChar,
          Uint8List.fromList(bytes),
          withoutResponse: false);
      _logController.add('writeToRadio: write successful (with response)');
    } catch (e) {
      _logController.add('writeToRadio: write failed (with response): $e');
      rethrow;
    }
  }

  void dispose() {
    _fromRadioSub?.cancel();
    _logSub?.cancel();
    _connectionSub?.cancel();
    _logController.close();
  }
}
