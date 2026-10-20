// Test doubles for the daily totals: a small HealthKit-like store, a server
// stand-in and a Berlin day calendar with real DST rules. Synthetic values only.
import 'package:anchored_health_engine/anchored_health_engine.dart';

/// Berlin: CET (+1) / CEST (+2). DST from the last Sunday of March 01:00 UTC to
/// the last Sunday of October 01:00 UTC (valid for 2025 and 2026 here).
class BerlinCalendar extends DayCalendar {
  const BerlinCalendar();

  static DateTime _lastSunday(int year, int month) {
    var d = DateTime.utc(year, month + 1, 0); // last day of the month
    while (d.weekday != DateTime.sunday) {
      d = d.subtract(const Duration(days: 1));
    }
    return DateTime.utc(year, month, d.day, 1);
  }

  static int offsetHours(DateTime instant) {
    final u = instant.toUtc();
    final start = _lastSunday(u.year, 3);
    final end = _lastSunday(u.year, 10);
    return (!u.isBefore(start) && u.isBefore(end)) ? 2 : 1;
  }

  @override
  LocalDay dayOf(DateTime instant) {
    final shifted = instant.toUtc().add(Duration(hours: offsetHours(instant)));
    return LocalDay(shifted.year, shifted.month, shifted.day);
  }

  @override
  DateTime startOf(LocalDay day) {
    final midnight = DateTime.utc(day.year, day.month, day.day);
    for (final off in [2, 1]) {
      final t = midnight.subtract(Duration(hours: off));
      if (offsetHours(t) == off) return t;
    }
    throw StateError('no start for $day');
  }
}

/// UTC calendar: easy to reason about; used where the zone does not matter.
class UtcCalendar extends DayCalendar {
  const UtcCalendar();
  @override
  LocalDay dayOf(DateTime instant) {
    final u = instant.toUtc();
    return LocalDay(u.year, u.month, u.day);
  }

  @override
  DateTime startOf(LocalDay day) => DateTime.utc(day.year, day.month, day.day);
}

class _Sample {
  _Sample(this.seq, this.uuid, this.type, this.start, this.end, this.value, this.source, this.priority);
  final int seq;
  final String uuid;
  final String type;
  final DateTime start;
  final DateTime end;
  final double value;
  final String source;
  final int priority; // lower = preferred source (iPhone before Watch)
}

/// Behaves like HealthKit for the parts the engine relies on: anchored
/// references with deletions, statistics per local day with a merged sum over
/// sources (overlapping samples of lower-priority sources are not counted),
/// samples apportioned to the days they overlap, no entry for days without data.
class FakeActivityStore implements ActivityDailyBridge {
  FakeActivityStore({this.calendar = const UtcCalendar(), this.zone = 'Europe/Berlin'});

  final DayCalendar calendar;
  String zone;

  final List<_Sample> _samples = [];
  final List<(int, String, String)> _deletions = []; // seq, type, uuid
  int _seq = 0;

  /// Log of calls for assertions.
  final List<String> calls = [];
  final List<({LocalDay from, LocalDay to})> totalsRanges = [];

  @override
  HealthPlatform get platform => HealthPlatform.appleHealth;

  String add(String type, DateTime start, DateTime end, double value,
      {String uuid = '', String source = 'iphone', int priority = 0}) {
    final id = uuid.isEmpty ? 'u${_seq + 1}' : uuid;
    _samples.add(_Sample(++_seq, id, type, start, end, value, source, priority));
    return id;
  }

  void remove(String type, String uuid) {
    final i = _samples.indexWhere((s) => s.type == type && s.uuid == uuid);
    if (i >= 0) _samples.removeAt(i);
    _deletions.add((++_seq, type, uuid));
  }

  /// A deletion of a sample the engine never saw.
  void removeUnknown(String type, String uuid) => _deletions.add((++_seq, type, uuid));

  @override
  Future<ActivityRefsPage> sampleRefs(String platformType,
      {String? anchor, DateTime? from, int limit = 5000}) async {
    calls.add('refs:${anchor ?? '-'}:${from?.toUtc().toIso8601String() ?? '-'}');
    final a = int.tryParse(anchor ?? '') ?? 0;
    final log = <(int, Object)>[
      for (final s in _samples) if (s.type == platformType && s.seq > a) (s.seq, s),
      for (final d in _deletions) if (d.$2 == platformType && d.$1 > a) (d.$1, d),
    ]..sort((x, y) => x.$1.compareTo(y.$1));
    final refs = <ActivitySampleRef>[];
    final deleted = <String>[];
    var last = a;
    var taken = 0;
    for (final (seq, obj) in log) {
      if (limit > 0 && taken >= limit) break;
      taken++;
      last = seq;
      if (obj is _Sample) {
        if (from == null || !obj.start.isBefore(from)) {
          refs.add(ActivitySampleRef(uuid: obj.uuid, start: obj.start, end: obj.end));
        }
      } else if (obj is (int, String, String)) {
        deleted.add(obj.$3);
      }
    }
    final more = log.isNotEmpty && last < log.last.$1;
    return ActivityRefsPage(refs: refs, deletedUuids: deleted, nextAnchor: '$last', hasMore: more);
  }

