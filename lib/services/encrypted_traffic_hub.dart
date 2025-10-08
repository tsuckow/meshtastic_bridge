import 'dart:async';

import '../generated/protos/meshtastic/mesh.pb.dart' as mesh;
import 'managed_meshtastic_device.dart';
import 'virtual_meshtastic_device.dart';

/// EncryptedTrafficHub bridges encrypted MeshPacket traffic between multiple devices.
///
/// MVP goals:
/// - Attach to two ManagedMeshtasticDevice instances (physical BLE devices)
///   and one VirtualMeshtasticDevice (TCP emulated).
/// - Listen for encrypted packets from any source and forward to the others.
/// - Provide an overridable filter callback to allow future selective forwarding.
typedef ForwardFilter = FutureOr<bool> Function(
    Source source, mesh.MeshPacket pkt);

class EncryptedTrafficHub {
  EncryptedTrafficHub({
    this.deviceA,
    this.deviceB,
    this.virtualDevice,
    ForwardFilter? filter,
  }) : _filter = filter ?? _defaultAllowAll;

  ManagedMeshtasticDevice? deviceA;
  ManagedMeshtasticDevice? deviceB;
  VirtualMeshtasticDevice? virtualDevice;

  static FutureOr<bool> _defaultAllowAll(Source _s, mesh.MeshPacket _p) => true;

  ForwardFilter _filter;

  StreamSubscription? _subA;
  StreamSubscription? _subB;
  StreamSubscription? _subV;

  final _logController = StreamController<String>.broadcast();
  Stream<String> get logs => _logController.stream;

  /// Attach to currently set devices and begin forwarding.
  void start() {
    _disposeSubs();
    if (deviceA != null) {
      _subA = deviceA!.encryptedPackets.listen((pkt) {
        _onPacket(Source.deviceA, pkt);
      });
      _log('Listening on deviceA');
    }
    if (deviceB != null) {
      _subB = deviceB!.encryptedPackets.listen((pkt) {
        _onPacket(Source.deviceB, pkt);
      });
      _log('Listening on deviceB');
    }
    if (virtualDevice != null) {
      _subV = virtualDevice!.encryptedPackets.listen((pkt) {
        _onPacket(Source.virtual, pkt);
      });
      _log('Listening on virtual device');
    }
  }

  /// Stop forwarding and detach listeners.
  void stop() {
    _disposeSubs();
  }

  void _disposeSubs() {
    try {
      _subA?.cancel();
    } catch (_) {}
    _subA = null;
    try {
      _subB?.cancel();
    } catch (_) {}
    _subB = null;
    try {
      _subV?.cancel();
    } catch (_) {}
    _subV = null;
  }

  Future<void> _onPacket(Source src, mesh.MeshPacket pkt) async {
    try {
      // Basic sanity: only forward encrypted payloads
      if (pkt.whichPayloadVariant() !=
          mesh.MeshPacket_PayloadVariant.encrypted) {
        _log('Ignoring non-encrypted packet from $src');
        return;
      }

      if (!await _allow(src, pkt)) {
        _log('Filter blocked packet from $src');
        return;
      }

      // Forward to all other endpoints
      final futures = <Future<void>>[];
      switch (src) {
        case Source.deviceA:
          if (deviceB?.isConnected == true) {
            futures.add(deviceB!.sendMeshPacket(pkt));
          }
          if (virtualDevice?.isClientConnected == true) {
            futures.add(virtualDevice!.handlePacketFromHub(pkt));
          }
          break;
        case Source.deviceB:
          if (deviceA?.isConnected == true) {
            futures.add(deviceA!.sendMeshPacket(pkt));
          }
          if (virtualDevice?.isClientConnected == true) {
            futures.add(virtualDevice!.handlePacketFromHub(pkt));
          }
          break;
        case Source.virtual:
          if (deviceA?.isConnected == true) {
            futures.add(deviceA!.sendMeshPacket(pkt));
          }
          if (deviceB?.isConnected == true) {
            futures.add(deviceB!.sendMeshPacket(pkt));
          }
          break;
      }

      if (futures.isNotEmpty) {
        await Future.wait(futures);
      }
    } catch (e) {
      _log('Forward error from $src: $e');
    }
  }

  FutureOr<bool> _allow(Source source, mesh.MeshPacket pkt) =>
      _filter(source, pkt);

  /// Update the forwarding filter.
  void setFilter(ForwardFilter filter) {
    _filter = filter;
  }

  void dispose() {
    stop();
    _logController.close();
  }

  void _log(String line) {
    try {
      _logController.add(line);
    } catch (_) {}
  }
}

enum Source { deviceA, deviceB, virtual }
