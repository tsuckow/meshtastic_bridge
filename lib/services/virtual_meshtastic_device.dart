import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';

import '../generated/protos/meshtastic/mesh.pb.dart' as mesh;
import '../generated/protos/meshtastic/channel.pb.dart' as chpb;

/// Virtual Meshtastic device that emulates the BLE PhoneAPI over a simple TCP socket.
///
/// Protocol framing:
/// - Incoming data (from client) must be a sequence of frames: [u32_be length][ToRadio bytes]
/// - Outgoing data (to client) are frames: [u32_be length][FromRadio bytes]
///
/// Behavior:
/// - Accepts only one client at a time. A new connection closes the previous one.
/// - On connect, waits for a ToRadio.wantConfigId message. When received, replies with
///   FromRadio messages describing current config (myInfo, channels) and finally a
///   FromRadio.config_complete_id echoing the provided id.
/// - Incoming ToRadio.packet messages are accepted. Only encrypted MeshPackets are
///   surfaced via the [encryptedPackets] stream for app-side stats or logging.
///
/// Identity:
/// - On first run, generates and persists: nodeId (u32), uniqueId (12 bytes), and Ed25519 keys.
class VirtualMeshtasticDevice {
  VirtualMeshtasticDevice({
    required this.prefsKey,
    required this.label,
    this.port = 4242,
  });

  final String prefsKey; // namespace for persisted identity
  final String label;
  final int port;

  // Identity/state
  int? _nodeId;
  List<int>? _uniqueId12;
  crypto.SimpleKeyPairData? _ed25519KeyPair;
  List<int>? _publicKey; // 32 bytes
  String? _lastRemoteEndpoint; // last connected client's ip:port

  // Minimal channel config: index 0 with name and PSK
  final Map<int, chpb.ChannelSettings> _channels = {
    // Will be filled in after identity load with a random PSK
  };

  // TCP server and client connection
  ServerSocket? _server;
  Socket? _client;
  StreamSubscription<Socket>? _serverSub;
  StreamSubscription<List<int>>? _clientSub;
  final _rxBuffer = BytesBuilder(copy: false);

  // App-facing streams
  final _logController = StreamController<String>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();
  final _encryptedPacketController =
      StreamController<mesh.MeshPacket>.broadcast();

  Stream<String> get logs => _logController.stream;
  Stream<bool> get connected => _connectedController.stream;
  Stream<mesh.MeshPacket> get encryptedPackets =>
      _encryptedPacketController.stream;
  bool get isClientConnected => _client != null;
  String? get lastRemoteEndpoint => _lastRemoteEndpoint;

  Future<void> start() async {
    await _ensureIdentity();
    await _startServer();
  }

  Future<void> stop() async {
    await _closeClient();
    await _closeServer();
  }

  Future<void> _ensureIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    final nidKey = '${prefsKey}.nodeId';
    final uidKey = '${prefsKey}.uniqueId12';
    final privKeyKey = '${prefsKey}.ed25519.private';
    final pubKeyKey = '${prefsKey}.ed25519.public';

    final nid = prefs.getInt(nidKey);
    final uidB64 = prefs.getString(uidKey);
    final privB64 = prefs.getString(privKeyKey);
    final pubB64 = prefs.getString(pubKeyKey);

    if (nid != null && uidB64 != null && privB64 != null && pubB64 != null) {
      _nodeId = nid;
      _uniqueId12 = base64Decode(uidB64);
      final privateKeyBytes = Uint8List.fromList(base64Decode(privB64));
      final publicKeyBytes = Uint8List.fromList(base64Decode(pubB64));
      _publicKey = publicKeyBytes;
      _ed25519KeyPair = crypto.SimpleKeyPairData(
        privateKeyBytes,
        publicKey: crypto.SimplePublicKey(publicKeyBytes,
            type: crypto.KeyPairType.ed25519),
        type: crypto.KeyPairType.ed25519,
      );
      _log('Loaded identity: nodeId=$_nodeId');
    } else {
      final rng = Random.secure();
      // nodeId: avoid 0..3 and 0xff (broadcast); choose in 0x000004 .. 0x00FFFFFE range for simplicity
      int newId;
      do {
        newId = rng.nextInt(0x00FFFFFE);
      } while (newId <= 3 || newId == 0xFF);
      _nodeId = newId;

      final uid = List<int>.generate(12, (_) => rng.nextInt(256));
      _uniqueId12 = uid;

      final ed25519 = crypto.Ed25519();
      final keyPair = await ed25519.newKeyPair();
      final keyPairData = await keyPair.extract();
      _ed25519KeyPair = keyPairData;
      _publicKey = keyPairData.publicKey.bytes;

      await prefs.setInt(nidKey, _nodeId!);
      await prefs.setString(uidKey, base64Encode(Uint8List.fromList(uid)));
      await prefs.setString(
          privKeyKey, base64Encode(Uint8List.fromList(keyPairData.bytes)));
      await prefs.setString(
          pubKeyKey, base64Encode(Uint8List.fromList(_publicKey!)));
      _log('Generated new identity: nodeId=$_nodeId');
    }