  /// Number of seconds of [s] inside [from, to).
  double _overlap(_Sample s, DateTime from, DateTime to) {
    final a = s.start.isAfter(from) ? s.start : from;
    final b = s.end.isBefore(to) ? s.end : to;
    return b.isAfter(a) ? b.difference(a).inMilliseconds.toDouble() : 0;
  }

  @override
  Future<DailyTotalsPage> dailyTotals(String platformType, {required LocalDay from, required LocalDay to}) async {
    calls.add('totals:$from:$to');
    totalsRanges.add((from: from, to: to));
    final days = <DailyTotal>[];
    for (final day in daysInRange(from, to)) {
      final start = calendar.startOf(day);
      final end = calendar.startOf(day.addDays(1));
      final inDay = [for (final s in _samples) if (s.type == platformType && _overlap(s, start, end) > 0) s]
        ..sort((a, b) => a.priority.compareTo(b.priority));
      if (inDay.isEmpty) continue;
      final counted = <_Sample>[];
      for (final s in inDay) {
        // HealthKit merge: a sample of a lower-priority source that overlaps an
        // already counted sample of another source is not counted again.
        final clash = counted.any((c) =>
            c.source != s.source && c.start.isBefore(s.end) && s.start.isBefore(c.end));
        if (!clash) counted.add(s);
      }
      var sum = 0.0;
      for (final s in counted) {
        final total = s.end.difference(s.start).inMilliseconds;
        sum += total == 0 ? s.value : s.value * _overlap(s, start, end) / total;
      }
      days.add(DailyTotal(day: day, value: sum));
    }
    return DailyTotalsPage(days: days, timeZoneId: zone);
  }
}

/// Server stand-in with the contract of `health_ingest_daily`.
class FakeActivityUploader implements ActivityDailyUploader {
  FakeActivityUploader({this.timezoneId = 'Europe/Berlin'});

  String? timezoneId;
  final List<List<ActivityIngestElement>> batches = [];

  /// Stored rows: `type|source|day` -> value.
  final Map<String, double> rows = {};

  /// Throw on the n-th call (1-based).
  int? failOnCall;
  int rejectEvery = 0;

  /// Turn down every element (inactive mapping, type off for the connection, consent missing):
  /// the server answers without an error and counts them as `rejected` (README `hk2`).
  bool rejectAll = false;

  /// Reject only the n-th call (1-based) completely.
  int? rejectCall;

  /// Count every element as dropped echo.
  bool echoAll = false;

  /// Answer with empty counters (a reply that does not say what happened).
  bool silent = false;

  /// Count this many more elements than were sent (an answer that does not add up).
  int overCount = 0;
  int _calls = 0;
  int get calls => _calls;

  List<ActivityIngestElement> get all => [for (final b in batches) ...b];

  @override
  Future<ActivityIngestResult> ingestDaily(String linkId, List<ActivityIngestElement> days) async {
    _calls++;
    if (failOnCall == _calls) throw StateError('network');
    batches.add(days);
    if (silent) return ActivityIngestResult(timezoneId: timezoneId);
    if (echoAll) return ActivityIngestResult(echo: days.length, timezoneId: timezoneId);
    if (rejectAll || rejectCall == _calls) {
      return ActivityIngestResult(rejected: days.length, timezoneId: timezoneId);
    }
    var ins = 0, upd = 0, dup = 0, rej = 0;
    for (final (i, e) in days.indexed) {
      if (rejectEvery > 0 && (i + 1) % rejectEvery == 0) {
        rej++;
        continue;
      }
      final key = '${e.platformType}|${e.sourcePackage}|${e.day}';
      final old = rows[key];
      if (old == null) {
        ins++;
      } else if (old == e.valueNumeric) {
        dup++;
      } else {
        upd++;
      }
      rows[key] = e.valueNumeric;
    }
    return ActivityIngestResult(inserted: ins + overCount, updated: upd, duplicates: dup, rejected: rej, timezoneId: timezoneId);
  }
}
