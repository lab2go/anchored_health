import 'dart:convert';
import 'dart:math';

import '../types.dart';

/// Injectable key-value store (app: e.g. SharedPreferences or files with data
/// protection; tests: [InMemoryKeyValueStore]).
abstract class KeyValueStore {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
  Future<Iterable<String>> keys();
}

class InMemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> data = {};
  @override
  Future<String?> get(String key) async => data[key];
  @override
  Future<void> set(String key, String value) async => data[key] = value;
  @override
  Future<void> remove(String key) async => data.remove(key);
  @override
  Future<Iterable<String>> keys() async => data.keys.toList();
}

/// Binding device <-> (user id, profile id, platform).
class SyncScope {
  const SyncScope({required this.userId, required this.profileId, required this.platform});
  final String userId;
  final String profileId;
  final HealthPlatform platform;

  /// `<uid>/<pid>/<platform>/`
  String get prefix => '$userId/$profileId/${platform.id}/';

  @override
  bool operator ==(Object other) =>
      other is SyncScope && other.userId == userId && other.profileId == profileId && other.platform == platform;

  @override
  int get hashCode => Object.hash(userId, profileId, platform);
}

/// Anchor (iOS, Base64) or changes token (Android) per type.
class SyncToken {
  const SyncToken({
    required this.value,
    required this.createdAt,
    this.firstRunFrom,
    this.firstRunComplete = true,
  });

  final String value;

  /// For the token max-age rule (Android).
  final DateTime createdAt;

  /// iOS first run with a time window: until [firstRunComplete], every
  /// following page must run with the same `from` (otherwise history outside
  /// the window would arrive).
  final DateTime? firstRunFrom;
  final bool firstRunComplete;

  Map<String, Object?> toJson() => {
        'v': value,
        'c': createdAt.toUtc().toIso8601String(),
        if (firstRunFrom != null) 'f': firstRunFrom!.toUtc().toIso8601String(),
        'done': firstRunComplete,
      };

  static SyncToken fromJson(Map<String, Object?> j) => SyncToken(
        value: j['v'] as String,
        createdAt: DateTime.parse(j['c'] as String),
        firstRunFrom: j['f'] == null ? null : DateTime.parse(j['f'] as String),
        firstRunComplete: (j['done'] as bool?) ?? true,
      );
}

/// Resumable window cursor of a series backfill.
class BackfillCursor {
  const BackfillCursor({required this.windows, required this.done});

  /// Windows [from, to) from newest to oldest.
  final List<({DateTime from, DateTime to})> windows;
  final int done;

  bool get isComplete => done >= windows.length;

  BackfillCursor advance() => BackfillCursor(windows: windows, done: done + 1);

  Map<String, Object?> toJson() => {
        'w': [
          for (final w in windows) [w.from.toUtc().toIso8601String(), w.to.toUtc().toIso8601String()]
        ],
        'd': done,
      };

  static BackfillCursor fromJson(Map<String, Object?> j) => BackfillCursor(
        windows: [
          for (final w in (j['w'] as List).cast<List>())
            (from: DateTime.parse(w[0] as String), to: DateTime.parse(w[1] as String))
        ],
        done: j['d'] as int,
      );

  /// Splits [from, to) into windows <= [maxWindow], newest first.
  static BackfillCursor split(DateTime from, DateTime to, {Duration maxWindow = const Duration(days: 7)}) {
    final windows = <({DateTime from, DateTime to})>[];
    var end = to;
    while (end.isAfter(from)) {
      final start = end.subtract(maxWindow).isBefore(from) ? from : end.subtract(maxWindow);
      windows.add((from: start, to: end));
      end = start;
    }
    return BackfillCursor(windows: windows, done: 0);
  }
}