    // Ensure channel 0 exists with a random 16-byte PSK
    if (!_channels.containsKey(0)) {
      final rng = Random.secure();
      final psk = List<int>.generate(16, (_) => rng.nextInt(256));
      _channels[0] = chpb.ChannelSettings(
        name: 'Virtual',
        psk: psk,
        id: 0, // id unused here
      );
    }
  }

  Future<void> _startServer() async {
    try {
      final idInfo =
          'node=$_nodeId pubKeyLen=${_publicKey?.length ?? 0} uidLen=${_uniqueId12?.length ?? 0} privLen=${_ed25519KeyPair?.bytes.length ?? 0}';
      _log(idInfo);
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _log('TCP server listening on ${_server!.address.address}:$port');
      _serverSub = _server!.listen(_handleNewClient, onError: (e, st) {
        _log('Server error: $e');
      }, onDone: () {
        _log('Server closed');
      });
    } catch (e) {
      _log('Failed to bind TCP server on 127.0.0.1:$port — $e');
      rethrow;
    }
  }

  Future<void> _closeServer() async {
    try {
      await _serverSub?.cancel();
    } catch (_) {}
    _serverSub = null;
    // Closing the server implies no active client
    _lastRemoteEndpoint = null;
    _connectedController.add(false);
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }

  Future<void> _closeClient() async {
    if (_clientSub != null) {
      try {
        await _clientSub!.cancel();
      } catch (_) {}
      _clientSub = null;
    }
    if (_client != null) {
      try {
        await _client!.close();
      } catch (_) {}
      _lastRemoteEndpoint = null;
      _client = null;
      _connectedController.add(false);
    }
  }

  void _handleNewClient(Socket client) async {
    // Only accept one client: close previous if any
    if (_client != null) {
      _log('New client connected; closing previous connection');
      await _closeClient();
    }
    _client = client;
    _rxBuffer.clear();
    _lastRemoteEndpoint =
        '${client.remoteAddress.address}:${client.remotePort}';
    _connectedController.add(true);
    _log(
        'Client connected from ${client.remoteAddress.address}:${client.remotePort}');

    _clientSub = client.listen(_onClientData,
        onError: (e) => _log('Client error: $e'),
        onDone: () {
          _log('Client disconnected');
          _lastRemoteEndpoint = null;
          _connectedController.add(false);
          _client = null;
        });
  }

  void _onClientData(List<int> data) {
    _log('Got Packet: ${data.length} bytes');
    _handleToRadio(data);
    // _rxBuffer.add(Uint8List.fromList(data));
    // final bytes = _rxBuffer.toBytes();
    // int offset = 0;
    // while (bytes.length - offset >= 4) {
    //   final length = _readU32BE(bytes, offset);
    //   if (bytes.length - offset - 4 < length) break; // wait for more
    //   final msgBytes = bytes.sublist(offset + 4, offset + 4 + length);
    //   offset += 4 + length;
    //   _handleToRadio(Uint8List.fromList(msgBytes));
    // }
    // // keep only the remaining unread bytes
    // final remaining = bytes.length - offset;
    // _rxBuffer.clear();
    // if (remaining > 0) {
    //   _rxBuffer.add(bytes.sublist(offset));
    // }
  }

  void _handleToRadio(List<int> msgBytes) {
    try {
      final to = mesh.ToRadio.fromBuffer(msgBytes);
      switch (to.whichPayloadVariant()) {
        case mesh.ToRadio_PayloadVariant.wantConfigId:
          _log('Received wantConfigId: ${to.wantConfigId}');
          _sendInitialConfigAndComplete(to.wantConfigId);
        case mesh.ToRadio_PayloadVariant.packet:
          if (to.hasPacket()) {
            final pkt = to.packet;
            if (pkt.whichPayloadVariant() ==
                mesh.MeshPacket_PayloadVariant.encrypted) {
              // Surface encrypted packet to app-facing stream
              _encryptedPacketController.add(pkt);
              _log(
                  'Received encrypted MeshPacket (len=${pkt.encrypted.length})');
            } else {
              _log('Ignoring non-encrypted MeshPacket');
            }
          }
        case mesh.ToRadio_PayloadVariant.disconnect:
          _log('Received disconnect request');
          _client?.destroy();
        case mesh.ToRadio_PayloadVariant.xmodemPacket:
        case mesh.ToRadio_PayloadVariant.mqttClientProxyMessage:
        case mesh.ToRadio_PayloadVariant.heartbeat:
          _log('Ignoring ToRadio variant: ${to.whichPayloadVariant()}');
        case mesh.ToRadio_PayloadVariant.notSet:
          _log('ToRadio notSet variant received');
      }
    } catch (e) {
      _log('Failed to parse ToRadio: $e');
    }
  }

  void _sendInitialConfigAndComplete(int requestId) {
    // MyNodeInfo
    final info = mesh.MyNodeInfo(myNodeNum: _nodeId ?? 0);
    final fr1 = mesh.FromRadio()..myInfo = info;
    _sendFromRadio(fr1);

    // Send channels by index
    for (final entry in _channels.entries) {
      final ch = chpb.Channel(index: entry.key, settings: entry.value);
      final fr = mesh.FromRadio()..channel = ch;
      _sendFromRadio(fr);
    }

    // Config complete (echo request id)
    final frDone = mesh.FromRadio()..configCompleteId = requestId;
    _sendFromRadio(frDone);
  }

  void _sendFromRadio(mesh.FromRadio msg) {
    final bytes = msg.writeToBuffer();
    final lengthPrefix = _u32be(bytes.length);
    try {
      _client?.add(lengthPrefix);
      _client?.add(bytes);
      _client?.flush();
      _log('Sent FromRadio: ${msg.whichPayloadVariant()}');
    } catch (e) {
      _log('Failed to send FromRadio: $e');
    }
  }

  int _readU32BE(List<int> b, int off) {
    return (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
  }

  List<int> _u32be(int v) => [
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ];

  void _log(String line) {
    try {
      _logController.add(line);
    } catch (_) {}
  }

  void dispose() {
    stop();
    _logController.close();
    _connectedController.close();
    _encryptedPacketController.close();
  }
}
