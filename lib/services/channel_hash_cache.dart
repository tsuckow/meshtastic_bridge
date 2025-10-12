import 'dart:convert';

/// Represents a cached channel hash entry.
class ChannelHashEntry {
  ChannelHashEntry({
    required this.name,
    required List<int> psk,
    required this.hash,
  }) : psk = List<int>.from(psk, growable: false);

  final String name;
  final List<int> psk;
  final int hash; // 0-255
}

/// FIFO cache (capacity 8) computing a one-byte channel hash as XOR of
/// UTF-8 name bytes and all PSK bytes.
class ChannelHashCache {
  static const int capacity = 8;
  final List<ChannelHashEntry> _entries = <ChannelHashEntry>[];

  // Default 15-byte prefix used by firmware when a single-byte PSK is provided.
  // Effective 16-byte PSK becomes: defaultPrefix + [providedByte].
  static const List<int> _defaultPskPrefix = <int>[
    0xd4,
    0xf1,
    0xbb,
    0x3a,
    0x20,
    0x29,
    0x07,
    0x59,
    0xf0,
    0xbc,
    0xff,
    0xab,
    0xcf,
    0x4e,
    0x69,
  ];

  /// Returns the effective PSK bytes used by Meshtastic firmware for hashing
  /// and symmetric crypto.
  ///
  /// - If [psk] has length 1, returns the 16-byte sequence constructed by
  ///   appending the provided byte to the firmware default prefix.
  /// - Otherwise returns [psk] as-is (no copy).
  static List<int> effectivePsk(List<int> psk) {
    if (psk.length == 1) {
      return <int>[..._defaultPskPrefix, psk[0] & 0xFF];
    }
    return psk;
  }

  /// Expands the PSK to exactly [len] bytes by repeating or truncating
  /// after applying [effectivePsk] rules.
  static List<int> expandKey(List<int> psk, int len) {
    final base = effectivePsk(psk);
    if (base.length == len) return List<int>.from(base, growable: false);
    if (base.length > len)
      return List<int>.from(base.sublist(0, len), growable: false);
    final out = <int>[];
    while (out.length < len) {
      out.addAll(base);
    }
    return List<int>.from(out.sublist(0, len), growable: false);
  }

  /// Compute XOR hash (0..255) for a channel.
  static int computeHash(String name, List<int> psk) {
    int h = 0;
    final nameBytes = utf8.encode(name);
    for (final b in nameBytes) {
      h ^= (b & 0xFF);
    }
    final epsk = effectivePsk(psk);
    for (final b in epsk) {
      h ^= (b & 0xFF);
    }
    return h & 0xFF;
  }

  /// Return the hash for the given (name, psk). If cached, returns cached value.
  /// Otherwise computes, inserts (respecting FIFO capacity) and returns it.
  int getHash(String name, List<int> psk) {
    for (final e in _entries) {
      if (e.name == name && _listEquals(e.psk, psk)) {
        return e.hash;
      }
    }
    return _addInternal(name, psk).hash;
  }

  ChannelHashEntry _addInternal(String name, List<int> psk) {
    _entries.removeWhere((e) => e.name == name && _listEquals(e.psk, psk));
    final h = computeHash(name, psk);
    final entry = ChannelHashEntry(name: name, psk: psk, hash: h);
    _entries.add(entry);
    if (_entries.length > capacity) {
      _entries.removeAt(0);
    }
    return entry;
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