/// Local sync state with the key layout
/// `<uid>/<pid>/<platform>/sync_token/<platform_type>`, `.../backfill/<platform_type>`,
/// `.../series_sources`, `.../run_lock`, `.../last_run`. The installation id
/// ([deviceIdKey]) lives **outside** the `<uid>/` prefix and survives
/// [resetUser].
class SyncStateStore {
  SyncStateStore(this.kv, {Random? random, this.deviceIdKey = defaultDeviceIdKey})
      : _random = random ?? Random.secure();

  final KeyValueStore kv;
  final Random _random;

  /// Default key of the installation id.
  static const defaultDeviceIdKey = 'anchored_health/device_id';

  /// Key of the installation id; must not start with a user id followed by `/`.
  final String deviceIdKey;

  String tokenKey(SyncScope s, String platformType) => '${s.prefix}sync_token/$platformType';
  String backfillKey(SyncScope s, String platformType) => '${s.prefix}backfill/$platformType';
  String seriesSourcesKey(SyncScope s) => '${s.prefix}series_sources';
  String runLockKey(SyncScope s) => '${s.prefix}run_lock';
  String lastRunKey(SyncScope s) => '${s.prefix}last_run';

  Future<SyncToken?> token(SyncScope s, String platformType) async {
    final raw = await kv.get(tokenKey(s, platformType));
    if (raw == null) return null;
    return SyncToken.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
  }

  Future<void> saveToken(SyncScope s, String platformType, SyncToken token) =>
      kv.set(tokenKey(s, platformType), jsonEncode(token.toJson()));

  /// Type disabled or token expired => discard.
  Future<void> clearToken(SyncScope s, String platformType) => kv.remove(tokenKey(s, platformType));

  Future<BackfillCursor?> backfillCursor(SyncScope s, String platformType) async {
    final raw = await kv.get(backfillKey(s, platformType));
    if (raw == null) return null;
    return BackfillCursor.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
  }

  Future<void> saveBackfillCursor(SyncScope s, String platformType, BackfillCursor c) =>
      kv.set(backfillKey(s, platformType), jsonEncode(c.toJson()));

  Future<void> clearBackfillCursor(SyncScope s, String platformType) => kv.remove(backfillKey(s, platformType));

  /// Sticky series sources.
  Future<Set<String>> seriesSources(SyncScope s) async {
    final raw = await kv.get(seriesSourcesKey(s));
    if (raw == null) return {};
    return (jsonDecode(raw) as List).cast<String>().toSet();
  }

  Future<void> addSeriesSources(SyncScope s, Set<String> sources) async {
    if (sources.isEmpty) return;
    final all = {...await seriesSources(s), ...sources}.toList()..sort();
    await kv.set(seriesSourcesKey(s), jsonEncode(all));
  }

  /// Lock per connection; stale locks (> [timeout]) are taken over.
  Future<bool> acquireRunLock(SyncScope s, DateTime now, {Duration timeout = const Duration(minutes: 10)}) async {
    final raw = await kv.get(runLockKey(s));
    if (raw != null) {
      final since = DateTime.tryParse(raw);
      if (since != null && now.difference(since) < timeout) return false;
    }
    await kv.set(runLockKey(s), now.toUtc().toIso8601String());
    return true;
  }

  Future<void> releaseRunLock(SyncScope s) => kv.remove(runLockKey(s));

  Future<DateTime?> lastRunAt(SyncScope s) async {
    final raw = await kv.get(lastRunKey(s));
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setLastRunAt(SyncScope s, DateTime t) => kv.set(lastRunKey(s), t.toUtc().toIso8601String());

  /// Installation id, kept across account/profile switches.
  Future<String> deviceId() async {
    final existing = await kv.get(deviceIdKey);
    if (existing != null) return existing;
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await kv.set(deviceIdKey, id);
    return id;
  }

  /// Logout/reset: deletes everything under `<uid>/` (anchors, cursors,
  /// series sources, locks), never the installation id.
  Future<int> resetUser(String userId) async {
    final prefix = '$userId/';
    final keys = (await kv.keys()).where((k) => k.startsWith(prefix)).toList();
    for (final k in keys) {
      await kv.remove(k);
    }
    return keys.length;
  }
}
