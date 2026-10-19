import 'dart:convert';

import '../state/sync_state_store.dart';
import 'local_day.dart';

/// Per type: anchor of the reference query, zone of the last read and the
/// look-back it was built for.
class ActivityAnchor {
  const ActivityAnchor({this.anchor, this.timeZoneId, required this.lookbackDays});
  final String? anchor;
  final String? timeZoneId;
  final int lookbackDays;

  Map<String, Object?> toJson() => {
        if (anchor != null) 'a': anchor,
        if (timeZoneId != null) 'tz': timeZoneId,
        'lb': lookbackDays,
      };

  static ActivityAnchor fromJson(Map<String, Object?> j) => ActivityAnchor(
        anchor: j['a'] as String?,
        timeZoneId: j['tz'] as String?,
        lookbackDays: (j['lb'] as num).toInt(),
      );
}

/// Local state of the daily totals. All keys live under the connection prefix
/// `<uid>/<pid>/<platform>/activity/...`, so `SyncStateStore.resetUser` removes
/// them with everything else; [clearType]/[clearAll] do it on revocation.
///
/// * `anchor/<type>`: [ActivityAnchor].
/// * `sent/<type>`: day -> last value the server accepted (to send only
///   changes; also tells which days the server holds).
/// * `idx/<type>/<yyyy-MM>`: UUID -> days of the samples of the last
///   `indexDays` days, in shards by month of the first day. Only needed to
///   find the days a deletion touches (HealthKit reports only the UUID).
/// * `server_tz`: time zone the server reported for the day boundaries.
class ActivityDailyState {
  ActivityDailyState(this.state);

  final SyncStateStore state;
  KeyValueStore get _kv => state.kv;

  String _base(SyncScope s) => '${s.prefix}activity/';
  String anchorKey(SyncScope s, String type) => '${_base(s)}anchor/$type';
  String sentKey(SyncScope s, String type) => '${_base(s)}sent/$type';
  String indexPrefix(SyncScope s, String type) => '${_base(s)}idx/$type/';
  String serverTzKey(SyncScope s) => '${_base(s)}server_tz';

  // --- anchor ---

  Future<ActivityAnchor?> anchor(SyncScope s, String type) async {
    final raw = await _kv.get(anchorKey(s, type));
    if (raw == null) return null;
    try {
      return ActivityAnchor.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (_) {
      return null; // damaged state: start over with a full read
    }
  }

  Future<void> saveAnchor(SyncScope s, String type, ActivityAnchor a) =>
      _kv.set(anchorKey(s, type), jsonEncode(a.toJson()));

  // --- sent values ---

  Future<Map<LocalDay, double>> sent(SyncScope s, String type) async {
    final raw = await _kv.get(sentKey(s, type));
    if (raw == null) return {};
    try {
      return {
        for (final e in (jsonDecode(raw) as Map).entries)
          LocalDay.parse(e.key as String): (e.value as num).toDouble()
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> saveSent(SyncScope s, String type, Map<LocalDay, double> sent) => _kv.set(
        sentKey(s, type),
        jsonEncode({for (final e in sent.entries) e.key.iso: e.value}),
      );

  // --- UUID -> days index ---

  Future<List<String>> _shardKeys(SyncScope s, String type) async {
    final p = indexPrefix(s, type);
    return [for (final k in await _kv.keys()) if (k.startsWith(p)) k];
  }

  Future<Map<String, String>> _readShard(String key) async {
    final raw = await _kv.get(key);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  static String _encodeDays(Set<LocalDay> days) => (days.toList()..sort()).map((d) => d.iso).join(',');
  static Set<LocalDay> _decodeDays(String s) => {for (final p in s.split(',')) if (p.isNotEmpty) LocalDay.parse(p)};

  /// Days of the given UUIDs; UUIDs the index does not know are missing in the
  /// result.
  Future<Map<String, Set<LocalDay>>> lookup(SyncScope s, String type, Set<String> uuids) async {
    final out = <String, Set<LocalDay>>{};
    if (uuids.isEmpty) return out;
    for (final key in await _shardKeys(s, type)) {
      final shard = await _readShard(key);
      for (final u in uuids) {
        final v = shard[u];
        if (v != null) out[u] = _decodeDays(v);
      }
    }
    return out;
  }

  /// Adds [add], removes [remove] and forgets everything that ends before
  /// [keepFrom].
  Future<void> updateIndex(
    SyncScope s,
    String type, {
    required Map<String, Set<LocalDay>> add,
    required Set<String> remove,
    required LocalDay keepFrom,
  }) async {
    final prefix = indexPrefix(s, type);
    final touched = <String, Map<String, String>>{};
    for (final key in await _shardKeys(s, type)) {
      final shardMonth = key.substring(prefix.length);
      if (shardMonth.compareTo(keepFrom.monthKey) < 0) {
        await _kv.remove(key); // whole month is out of the index window
        continue;
      }
      final shard = await _readShard(key);
      var changed = false;
      for (final u in remove) {
        if (shard.remove(u) != null) changed = true;
      }
      // Entries whose last day is before keepFrom are no longer needed.
      final stale = [
        for (final e in shard.entries)
          if (_decodeDays(e.value).every((d) => d.isBefore(keepFrom))) e.key
      ];
      for (final u in stale) {
        shard.remove(u);
        changed = true;
      }
      if (changed) touched[key] = shard;
    }
    for (final e in add.entries) {
      final days = e.value.where((d) => !d.isBefore(keepFrom)).toSet();
      if (days.isEmpty || remove.contains(e.key)) continue;
      final first = (days.toList()..sort()).first;
      final key = '$prefix${first.monthKey}';
      final shard = touched[key] ?? await _readShard(key);
      shard[e.key] = _encodeDays(days);
      touched[key] = shard;
    }
    for (final e in touched.entries) {
      if (e.value.isEmpty) {
        await _kv.remove(e.key);
      } else {
        await _kv.set(e.key, jsonEncode(e.value));
      }
    }
  }

  // --- server time zone ---

  Future<String?> serverTimeZone(SyncScope s) => _kv.get(serverTzKey(s));

  Future<void> saveServerTimeZone(SyncScope s, String tz) => _kv.set(serverTzKey(s), tz);

  // --- clearing ---

  /// Anchor, sent values and index of one type.
  Future<void> clearType(SyncScope s, String type) async {
    await _kv.remove(anchorKey(s, type));
    await _kv.remove(sentKey(s, type));
    for (final k in await _shardKeys(s, type)) {
      await _kv.remove(k);
    }
  }

  /// Everything of the daily totals of a connection (consent revoked, type
  /// switched off, connection removed). Nothing is deleted on the server.
  Future<int> clearAll(SyncScope s) async {
    final p = _base(s);
    final keys = [for (final k in await _kv.keys()) if (k.startsWith(p)) k];
    for (final k in keys) {
      await _kv.remove(k);
    }
    return keys.length;
  }

  /// Anchors and sent values, **keeping** the index: next run reads the whole
  /// look-back and sends every day again (e.g. after a time zone change).
  Future<void> clearAnchorsAndSent(SyncScope s, Iterable<String> types) async {
    for (final t in types) {
      await _kv.remove(anchorKey(s, t));
      await _kv.remove(sentKey(s, t));
    }
  }
}
