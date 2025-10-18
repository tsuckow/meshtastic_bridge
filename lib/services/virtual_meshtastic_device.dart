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
import '../generated/protos/meshtastic/portnums.pbenum.dart' as ports;
import '../generated/protos/meshtastic/admin.pb.dart' as admin;
import 'channel_hash_cache.dart';

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
  mesh.User? _selfUser; // our current user/owner identity
  Uint8List? _adminSessionPasskey; // session passkey for admin replies

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

  // Channel hash cache (XOR-based) for up to 8 channels
  final ChannelHashCache _chanHashCache = ChannelHashCache();

  // Deduplication of packets received from hub (by MeshPacket.id) over a time window
  // Maps packet id -> last seen epoch seconds
  final Map<int, int> _recentHubPacketIds = <int, int>{};
  static const int _dedupeWindowSecs = 10 * 60; // 10 minutes

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
        id: 1,
      );
      _channels[1] = chpb.ChannelSettings(
        name: 'LongFast',
        psk: base64Decode('AQ=='),
        id: 2,
      );
      _channels[2] = chpb.ChannelSettings(
        name: 'MeshOregon',
        psk: base64Decode('AQ=='),
        id: 3,
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

  bool _isProcessingData = false;
  Future<void> _onClientData(List<int> data) async {
    //_log("packet");

    _rxBuffer.add(Uint8List.fromList(data));

    if (_isProcessingData) return;
    _isProcessingData = true;
    try {
      while (true) {
        final buf = _rxBuffer.toBytes();
        final remaining = buf.length;
        // Need at least 4 bytes for header (magic 2 + len 2)
        if (remaining < 4) break;

        if (buf[0] != 0x94) {
          _log(
              'Desync: expected magic 0x94, got 0x${buf[0].toRadixString(16)}');
          _rxBuffer.clear();
          _rxBuffer.add(buf.sublist(1));
          continue;
        }

        if (buf[1] != 0xC3) {
          _log(
              'Desync: expected magic 0xC3, got 0x${buf[1].toRadixString(16)}');
          _rxBuffer.clear();
          _rxBuffer.add(buf.sublist(2));
          continue;
        }

        final lenHi = buf[2];
        final lenLo = buf[3];
        final payloadLen = ((lenHi & 0xFF) << 8) | (lenLo & 0xFF);
        // _log(
        //     'Header parsed: len=$payloadLen (0x${payloadLen.toRadixString(16)})');
        if (remaining < payloadLen + 4) {
          //_log('Need ${payloadLen + 4 - remaining} more bytes');
          // Not enough bytes for payload yet
          break;
        }

        //Atomic Operation
        final start = 4;
        final end = start + payloadLen;
        final msgBytes = buf.sublist(start, end);
        _rxBuffer.clear();
        _rxBuffer.add(buf.sublist(end));
        //End Atomic Operation
        //_log('Got frame: $payloadLen bytes');
        await _handleToRadio(msgBytes);
      }
    } finally {
      _isProcessingData = false;
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

            // Always acknowledge ToRadio.packet with a queueStatus response
            try {
              final q = mesh.QueueStatus(
                res: 0, // OK
                free: 7, // pretend there are free entries
                maxlen: 8, // pretend total queue size
                meshPacketId: pkt.hasId() ? pkt.id : 0,
              );
              _log(
                  'Replying queueStatus: id=0x${q.meshPacketId.toRadixString(16)} free=${q.free}/${q.maxlen}');
              await _sendFromRadio(mesh.FromRadio()..queueStatus = q);
            } catch (e) {
              _log('Failed to send queueStatus: $e');
            }

            final isEnc = pkt.whichPayloadVariant() ==
                mesh.MeshPacket_PayloadVariant.encrypted;
            final bytesToDump = isEnc ? pkt.encrypted : pkt.writeToBuffer();
            _log(
                'Received ${isEnc ? 'encrypted' : 'plain'} MeshPacket (len=${bytesToDump.length})');
            _log('Packet ${jsonEncode(pkt.toProto3Json())}');
            // Handle Admin app messages (decoded Data on ADMIN_APP port)
            if (!isEnc && pkt.hasDecoded() && pkt.decoded.hasPayload()) {
              final data = pkt.decoded;
              if (data.portnum == ports.PortNum.ADMIN_APP) {
                await _handleAdminData(data);
                break;
              }
              // Encrypt selected decoded payloads and forward to hub
              if (data.portnum == ports.PortNum.TEXT_MESSAGE_APP ||
                  data.portnum == ports.PortNum.NODEINFO_APP ||
                  data.portnum == ports.PortNum.TRACEROUTE_APP) {
                try {
                  final encPkt = await _encryptForHub(pkt);
                  if (encPkt != null) {
                    _log(
                        'Forwarding encrypted to hub; chan=${encPkt.channel} id=0x${(encPkt.hasId() ? encPkt.id : 0).toRadixString(16)}');
                    _encryptedPacketController.add(encPkt);
                  } else {
                    _log(
                        'Encryption skipped: no channel or PSK for index ${pkt.channel}');
                  }
                } catch (e) {
                  _log('Encrypt-to-hub error: $e');
                }
              }
            }
            if (isEnc) {
              // Surface encrypted packet to app-facing stream
              _encryptedPacketController.add(pkt);
            }
          }
        case mesh.ToRadio_PayloadVariant.disconnect:
          _log('Received disconnect request');
          _client?.destroy();
        case mesh.ToRadio_PayloadVariant.setPromiscuous:
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

  Future<mesh.MeshPacket?> _encryptForHub(mesh.MeshPacket decodedPkt) async {
    if (!decodedPkt.hasDecoded()) return null;
    final idx = decodedPkt.channel; // local channel index
    final settings = _channels[idx];
    if (settings == null || !settings.hasPsk()) return null;

    final name = settings.hasName() ? settings.name : '';
    final psk = List<int>.from(settings.psk);
    final hashByte = _chanHashCache.getHash(name, psk) & 0xFF;

    final from = _nodeId ?? 0;
    final id = decodedPkt.hasId() && decodedPkt.id != 0
        ? decodedPkt.id
        : Random.secure().nextInt(0x7FFFFFFF);

    // Build nonce (16 bytes LE): [LE64(id)][LE32(from)][LE32(0)]
    final id64le = _le64from32(id);
    final from32le = _le32(from);
    final nonce16 = Uint8List(16)
      ..setRange(0, 8, id64le)
      ..setRange(8, 12, from32le)
      ..setRange(12, 16, const [0, 0, 0, 0]);
    //_log('D Nonce $nonce16');

    final effPsk = ChannelHashCache.effectivePsk(psk);
    final use256 = effPsk.length >= 32;

    final aesCtr = use256
        ? crypto.AesCtr.with256bits(macAlgorithm: crypto.MacAlgorithm.empty)
        : crypto.AesCtr.with128bits(macAlgorithm: crypto.MacAlgorithm.empty);

    final clear = decodedPkt.decoded.writeToBuffer();
    // _log(
    //     'Encrypting for hub AES-CTR${use256 ? 256 : 128}: idx=$idx hash=0x${hashByte.toRadixString(16)} nonce=${_hexDump(nonce16)} clearLen=${clear.length}');
    final box = await aesCtr.encrypt(
      clear,
      secretKey: crypto.SecretKey(effPsk),
      nonce: nonce16,
    );
    final ct = box.cipherText;

    // Build encrypted MeshPacket for hub forwarding; channel is hash byte
    final out = decodedPkt.deepCopy();
    out.channel = hashByte;
    out.from = from;
    out.id = id;
    out.hopLimit = 7;
    out.hopStart = 7;
    out.clearDecoded();
    out.encrypted = ct;

    return out;
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
        hwModel: mesh.HardwareModel.PRIVATE_HW);
    _selfUser = user;
    final selfNode = mesh.NodeInfo(
      num: _nodeId ?? 0,
      user: user,
      isFavorite: true,
      lastHeard: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    final frNode = mesh.FromRadio()..nodeInfo = selfNode;
    await _sendFromRadio(frNode);

    // Send device metadata after node info
    final meta = mesh.DeviceMetadata(
      firmwareVersion: '2.7.0virtual',
      deviceStateVersion: 24,
      canShutdown: false,
      hasWifi: false,
      hasBluetooth: false,
      hasEthernet: true,
      role: config.Config_DeviceConfig_Role.CLIENT_MUTE,
      positionFlags: 0,
      hwModel: mesh.HardwareModel.PRIVATE_HW,
      hasPKC: true,
      excludedModules: 20864,
    );
    final frMeta = mesh.FromRadio()..metadata = meta;
    await _sendFromRadio(frMeta);

    // Send all 8 channels (0..7). Include empty channels if not configured.
    for (int i = 0; i < 8; i++) {
      final settings = _channels[i];
      final ch = chpb.Channel(
        index: i,
        settings: settings ?? chpb.ChannelSettings(),
        role: i == 0
            ? chpb.Channel_Role.PRIMARY
            : (settings != null
                ? chpb.Channel_Role.SECONDARY
                : chpb.Channel_Role.DISABLED),
      );
      final fr = mesh.FromRadio()..channel = ch;
      await _sendFromRadio(fr);
    }

    // Config complete (echo request id)
    final frDone = mesh.FromRadio()..configCompleteId = requestId;
    await _sendFromRadio(frDone);

    // // After config complete, send a sample decoded text message on channel 0 from a test node
    // // Build a Data payload for TEXT_MESSAGE_APP with UTF-8 text
    // final text = 'Hello from virtual test node';
    // final data = mesh.Data(
    //   portnum: ports.PortNum.TEXT_MESSAGE_APP,
    //   payload: utf8.encode(text),
    //   wantResponse: false,
    // );
    // // Construct a MeshPacket as if received from a neighbor test node
    // final testFrom = (_nodeId ?? 0) ^ 0x010203; // stable non-equal test node id
    // final pkt = mesh.MeshPacket(
    //   from: testFrom,
    //   to: 0xFFFFFFFF, // broadcast
    //   channel: 0, // primary channel
    //   decoded: data,
    //   id: Random().nextInt(0x7FFFFFFF),
    //   rxTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    //   hopLimit: 0,
    //   wantAck: false,
    // );
    // final frPkt = mesh.FromRadio()..packet = pkt;
    // await _sendFromRadio(frPkt);
  }

  // Parse and respond to ADMIN_APP messages carried in decoded Data frames.
  Future<void> _handleAdminData(mesh.Data data) async {
    try {
      final msg = admin.AdminMessage.fromBuffer(data.payload);
      // Log full AdminMessage payload as JSON for visibility
      try {
        _log('ADMIN_APP json: ${jsonEncode(msg.toProto3Json())}');
      } catch (_) {
        // ignore JSON serialization errors
      }
      _log('ADMIN_APP received: ${msg.whichPayloadVariant()}');
      switch (msg.whichPayloadVariant()) {
        case admin.AdminMessage_PayloadVariant.getChannelRequest:
          final idx = msg.getChannelRequest - 1;
          final settings = _channels[idx] ?? chpb.ChannelSettings();
          final ch = chpb.Channel(
            index: idx,
            settings: settings,
            role: idx == 0
                ? chpb.Channel_Role.PRIMARY
                : (settings.hasName() || settings.hasPsk()
                    ? chpb.Channel_Role.SECONDARY
                    : chpb.Channel_Role.DISABLED),
          );
          final resp = admin.AdminMessage(
            getChannelResponse: ch,
            sessionPasskey: _ensureAdminSessionPasskey(),
          );
          await _sendAdminResponse(resp);
        case admin.AdminMessage_PayloadVariant.getOwnerRequest:
          final owner = _selfUser ?? mesh.User();
          final resp = admin.AdminMessage(
            getOwnerResponse: owner,
            sessionPasskey: _ensureAdminSessionPasskey(),
          );
          await _sendAdminResponse(resp);
        case admin.AdminMessage_PayloadVariant.getConfigRequest:
          // Return specific config section based on request type
          final req = msg.getConfigRequest;
          config.Config cfg;
          if (req == admin.AdminMessage_ConfigType.LORA_CONFIG) {
            final lora = config.Config_LoRaConfig(
              usePreset: true,
              modemPreset: config.Config_LoRaConfig_ModemPreset.LONG_FAST,
              region: config.Config_LoRaConfig_RegionCode.US,
              hopLimit: 7,
              txEnabled: true,
              txPower: 30,
              channelNum: 0,
            );
            cfg = (config.Config()..lora = lora);
          } else {
            // Default to Device Config for other/unspecified requests
            final dev = config.Config_DeviceConfig(
              role: config.Config_DeviceConfig_Role.CLIENT_MUTE,
            );
            cfg = (config.Config()..device = dev);
          }
          final resp = admin.AdminMessage(
            getConfigResponse: cfg,
            sessionPasskey: _ensureAdminSessionPasskey(),
          );
          await _sendAdminResponse(resp);
        case admin.AdminMessage_PayloadVariant.getDeviceMetadataRequest:
          List<mesh.ExcludedModules> excluded = [
            mesh.ExcludedModules.EXCLUDED_NONE
            // mesh.ExcludedModules.BLUETOOTH_CONFIG,
            // mesh.ExcludedModules.AUDIO_CONFIG,
            // mesh.ExcludedModules.AMBIENTLIGHTING_CONFIG,
            // mesh.ExcludedModules.CANNEDMSG_CONFIG,
            // mesh.ExcludedModules.DETECTIONSENSOR_CONFIG,
            // mesh.ExcludedModules.EXTNOTIF_CONFIG,
            // mesh.ExcludedModules.MQTT_CONFIG,
            // mesh.ExcludedModules.NEIGHBORINFO_CONFIG,
            // mesh.ExcludedModules.NETWORK_CONFIG,
            // mesh.ExcludedModules.PAXCOUNTER_CONFIG,
            // mesh.ExcludedModules.RANGETEST_CONFIG,
            // mesh.ExcludedModules.REMOTEHARDWARE_CONFIG,
            // mesh.ExcludedModules.SERIAL_CONFIG,
            // mesh.ExcludedModules.STOREFORWARD_CONFIG,
            // mesh.ExcludedModules.TELEMETRY_CONFIG,
          ];
          final meta = mesh.DeviceMetadata(
            firmwareVersion: '2.7.0virtual',
            deviceStateVersion: 24,
            canShutdown: false,
            hasWifi: false,
            hasBluetooth: false,
            hasEthernet: true,
            role: config.Config_DeviceConfig_Role.CLIENT_MUTE,
            positionFlags: 0,
            hwModel: mesh.HardwareModel.PRIVATE_HW,
            hasPKC: true,
            // Modules to /include/ that are excluded by default
            excludedModules: excluded.fold<int>(
                mesh.ExcludedModules.EXCLUDED_NONE.value,
                (acc, mod) => acc | mod.value),
          );
          final resp = admin.AdminMessage(
            getDeviceMetadataResponse: meta,
            sessionPasskey: _ensureAdminSessionPasskey(),
          );
          await _sendAdminResponse(resp);
        case admin.AdminMessage_PayloadVariant.setChannel:
          if (!_validateAdminPasskey(msg.sessionPasskey)) {
            _log('ADMIN_APP setChannel rejected: bad sessionPasskey');
            break;
          }
          final newCh = msg.setChannel;
          final idx = newCh.index;
          _channels[idx] = newCh.settings;
          // Emit FromRadio.channel update
          final out = chpb.Channel(
            index: idx,
            settings: newCh.settings,
            role: newCh.role,
          );
          await _sendFromRadio(mesh.FromRadio()..channel = out);
          // Update hash cache
          final name = out.settings.hasName() ? out.settings.name : '';
          final psk = out.settings.hasPsk()
              ? List<int>.from(out.settings.psk)
              : <int>[];
          _chanHashCache.getHash(name, psk);
        case admin.AdminMessage_PayloadVariant.setOwner:
          if (!_validateAdminPasskey(msg.sessionPasskey)) {
            _log('ADMIN_APP setOwner rejected: bad sessionPasskey');
            break;
          }
          _selfUser = msg.setOwner;
          // Emit updated NodeInfo
          final selfNode = mesh.NodeInfo(
            num: _nodeId ?? 0,
            user: _selfUser,
            isFavorite: true,
            lastHeard: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          );
          await _sendFromRadio(mesh.FromRadio()..nodeInfo = selfNode);
        case admin.AdminMessage_PayloadVariant.beginEditSettings:
        case admin.AdminMessage_PayloadVariant.commitEditSettings:
        case admin.AdminMessage_PayloadVariant.getModuleConfigRequest:
        case admin.AdminMessage_PayloadVariant.setConfig:
        case admin.AdminMessage_PayloadVariant.setModuleConfig:
        case admin.AdminMessage_PayloadVariant
              .getCannedMessageModuleMessagesRequest:
        case admin.AdminMessage_PayloadVariant.getRingtoneRequest:
        case admin.AdminMessage_PayloadVariant.getUiConfigRequest:
        case admin.AdminMessage_PayloadVariant.getDeviceConnectionStatusRequest:
        case admin.AdminMessage_PayloadVariant.keyVerification:
        case admin.AdminMessage_PayloadVariant.factoryResetDevice:
        case admin.AdminMessage_PayloadVariant.rebootSeconds:
        case admin.AdminMessage_PayloadVariant.shutdownSeconds:
        case admin.AdminMessage_PayloadVariant.factoryResetConfig:
        case admin.AdminMessage_PayloadVariant.nodedbReset:
        case admin.AdminMessage_PayloadVariant.notSet:
        default:
          _log('ADMIN_APP not implemented for ${msg.whichPayloadVariant()}');
      }
    } catch (e) {
      _log('Failed to parse ADMIN_APP payload: $e');
    }
  }

  List<int> _ensureAdminSessionPasskey() {
    if (_adminSessionPasskey == null || _adminSessionPasskey!.isEmpty) {
      final rng = Random.secure();
      _adminSessionPasskey =
          Uint8List.fromList(List<int>.generate(16, (_) => rng.nextInt(256)));
    }
    return _adminSessionPasskey!;
  }

  bool _validateAdminPasskey(List<int> provided) {
    if (_adminSessionPasskey == null) return false;
    if (provided.length != _adminSessionPasskey!.length) return false;
    for (int i = 0; i < provided.length; i++) {
      if ((provided[i] & 0xFF) != (_adminSessionPasskey![i] & 0xFF)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _sendAdminResponse(admin.AdminMessage resp) async {
    try {
      // Log the outgoing AdminMessage as JSON
      try {
        _log('ADMIN_APP response json: ${jsonEncode(resp.toProto3Json())}');
      } catch (_) {
        // ignore JSON serialization errors
      }
      final data = mesh.Data(
        portnum: ports.PortNum.ADMIN_APP,
        payload: resp.writeToBuffer(),
      );
      final pkt = mesh.MeshPacket(
        decoded: data,
      );
      await _sendFromRadio(mesh.FromRadio()..packet = pkt);
    } catch (e) {
      _log('Failed to send ADMIN_APP response: $e');
    }
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

  /// Called by the bridging hub when a MeshPacket should be emitted to the
  /// connected TCP client as a FromRadio.packet.
  Future<void> handlePacketFromHub(mesh.MeshPacket pkt) async {
    // Drop duplicates by id within the dedupe window
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _recentHubPacketIds
        .removeWhere((_, ts) => (nowSec - ts) > _dedupeWindowSecs);
    final pktId = pkt.hasId() ? pkt.id : 0;
    if (pktId != 0) {
      if (_recentHubPacketIds.containsKey(pktId)) {
        _log('Drop duplicate hub packet id=0x${pktId.toRadixString(16)}');
        return; // duplicate, ignore
      }
      _recentHubPacketIds[pktId] = nowSec;
    }

    // If this is an encrypted packet, see if we can identify the channel by hash
    // and attempt to decrypt. If decryption succeeds, emit the decoded variant
    // with the local channel index; otherwise, forward as-is.
    if (pkt.whichPayloadVariant() == mesh.MeshPacket_PayloadVariant.encrypted) {
      final hashByte = pkt.channel & 0xFF;
      final match = _findChannelByHash(hashByte);
      if (match != null) {
        _log('Decrypt channel hash: ${pkt.channel}');
        final idx = match.key;
        final settings = match.value;
        try {
          final data = await _tryDecrypt(pkt, settings);
          if (data != null) {
            // Special-case self-origin packets: convert to a ROUTING_APP notice with requestId
            final fromNode = pkt.hasFrom() ? pkt.from : 0;
            if (_nodeId != null && fromNode == _nodeId) {
              final routingData = mesh.Data(
                portnum: ports.PortNum.ROUTING_APP,
                payload: Uint8List(0),
                requestId: pktId,
              );
              final routingPkt = mesh.MeshPacket(
                from: fromNode,
                to: pkt.hasTo() ? pkt.to : 0,
                channel: idx,
                decoded: routingData,
                id: Random().nextInt(0x7FFFFFFF),
                rxTime: pkt.hasRxTime() ? pkt.rxTime : null,
                hopLimit: pkt.hasHopLimit() ? pkt.hopLimit : null,
                hopStart: pkt.hasHopStart() ? pkt.hopStart : null,
              );
              await _sendFromRadio(mesh.FromRadio()..packet = routingPkt);
              return;
            }

            // Normal path: forward decrypted decoded packet
            final decodedPkt = pkt.deepCopy();
            decodedPkt.clearEncrypted();
            decodedPkt.decoded = data;
            decodedPkt.channel = idx; // for decoded, channel is local index

            await _sendFromRadio(mesh.FromRadio()..packet = decodedPkt);
            return;
          }
        } catch (e) {
          _log('Decrypt attempt failed: $e');
        }
      }
    }

    // Default: forward packet unchanged
    await _sendFromRadio(mesh.FromRadio()..packet = pkt);
  }

  MapEntry<int, chpb.ChannelSettings>? _findChannelByHash(int hashByte) {
    for (final entry in _channels.entries) {
      final settings = entry.value;
      final name = settings.hasName() ? settings.name : '';
      final psk = settings.hasPsk() ? List<int>.from(settings.psk) : <int>[];
      final h = _chanHashCache.getHash(name, psk);
      if ((h & 0xFF) == (hashByte & 0xFF)) {
        return MapEntry(entry.key, settings);
      }
    }
    return null;
  }

  Future<mesh.Data?> _tryDecrypt(
      mesh.MeshPacket pkt, chpb.ChannelSettings settings) async {
    if (!pkt.hasEncrypted()) return null;
    //_log("Decrypt for ${settings.name}");
    final enc = Uint8List.fromList(pkt.encrypted);
    if (enc.isEmpty) {
      _log('Decrypt skipped: empty ciphertext');
      return null; // must have some ciphertext
    }

    final from = pkt.hasFrom() ? pkt.from : 0;
    final id = pkt.hasId() ? pkt.id : 0;

    // Prepare key material candidates using ChannelHashCache helpers
    final rawPsk = settings.hasPsk() ? List<int>.from(settings.psk) : <int>[];
    final effPsk = ChannelHashCache.effectivePsk(rawPsk);

    // First, try AES-CTR as implemented in Meshtastic firmware.
    // Nonce layout (16 bytes, little-endian):
    // [0..7]  = LE64(packetId)
    // [8..11] = LE32(fromNode)
    // [12..15]= LE32(0) (counter starts from 0; firmware sets counter size to 4)
    final id64le = _le64from32(id);
    final from32le = _le32(from);
    final nonce16 = Uint8List(16)
      ..setRange(0, 8, id64le)
      ..setRange(8, 12, from32le)
      ..setRange(12, 16, const [0, 0, 0, 0]);
    //_log('E Nonce $nonce16');

    // Choose AES-CTR key size based on effective PSK size (firmware selects AES128 vs AES256 by key length)
    final use256 = effPsk.length >= 32;
    final aesCtr = use256
        ? crypto.AesCtr.with256bits(macAlgorithm: crypto.MacAlgorithm.empty)
        : crypto.AesCtr.with128bits(macAlgorithm: crypto.MacAlgorithm.empty);
    // _log(
    //     'AES-CTR${use256 ? 256 : 128} try: nonce=${_hexDump(nonce16)} ctLen=${enc.length} pskLen=${effPsk.length} from=0x${from.toRadixString(16)} id=0x${id.toRadixString(16)}');
    try {
      final box = crypto.SecretBox(enc, nonce: nonce16, mac: crypto.Mac.empty);
      final secretKey = crypto.SecretKey(effPsk);
      final clear = await aesCtr.decrypt(box, secretKey: secretKey);
      try {
        return mesh.Data.fromBuffer(clear);
      } catch (e) {
        _log('AES-CTR parse Data failed (len=${clear.length}): $e');
      }
    } catch (e) {
      _log('AES-CTR decrypt error: $e');
    }
    _log(
        'Decrypt failed: AES-CTR${use256 ? 256 : 128} could not produce valid Data for ${settings.hasName() ? settings.name : '(unnamed)'}; ctLen=${enc.length} pskLen=${effPsk.length} from=0x${from.toRadixString(16)} id=0x${id.toRadixString(16)}');
    return null;
  }

  // removed unused _expandKey; using ChannelHashCache.expandKey instead

  Uint8List _le32(int v) => Uint8List.fromList([
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ]);

  // Build 8 little-endian bytes from a 32-bit id (upper 32 bits zero)
  Uint8List _le64from32(int v32) => Uint8List.fromList([
        v32 & 0xFF,
        (v32 >> 8) & 0xFF,
        (v32 >> 16) & 0xFF,
        (v32 >> 24) & 0xFF,
        0,
        0,
        0,
        0,
      ]);

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
