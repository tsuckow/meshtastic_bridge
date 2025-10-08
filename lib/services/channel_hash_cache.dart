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

  /// Compute XOR hash (0..255) for a channel.
  static int computeHash(String name, List<int> psk) {
    int h = 0;
    final nameBytes = utf8.encode(name);
    for (final b in nameBytes) {
      h ^= (b & 0xFF);
    }
    // If a single-byte PSK is provided, expand to the default 16-byte key
    // pattern used in firmware, replacing the last byte with the provided one.
    // default prefix (first 15 bytes) then provided byte as 16th:
    // d4 f1 bb 3a 20 29 07 59 f0 bc ff ab cf 4e 69 <provided>
    List<int> effectivePsk;
    if (psk.length == 1) {
      effectivePsk = [
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
        psk[0] & 0xFF
      ];
    } else {
      effectivePsk = psk;
    }
    for (final b in effectivePsk) {
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
