import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';

import '../generated/protos/meshtastic/mesh.pb.dart' as mesh;
import '../generated/protos/meshtastic/channel.pb.dart' as chpb;
import '../generated/protos/meshtastic/config.pb.dart' as config;

/// Virtual Meshtastic device that emulates the BLE PhoneAPI over a simple TCP socket.
///
/// Protocol framing (Meshtastic client API):
/// - Incoming data (from client) must be a sequence of frames: [0x94, 0xC3][u16_be length][ToRadio bytes]
/// - Outgoing data (to client) are frames: [0x94, 0xC3][u16_be length][FromRadio bytes]
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
    this.port = 4403,
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

    _clientSub = client.listen(
        (data) async {
          await _onClientData(data);
        },
        onError: (e) => _log('Client error: $e'),
        onDone: () {
          _log('Client disconnected');
          _lastRemoteEndpoint = null;
          _connectedController.add(false);
          _client = null;
        });
  }

  Future<void> _onClientData(List<int> data) async {
    _log("packet");

    _rxBuffer.add(Uint8List.fromList(data));
    while (true) {
      final buf = _rxBuffer.toBytes();
      final remaining = buf.length;
      // Need at least 4 bytes for header (magic 2 + len 2)
      if (remaining < 4) break;

      if (buf[0] != 0x94) {
        _log('Desync: expected magic 0x94, got 0x${buf[0].toRadixString(16)}');
        _rxBuffer.clear();
        _rxBuffer.add(buf.sublist(1));
        continue;
      }

      if (buf[1] != 0xC3) {
        _log('Desync: expected magic 0xC3, got 0x${buf[1].toRadixString(16)}');
        _rxBuffer.clear();
        _rxBuffer.add(buf.sublist(2));
        continue;
      }

      final lenHi = buf[2];
      final lenLo = buf[3];
      final payloadLen = ((lenHi & 0xFF) << 8) | (lenLo & 0xFF);
      _log(
          'Header parsed: len=$payloadLen (0x${payloadLen.toRadixString(16)})');
      if (remaining < payloadLen + 4) {
        _log('Need ${payloadLen + 4 - remaining} more bytes');
        // Not enough bytes for payload yet
        break;
      }

      final start = 4;
      final end = start + payloadLen;
      final msgBytes = buf.sublist(start, end);
      _log('Got frame: $payloadLen bytes');
      _log('Frame hex ($payloadLen bytes):\n${_hexDump(msgBytes)}');
      await _handleToRadio(msgBytes);
      _rxBuffer.clear();
      _rxBuffer.add(buf.sublist(end));
    }
  }

  Future<void> _handleToRadio(List<int> msgBytes) async {
    try {
      final to = mesh.ToRadio.fromBuffer(msgBytes);
      switch (to.whichPayloadVariant()) {
        case mesh.ToRadio_PayloadVariant.wantConfigId:
          _log('Received wantConfigId: ${to.wantConfigId}');
          await _sendInitialConfigAndComplete(to.wantConfigId);
        case mesh.ToRadio_PayloadVariant.packet:
          if (to.hasPacket()) {
            final pkt = to.packet;
            final isEnc = pkt.whichPayloadVariant() ==
                mesh.MeshPacket_PayloadVariant.encrypted;
            final bytesToDump = isEnc ? pkt.encrypted : pkt.writeToBuffer();
            _log(
                'Received ${isEnc ? 'encrypted' : 'plain'} MeshPacket (len=${bytesToDump.length})');
            _log(
                'Packet hex (${bytesToDump.length} bytes):\n${_hexDump(bytesToDump)}');
            if (isEnc) {
              // Surface encrypted packet to app-facing stream
              _encryptedPacketController.add(pkt);
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

  String _hexDump(List<int> bytes, {int bytesPerLine = 16}) {
    if (bytes.isEmpty) return '';
    final sb = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      if (i > 0) sb.write(i % bytesPerLine == 0 ? '\n' : ' ');
      final b = bytes[i] & 0xFF;
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  Future<void> _sendInitialConfigAndComplete(int requestId) async {
    // MyNodeInfo
    final info = mesh.MyNodeInfo(
        myNodeNum: _nodeId ?? 0, deviceId: _uniqueId12, minAppVersion: 30200);
    final fr1 = mesh.FromRadio()..myInfo = info;
    await _sendFromRadio(fr1);

    // Also provide a NodeInfo entry for our own node number
    // Attach a basic User derived from our identity
    final idStr =
        '!${(_nodeId ?? 0).toRadixString(16).padLeft(8, '0').toLowerCase()}';

    final user = mesh.User(
      id: idStr,
      longName: "Virtual TODO",
      shortName: "V",
      publicKey: _publicKey,
      role: config.Config_DeviceConfig_Role.CLIENT_MUTE,
    );
    final selfNode = mesh.NodeInfo(
      num: _nodeId ?? 0,
      user: user,
      isFavorite: true,
      lastHeard: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    final frNode = mesh.FromRadio()..nodeInfo = selfNode;
    await _sendFromRadio(frNode);

    // Send all 8 channels (0..7). Include empty channels if not configured.
    for (int i = 0; i < 8; i++) {
      final settings = _channels[i];
      final ch = chpb.Channel(index: i, settings: settings);
      final fr = mesh.FromRadio()..channel = ch;
      await _sendFromRadio(fr);
    }

    // Config complete (echo request id)
    final frDone = mesh.FromRadio()..configCompleteId = requestId;
    await _sendFromRadio(frDone);
  }

  Future<void> _sendFromRadio(mesh.FromRadio msg) async {
    final bytes = msg.writeToBuffer();
    try {
      // Meshtastic framing: 0x94 0xC3 then 16-bit length (big-endian)
      _client?.add([0x94, 0xC3, ..._u16be(bytes.length)]);
      _client?.add(bytes);
      await _client?.flush();
      // Log JSON-serialized FromRadio for visibility
      try {
        final jsonText = jsonEncode(msg.toProto3Json());
        _log('Sent FromRadio json: $jsonText');
      } catch (_) {
        _log('Sent FromRadio: ${msg.whichPayloadVariant()}');
      }
    } catch (e) {
      _log('Failed to send FromRadio: $e');
    }
  }

  // (u32 helpers removed; using Meshtastic framing marker + u16 length)

  List<int> _u16be(int v) => [
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
