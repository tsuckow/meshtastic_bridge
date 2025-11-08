import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:cryptography/cryptography.dart' as crypto;

import '../generated/protos/meshtastic/mesh.pb.dart' as mesh;
import '../generated/protos/meshtastic/telemetry.pb.dart' as tel;
import '../generated/protos/meshtastic/portnums.pbenum.dart' as ports;
import 'managed_meshtastic_device.dart';
import 'virtual_meshtastic_device.dart';
import 'channel_hash_cache.dart';

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

  // Hard-coded initial DPI keys; base64 strings, typically single-byte PSK in base64.
  // "AQ==" => 0x01, "AA==" => 0x00
  final List<List<int>> _dpiKeys = <List<int>>[
    // effective PSKs will be derived at decrypt time
    base64Decode("AQ=="),
    base64Decode("AA=="),
  ];

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

      // Timestamp in seconds
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

      // Update per-sender counters (LRU limited) and per-minute device/sender counters
      _updateSenderHourlyCounts(pkt);
      _updateSenderMinuteCounts(pkt, nowSec);
      if (src == Source.deviceA) {
        _devACounter.bump(nowSec);
      } else if (src == Source.deviceB) {
        _devBCounter.bump(nowSec);
      }

      // Attempt deep packet inspection decrypt with known keys
      final decoded = await _attemptDpiDecrypt(pkt);
      if (decoded != null) {
        _handleDecodedForStats(src, decoded);
      }

      if (!await _allow(src, pkt)) {
        _log('Filter blocked packet from $src');
        return;
      }

      // Forward to all other endpoints
      final futures = <Future<void>>[];

      // Limit forwarding between managed devices for packets we can't decrypt
      // or non-TEXT_MESSAGE_APP packets we could decrypt. Always send to virtual.
      final subjectToLimit = (decoded == null) ||
          (decoded.hasDecoded() &&
              decoded.decoded.portnum != ports.PortNum.TEXT_MESSAGE_APP);
      switch (src) {
        case Source.deviceA:
          if (deviceB?.isConnected == true) {
            if (!subjectToLimit || _allowCrossManaged(nowSec, src, pkt)) {
              futures.add(deviceB!.sendMeshPacket(pkt));
            } else {
              // Sampling drop for cross-managed forwarding
              _devADroppedCounter.bump(nowSec);
            }
          }
          if (virtualDevice?.isClientConnected == true) {
            futures.add(virtualDevice!.handlePacketFromHub(pkt));
          }
          break;
        case Source.deviceB:
          if (deviceA?.isConnected == true) {
            if (!subjectToLimit || _allowCrossManaged(nowSec, src, pkt)) {
              futures.add(deviceA!.sendMeshPacket(pkt));
            } else {
              // Sampling drop for cross-managed forwarding
              _devBDroppedCounter.bump(nowSec);
            }
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
      // Notify listeners so UI can refresh packet/dropped counts
      _statsController.add(null);
    } catch (e) {
      _log('Forward error from $src: $e');
    }
  }

  // Attempt to decrypt packet with DPI keys using firmware-compatible AES-CTR.
  Future<mesh.MeshPacket?> _attemptDpiDecrypt(mesh.MeshPacket pkt) async {
    try {
      if (!pkt.hasEncrypted()) return null;
      final enc = Uint8List.fromList(pkt.encrypted);
      if (enc.isEmpty) return null;
      final from = pkt.hasFrom() ? pkt.from : 0;
      final id = pkt.hasId() ? pkt.id : 0;
      if (id == 0) return null; // nonce needs id

      // Build nonce (LE): [LE64(id)][LE32(from)][LE32(0)]
      Uint8List le32(int v) => Uint8List.fromList(
            [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF],
          );
      Uint8List le64from32(int v32) => Uint8List.fromList([
            v32 & 0xFF,
            (v32 >> 8) & 0xFF,
            (v32 >> 16) & 0xFF,
            (v32 >> 24) & 0xFF,
            0,
            0,
            0,
            0,
          ]);
      final nonce16 = Uint8List(16)
        ..setRange(0, 8, le64from32(id))
        ..setRange(8, 12, le32(from))
        ..setRange(12, 16, const [0, 0, 0, 0]);

      for (final k in _dpiKeys) {
        final eff = ChannelHashCache.effectivePsk(k);
        final use256 = eff.length >= 32;
        final aesCtr = use256
            ? crypto.AesCtr.with256bits(macAlgorithm: crypto.MacAlgorithm.empty)
            : crypto.AesCtr.with128bits(
                macAlgorithm: crypto.MacAlgorithm.empty);
        try {
          final box =
              crypto.SecretBox(enc, nonce: nonce16, mac: crypto.Mac.empty);
          final clear =
              await aesCtr.decrypt(box, secretKey: crypto.SecretKey(eff));
          // Try parse as Data; if fails, ignore
          try {
            final data = mesh.Data.fromBuffer(clear);
            final decodedPkt = mesh.MeshPacket(
              from: from,
              to: pkt.hasTo() ? pkt.to : null,
              id: id,
              channel: pkt.channel,
              hopLimit: pkt.hasHopLimit() ? pkt.hopLimit : null,
              hopStart: pkt.hasHopStart() ? pkt.hopStart : null,
              rxTime: pkt.hasRxTime() ? pkt.rxTime : null,
              decoded: data,
            );
            _log(
                'DPI decrypt success: from=${from.toRadixString(16)} id=${id.toRadixString(16)} port=${data.portnum.name}');
            return decodedPkt; // stop at first success
          } catch (_) {
            // not a valid Data for this key
          }
        } catch (_) {
          // wrong key/nonce, continue
        }
      }
    } catch (e) {
      _log('DPI decrypt error: $e');
    }
    return null;
  }

  // --- Per-sender rolling 24-hour packet counters with LRU size 10k ---
  static const int _maxSenders = 10000;
  static const int _hoursWindow = 24;
  final Map<int, _SenderStats> _senderStats = <int, _SenderStats>{};
  final List<int> _lruOrder = <int>[]; // most recent at end

  void _updateSenderHourlyCounts(mesh.MeshPacket pkt) {
    final from = pkt.hasFrom() ? pkt.from : 0;
    if (from == 0) return;
    final now = DateTime.now().toUtc();
    final hourKey = DateTime.utc(now.year, now.month, now.day, now.hour);
    var stats = _senderStats[from];
    if (stats == null) {
      stats = _SenderStats();
      _senderStats[from] = stats;
      _lruOrder.add(from);
      if (_lruOrder.length > _maxSenders) {
        final evict = _lruOrder.removeAt(0);
        _senderStats.remove(evict);
      }
    } else {
      // move to MRU
      _lruOrder.remove(from);
      _lruOrder.add(from);
    }
    stats.bump(hourKey);
  }

  Map<int, List<int>> getSenderCountsLast24h() {
    final now = DateTime.now().toUtc();
    final List<DateTime> hours = List.generate(
        _hoursWindow,
        (i) => DateTime.utc(now.year, now.month, now.day, now.hour)
            .subtract(Duration(hours: i)));
    final out = <int, List<int>>{};
    _senderStats.forEach((from, s) {
      out[from] = hours.map((h) => s.countForHour(h)).toList();
    });
    return out;
  }

  void clearSenderStats() {
    _senderStats.clear();
    _lruOrder.clear();
  }

  // --- DeviceMetrics rolling channel utilization tracking ---
  final List<double> _dev1Util = <double>[]; // last 10
  final List<double> _dev2Util = <double>[]; // last 10
  final _statsController = StreamController<void>.broadcast();
  Stream<void> get statsChanged => _statsController.stream;
  double get device1AvgUtil => _avg(_dev1Util);
  double get device2AvgUtil => _avg(_dev2Util);

  // --- Per-device last-minute counters (minute-resolution) ---
  final _devACounter = _MinuteRing();
  final _devBCounter = _MinuteRing();
  final _devADroppedCounter = _MinuteRing();
  final _devBDroppedCounter = _MinuteRing();

  int get device1PacketsLastMinute {
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    return _devACounter.sumLastMinutes(nowSec, 1);
  }

  int get device2PacketsLastMinute {
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    return _devBCounter.sumLastMinutes(nowSec, 1);
  }

  int get device1DroppedLastMinute {
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    return _devADroppedCounter.sumLastMinutes(nowSec, 1);
  }

  int get device2DroppedLastMinute {
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    return _devBDroppedCounter.sumLastMinutes(nowSec, 1);
  }

  // Update per-sender minute ring (for last-hour avg-per-minute)
  void _updateSenderMinuteCounts(mesh.MeshPacket pkt, int nowSec) {
    final from = pkt.hasFrom() ? pkt.from : 0;
    if (from == 0) return;
    final s = _senderStats[from];
    if (s != null) s.minuteRing.bump(nowSec);
  }

  // RNG for sampling decisions
  final Random _rng = Random();

  // Decide if cross-managed forwarding should be allowed under rate limit
  bool _allowCrossManaged(int nowSec, Source src, mesh.MeshPacket pkt) {
    // Count from the device in the last minute
    final dm = (src == Source.deviceA
            ? _devACounter
            : _devBCounter)
        .sumLastMinutes(nowSec, 1);
    // Sender avg-per-minute over last 60 minutes
    final from = pkt.hasFrom() ? pkt.from : 0;
    final s = _senderStats[from];
    final senderLastHour = s?.minuteRing.sumLastMinutes(nowSec, 60) ?? 0;
    final spm = senderLastHour / 60.0;

    // Build denominator: scale with device load vs 30/min and sender activity
    final deviceFactor = (dm <= 30) ? 1 : ((dm + 29) ~/ 30); // ceil(dm/30)
    final senderFactor = spm <= 1.0 ? 1 : spm.ceil();
    final denom = deviceFactor * senderFactor;
    if (denom <= 1) return true;
    return _rng.nextInt(denom) == 0;
  }

  void _handleDecodedForStats(Source src, mesh.MeshPacket decodedPkt) {
    if (!decodedPkt.hasDecoded()) return;
    final data = decodedPkt.decoded;
    // TELEMETRY_APP port holds Telemetry
    // Port number constant lives in generated pbenum; if not imported here, rely on numeric: 67
    const int telemetryPortNum = 67; // PortNum.TELEMETRY_APP
    if (data.portnum.value != telemetryPortNum) return;
    try {
      final t = tel.Telemetry.fromBuffer(data.payload);
      if (t.hasDeviceMetrics() && t.deviceMetrics.hasChannelUtilization()) {
        final v = t.deviceMetrics.channelUtilization;
        final list = src == Source.deviceA ? _dev1Util : _dev2Util;
        list.add(v);
        while (list.length > 10) list.removeAt(0);
        _statsController.add(null);
      }
    } catch (_) {
      // ignore parse errors
    }
  }

  double _avg(List<double> xs) {
    if (xs.isEmpty) return 0;
    var s = 0.0;
    for (final v in xs) s += v;
    return s / xs.length;
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

class _SenderStats {
  // Use a map keyed by UTC hour (DateTime at hour precision) to counts
  final Map<DateTime, int> _hourCounts = <DateTime, int>{};
  final _MinuteRing minuteRing = _MinuteRing();

  void bump(DateTime hourKey) {
    // prune entries older than 24 hours from hourKey
    final cutoff = hourKey.subtract(const Duration(hours: 24));
    _hourCounts.removeWhere((k, _) => k.isBefore(cutoff));
    _hourCounts.update(hourKey, (v) => v + 1, ifAbsent: () => 1);
  }

  int countForHour(DateTime hourKey) {
    return _hourCounts[hourKey] ?? 0;
  }
}

// Minute-resolution ring counter for last N minutes queries (default supports >= 60)
class _MinuteRing {
  final Map<int, int> _counts = <int, int>{}; // minuteKey -> count

  void bump(int nowSec) {
    final m = nowSec ~/ 60;
    _counts.update(m, (v) => v + 1, ifAbsent: () => 1);
    // prune older than 2 hours to keep small
    final cutoff = m - 120;
    _counts.removeWhere((k, _) => k < cutoff);
  }

  int sumLastMinutes(int nowSec, int minutes) {
    final m = nowSec ~/ 60;
    final start = m - minutes + 1;
    var sum = 0;
    for (int k = start; k <= m; k++) {
      sum += _counts[k] ?? 0;
    }
    return sum;
  }
}

enum Source { deviceA, deviceB, virtual }
