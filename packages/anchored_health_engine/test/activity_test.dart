import 'dart:io';

import 'package:anchored_health_engine/anchored_health_engine.dart';
import 'package:anchored_health_engine/file_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/activity_fakes.dart';
import 'support/fakes.dart';

const _steps = 'stepCount';
final _now = DateTime.utc(2026, 10, 19, 12);
LocalDay d(String s) => LocalDay.parse(s);

class Harness {
  Harness({
    DayCalendar calendar = const UtcCalendar(),
    DateTime? now,
    ActivityDailyConfig config = const ActivityDailyConfig(),
    SessionProvider? session,
    this.timezone = 'Europe/Berlin',
    this.activityKv,
    InMemoryKeyValueStore? sharedKv,
  })  : clock = now ?? _now,
        store = FakeActivityStore(calendar: calendar, zone: timezone),
        uploader = FakeActivityUploader(timezoneId: timezone),
        kv = sharedKv ?? InMemoryKeyValueStore() {
    state = SyncStateStore(kv, activityKv: activityKv);
    sync = ActivityDailySync(
      bridge: store,
      catalog: testCatalog(),
      state: state,
      uploader: uploader,
      session: session ?? const FixedSession('user-a', 'profile-a'),
      config: config,
      calendar: calendar,
      clock: () => clock,
    );
  }

  final String timezone;

  /// Separate state store (file store outside the backup), null = everything in [kv].
  final KeyValueStore? activityKv;
  DateTime clock;
  final FakeActivityStore store;
  final FakeActivityUploader uploader;
  final InMemoryKeyValueStore kv;
  late final SyncStateStore state;
  late final ActivityDailySync sync;
  final link = const HealthLink(
      linkId: 'link-1', userId: 'user-a', profileId: 'profile-a', platform: HealthPlatform.appleHealth);

  Future<ActivitySyncResult> run([Set<String> types = const {_steps}, bool forceFull = false]) =>
      sync.syncNow(link, types: types, forceFull: forceFull);

  /// A step sample of [minutes] minutes starting at [hour]:00 UTC of [day].
  String steps(String day, int hour, double value,
      {int minutes = 10, String type = _steps, String source = 'iphone', int priority = 0, String uuid = ''}) {
    final start = DateTime.utc(d(day).year, d(day).month, d(day).day, hour);
    return store.add(type, start, start.add(Duration(minutes: minutes)), value,
        source: source, priority: priority, uuid: uuid);
  }

  Map<String, double> get rows => uploader.rows;
  double? row(String day, {String type = _steps}) =>
      uploader.rows['$type|$defaultActivitySourcePackage|$day'];
}

void main() {
  group('LocalDay', () {
    test('strict parsing, formatting and arithmetic', () {
      expect(LocalDay.tryParse('2026-02-30'), isNull);
      expect(LocalDay.tryParse('2026-2-3'), isNull);
      expect(LocalDay.tryParse(' 2026-10-19'), isNull);
      expect(LocalDay.tryParse('2028-02-29')!.iso, '2028-02-29');
      expect(d('2026-03-01').addDays(-1).iso, '2026-02-28');
      expect(d('2026-12-31').addDays(1).iso, '2027-01-01');
      expect(d('2026-03-28').daysUntil(d('2026-03-30')), 2);
      expect(d('2026-10-19').monthKey, '2026-10');
      expect(daysInRange(d('2026-02-27'), d('2026-03-02')).map((x) => x.iso),
          ['2026-02-27', '2026-02-28', '2026-03-01', '2026-03-02']);
      expect(() => LocalDay.parse('x'), throwsFormatException);
    });
  });

  group('catalog and engine', () {
    test('five daily-total entries with canonical units, 365 days default and 1825 cap', () {
      final c = testCatalog();
      final e = c.dailySumEntries(HealthPlatform.appleHealth);
      expect(e.map((x) => x.platformType), activityPlatformTypes);
      expect(e.map((x) => x.unitCanonical), ['count', 'm', 'kcal', 'count', 'min']);
      expect(e.map((x) => x.backfillDefaultDays).toSet(), {365});
      expect(e.map((x) => x.backfillCapDays).toSet(), {1825});
      expect(e.every((x) => x.factor == 1 && x.offset == 0 && !x.exportSupported), isTrue);
      expect(e.map((x) => x.vitalTypeId), everyElement(isNotNull));
      expect(VitalKey.steps.loinc, '55423-8');
    });

    test('Health Connect has placeholders only (not importable)', () {
      final c = testCatalog();
      expect(c.dailySumEntries(HealthPlatform.healthConnect), isEmpty);
      final hc = c.entries.where((e) => e.platform == HealthPlatform.healthConnect && e.backfillClass == BackfillClass.dailySum);
      expect(hc.map((e) => e.platformType), ['StepsRecord', 'DistanceRecord', 'ActiveCaloriesBurnedRecord', 'FloorsClimbedRecord']);
      expect(hc.every((e) => !e.importSupported), isTrue);
      expect(c.importPlatformTypes(HealthPlatform.healthConnect), isNot(contains('StepsRecord')));
    });

    test('the Android bridge placeholder throws instead of returning data', () {
      const b = UnsupportedActivityDailyBridge(HealthPlatform.healthConnect);
      expect(() => b.dailyTotals('StepsRecord', from: d('2026-10-01'), to: d('2026-10-02')),
          throwsA(isA<HealthOperationUnsupported>()));
      expect(() => b.sampleRefs('StepsRecord'), throwsA(isA<HealthOperationUnsupported>()));
    });

    test('HealthSyncEngine.syncNow never reads daily-total types as single samples', () async {
      final h = EngineHarness();
      h.bridge.add(sample(id: 's1', type: 'stepCount', value: 500, unit: 'count'));
      final r = await h.sync({'stepCount', 'bodyMass'});
      expect(r['daily_sum_skipped'], 1);
      expect(r.failedTypes, isEmpty);
      expect(h.uploader.rows, isEmpty);
      expect(h.bridge.calls.where((c) => c.contains('stepCount')), isEmpty);
      final b = await h.engine.extendBackfill(h.link, 'stepCount', from: DateTime.utc(2026, 9, 1), to: DateTime.utc(2026, 10, 1));
      expect(b.outcome, SyncOutcome.error);
    });
  });

  group('reader', () {
    test('default look-back is 365 days including today; today is partial', () async {
      final h = Harness();
      h.steps('2026-10-19', 8, 1500);
      h.steps('2026-10-18', 8, 4000);
      h.steps('2025-10-20', 8, 100); // first day of 365
      h.steps('2025-10-19', 8, 999); // day 366: outside
      final r = ActivityDailyReader(bridge: h.store, calendar: const UtcCalendar(), clock: () => _now);
      final days = await r.readDailyTotals(_steps);
      expect(h.store.totalsRanges.single.from.iso, '2025-10-20');
      expect(h.store.totalsRanges.single.to.iso, '2026-10-19');
      expect(days.map((x) => x.day.iso), ['2025-10-20', '2026-10-18', '2026-10-19']);
      expect(days.map((x) => x.complete), [true, true, false]);
    });

    test('maximum look-back is 1825 days, more is an error', () async {
      final h = Harness();
      final r = ActivityDailyReader(bridge: h.store, calendar: const UtcCalendar(), clock: () => _now);
      await r.readDailyTotals(_steps, lookbackDays: 1825);
      expect(h.store.totalsRanges.last.from.daysUntil(h.store.totalsRanges.last.to) + 1, 1825);
      expect(() => r.readDailyTotals(_steps, lookbackDays: 1826), throwsArgumentError);
      expect(() => r.readDailyTotals(_steps, lookbackDays: 0), throwsArgumentError);
      expect(() => r.readDailyTotals('bodyMass'), throwsArgumentError);
      expect(() => r.readDailyTotals(_steps, from: d('2026-10-19'), to: d('2026-10-01')), throwsArgumentError);
      expect(() => r.readDailyTotals(_steps, from: d('2020-01-01'), to: d('2026-10-01')), throwsArgumentError);
    });

    test('days without data are missing, never 0; invalid values are dropped', () async {
      final h = Harness();
      h.steps('2026-10-10', 8, 0); // a real zero from the source stays
      h.steps('2026-10-12', 8, 700);
      final r = ActivityDailyReader(bridge: h.store, calendar: const UtcCalendar(), clock: () => _now);
      final days = await r.readDailyTotals(_steps, lookbackDays: 30);
      expect(days.map((x) => (x.day.iso, x.value)), [('2026-10-10', 0.0), ('2026-10-12', 700.0)]);
    });
  });

  group('first run', () {
    test('sends one merged sum per day with a fixed source, canonical unit and no version', () async {
      final h = Harness();
      h.steps('2026-10-17', 8, 3000);
      h.steps('2026-10-17', 14, 2500);
      h.steps('2026-10-18', 9, 4000);
      h.steps('2026-10-19', 9, 1200); // today, partial
      final r = await h.run();
      expect(r.outcome, SyncOutcome.success);
      expect(r['days_sent'], 3);
      final e = h.uploader.all;
      expect(e.map((x) => x.day.iso), ['2026-10-17', '2026-10-18', '2026-10-19']);
      expect(h.rows, {
        'stepCount|$defaultActivitySourcePackage|2026-10-17': 5500,
        'stepCount|$defaultActivitySourcePackage|2026-10-18': 4000,
        'stepCount|$defaultActivitySourcePackage|2026-10-19': 1200,
      });
      expect(e.first.toJson(), {
        'vital_type_id': 'vt-steps',
        'platform_type': 'stepCount',
        'day': '2026-10-17',
        'value_numeric': 5500.0,
        'source_package': defaultActivitySourcePackage,
        'unit': 'count',
        'source_name': 'Apple Health',
        'map_version': 1,
      });
      for (final x in e) {
        expect(x.toJson().keys, isNot(contains('external_version')));
        expect(x.toJson().keys, isNot(contains('deleted')));
      }
    });

    test('all five types in one run use their own ids and canonical units', () async {
      final h = Harness();
      for (final t in activityPlatformTypes) {
        h.steps('2026-10-18', 8, 10, type: t);
      }
      final r = await h.run(activityPlatformTypes.toSet());
      expect(r.outcome, SyncOutcome.success);
      expect(h.uploader.all.map((x) => (x.platformType, x.vitalTypeId, x.unit)).toSet(), {
        ('stepCount', 'vt-steps', 'count'),
        ('distanceWalkingRunning', 'vt-distance', 'm'),
        ('activeEnergyBurned', 'vt-energy', 'kcal'),
        ('flightsClimbed', 'vt-flights', 'count'),
        ('appleExerciseTime', 'vt-exercise', 'min'),
      });
    });

    test('an empty read changes nothing: nothing is sent, nothing is deleted', () async {
      final h = Harness();
      final r = await h.run();
      expect(r.outcome, SyncOutcome.success);
      expect(h.uploader.batches, isEmpty);
      expect(r.emptiedDays, isEmpty);
    });

    test('batches are per type and period (45 days), newest first, at most 2000', () async {
      final h = Harness();
      for (var i = 0; i < 365; i++) {
        h.steps(d('2026-10-19').addDays(-i).iso, 8, 100.0 + i);
      }
      final r = await h.run();
      expect(r['days_sent'], 365);
      expect(h.uploader.batches.length, 9);
      for (final b in h.uploader.batches) {
        expect(b.length, lessThanOrEqualTo(45));
        expect(b.first.day.daysUntil(b.last.day), lessThan(45));
      }
      expect(h.uploader.batches.first.last.day.iso, '2026-10-19');
      expect(h.uploader.batches.last.first.day.iso, '2025-10-20');
    });

    test('batch builder: limits and types never mix', () {
      ActivityIngestElement el(String type, String day) => ActivityIngestElement(
          vitalTypeId: 'id-$type', platformType: type, vitalKey: VitalKey.steps, day: d(day),
          valueNumeric: 1, sourcePackage: 'p', unit: 'count');
      final b = buildActivityBatches([
        el('a', '2026-01-01'), el('b', '2026-01-02'), el('a', '2026-01-03'), el('a', '2026-03-01'),
      ], maxSpanDays: 45);
      expect(b.map((x) => x.map((e) => '${e.platformType}${e.day}').toList()).toList(), [
        ['a2026-03-01'], ['a2026-01-01', 'a2026-01-03'], ['b2026-01-02'],
      ]);
      final many = [for (var i = 0; i < 2500; i++) el('a', '2026-01-01')];
      expect(buildActivityBatches(many, maxSpanDays: 100).map((x) => x.length).toList()..sort(), [500, 2000]);
      expect(() => buildActivityBatches(many, maxSize: 2001), throwsArgumentError);
    });
  });

  group('incremental runs', () {
    test('no change: only the reference query runs, nothing is read or sent', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 4000);
      await h.run();
      h.store.calls.clear();
      h.uploader.batches.clear();
      final r = await h.run();
      expect(r.outcome, SyncOutcome.success);
      expect(h.store.calls.where((c) => c.startsWith('totals')), isEmpty);
      expect(h.uploader.batches, isEmpty);
    });

    test('new sample today: only today is read and sent again (correction overwrites)', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 4000);
      h.steps('2026-10-19', 9, 1000);
      await h.run();
      h.uploader.batches.clear();
      h.store.totalsRanges.clear();
      h.steps('2026-10-19', 11, 500);
      final r = await h.run();
      expect(r['days_sent'], 1);
      expect(r['updated'], 1);
      expect(h.row('2026-10-19'), 1500);
      expect(h.store.totalsRanges.single.from.iso, '2026-10-19');
      expect(h.store.totalsRanges.single.to.iso, '2026-10-19');
    });

    test('late sample (old start, inserted now) recomputes only its old day', () async {
      final h = Harness();
      for (final day in ['2026-10-10', '2026-10-11', '2026-10-12', '2026-10-18']) {
        h.steps(day, 8, 1000);
      }
      await h.run();
      h.uploader.batches.clear();
      h.store.totalsRanges.clear();
      h.steps('2026-10-11', 21, 800); // the watch syncs three days late
      final r = await h.run();
      expect(r['days_sent'], 1);
      expect(h.uploader.all.single.day.iso, '2026-10-11');
      expect(h.row('2026-10-11'), 1800);
      expect(h.store.totalsRanges.single.from.iso, '2026-10-11');
      expect(h.store.totalsRanges.single.to.iso, '2026-10-11');
    });

    test('a very late sample far back does not travel with everyday days', () async {
      final h = Harness();
      h.steps('2026-10-19', 9, 1000);
      h.steps('2026-06-01', 9, 1000);
      await h.run();
      h.uploader.batches.clear();
      h.steps('2026-06-01', 20, 100);
      h.steps('2026-10-19', 10, 50);
      await h.run();
      expect(h.uploader.batches.length, 2, reason: 'review A3: separate batches for old and recent days');
      expect(h.uploader.batches.first.single.day.iso, '2026-10-19');
      expect(h.uploader.batches.last.single.day.iso, '2026-06-01');
    });

    test('a sample that spans midnight recomputes both days', () async {
      final h = Harness();
      h.steps('2026-10-17', 8, 100);
      await h.run();
      h.uploader.batches.clear();
      // 23:50 to 00:10: apportioned 50/50 by the store
      h.store.add(_steps, DateTime.utc(2026, 10, 17, 23, 50), DateTime.utc(2026, 10, 18, 0, 10), 200);
      final r = await h.run();
      expect(r['days_sent'], 2);
      expect(h.row('2026-10-17'), 200);
      expect(h.row('2026-10-18'), 100);
    });

    test('a sample that ends exactly at midnight does not touch the next day', () async {
      final h = Harness();
      h.steps('2026-10-17', 8, 100);
      await h.run();
      h.uploader.batches.clear();
      h.store.add(_steps, DateTime.utc(2026, 10, 17, 23, 50), DateTime.utc(2026, 10, 18), 40);
      await h.run();
      expect(h.uploader.all.map((x) => x.day.iso), ['2026-10-17']);
    });

    test('a deleted sample recomputes its day through the UUID index', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 3000, uuid: 'keep');
      h.steps('2026-10-18', 12, 1000, uuid: 'drop');
      h.steps('2026-10-17', 8, 2000, uuid: 'other');
      await h.run();
      h.uploader.batches.clear();
      h.store.totalsRanges.clear();
      h.store.remove(_steps, 'drop');
      final r = await h.run();
      expect(r['days_sent'], 1);
      expect(h.row('2026-10-18'), 3000);
      expect(h.row('2026-10-17'), 2000);
      expect(r['full_window_reads'], 0);
      expect(h.store.totalsRanges.single.from.iso, '2026-10-18');
      expect(h.store.totalsRanges.single.to.iso, '2026-10-18');
    });

    test('a deleted UUID the index does not know reads the whole look-back, sends only changes', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 3000);
      h.steps('2026-10-17', 8, 2000);
      await h.run();
      h.uploader.batches.clear();
      h.store.totalsRanges.clear();
      h.store.removeUnknown(_steps, 'old-sample');
      final r = await h.run();
      expect(r['full_window_reads'], 1);
      expect(r['unknown_deletions'], 1);
      expect(h.store.totalsRanges.single.from.iso, '2025-10-20');
      expect(h.uploader.batches, isEmpty, reason: 'nothing changed: no second upload of 365 days');
    });

    test('all samples of a day deleted: reported, never sent as 0, never deleted', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 3000, uuid: 'a');
      h.steps('2026-10-17', 8, 2000, uuid: 'b');
      await h.run();
      h.uploader.batches.clear();
      h.store.remove(_steps, 'a');
      final r = await h.run();
      expect(r.outcome, SyncOutcome.success);
      expect(h.uploader.batches, isEmpty, reason: 'no 0, no tombstone');
      expect(r.emptiedDays[_steps], [d('2026-10-18')]);
      expect(r['emptied_days'], 1);
      expect(h.row('2026-10-18'), 3000, reason: 'the server keeps its value');
      // And the engine never offers a tombstone.
      expect(h.uploader.all.any((x) => x.toJson().containsKey('deleted')), isFalse);
    });

    test('everything deleted in the store: an empty read deletes nothing', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 3000, uuid: 'a');
      await h.run();
      h.uploader.batches.clear();
      h.store.remove(_steps, 'a');
      h.store.removeUnknown(_steps, 'zzz'); // forces a full read
      final r = await h.run();
      expect(h.uploader.batches, isEmpty);
      expect(r.emptiedDays[_steps], [d('2026-10-18')]);
    });

    test('negative sums are ignored (they cannot be a daily total)', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 100);
      h.steps('2026-10-17', 8, -5);
      await h.run();
      expect(h.uploader.all.map((x) => x.day.iso), ['2026-10-18']);
    });

    test('the look-back window moves: old values are pruned from the local state', () async {
      final h = Harness();
      h.steps('2025-10-20', 8, 100);
      h.steps('2026-10-19', 8, 100);
      await h.run();
      final scope = h.link.scope;
      expect((await h.sync.store.sent(scope, _steps)).keys.map((x) => x.iso), ['2025-10-20', '2026-10-19']);
      h.clock = DateTime.utc(2026, 10, 22, 12);
      h.steps('2026-10-22', 8, 1);
      await h.run();
      expect((await h.sync.store.sent(scope, _steps)).keys.map((x) => x.iso), ['2026-10-19', '2026-10-22']);
    });
  });

  group('iPhone and Apple Watch overlap', () {
    test('the merged sum is sent, not the sum over devices', () async {
      final h = Harness();
      // iPhone and Watch both counted 08:00-09:00; the watch also walked 09:00-10:00 alone.
      h.steps('2026-10-18', 8, 800, minutes: 60, source: 'iphone', priority: 0);
      h.steps('2026-10-18', 8, 700, minutes: 60, source: 'watch', priority: 1);
      h.steps('2026-10-18', 9, 500, minutes: 60, source: 'watch', priority: 1);
      await h.run();
      expect(h.row('2026-10-18'), 1300, reason: 'not 2000');
    });

    test('a late watch sync that overlaps the phone changes nothing, one that does not adds up', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 800, minutes: 60, source: 'iphone', priority: 0);
      await h.run();
      h.uploader.batches.clear();
      h.steps('2026-10-18', 8, 700, minutes: 60, source: 'watch', priority: 1, uuid: 'w-overlap');
      await h.run();
      expect(h.uploader.batches, isEmpty, reason: 'recomputed to the same merged sum');
      h.steps('2026-10-18', 12, 600, minutes: 30, source: 'watch', priority: 1);
      await h.run();
      expect(h.row('2026-10-18'), 1400);
    });
  });

  group('23 and 25 hour days (Berlin)', () {
    const berlin = BerlinCalendar();

    test('calendar facts', () {
      expect(berlin.startOf(d('2026-03-29')), DateTime.utc(2026, 3, 28, 23));
      expect(berlin.startOf(d('2026-03-30')), DateTime.utc(2026, 3, 29, 22));
      expect(berlin.startOf(d('2026-10-25')), DateTime.utc(2026, 10, 24, 22));
      expect(berlin.startOf(d('2026-10-26')), DateTime.utc(2026, 10, 25, 23));
      expect(berlin.dayOf(DateTime.utc(2026, 3, 28, 23, 30)).iso, '2026-03-29');
      expect(berlin.dayOf(DateTime.utc(2026, 10, 25, 22, 30)).iso, '2026-10-25', reason: '23:30 CET, the 25th');
    });

    test('the 23-hour and the 25-hour day are single days with their own sum', () async {
      final h = Harness(calendar: berlin, now: DateTime.utc(2026, 11, 2, 12));
      // 100 steps per hour all day long.
      for (final day in ['2026-03-28', '2026-03-29', '2026-03-30']) {
        final s = berlin.startOf(d(day));
        final e = berlin.startOf(d(day).addDays(1));
        h.store.add(_steps, s, e, 100.0 * e.difference(s).inHours);
      }
      for (final day in ['2026-10-24', '2026-10-25', '2026-10-26']) {
        final s = berlin.startOf(d(day));
        final e = berlin.startOf(d(day).addDays(1));
        h.store.add(_steps, s, e, 100.0 * e.difference(s).inHours);
      }
      await h.run();
      expect(h.row('2026-03-28'), 2400);
      expect(h.row('2026-03-29'), 2300, reason: '23 hours');
      expect(h.row('2026-03-30'), 2400);
      expect(h.row('2026-10-24'), 2400);
      expect(h.row('2026-10-25'), 2500, reason: '25 hours');
      expect(h.row('2026-10-26'), 2400);
    });

    test('a late sample on the 23-hour day touches that day only', () async {
      final h = Harness(calendar: berlin, now: DateTime.utc(2026, 4, 3, 12));
      for (final day in ['2026-03-28', '2026-03-29', '2026-03-30']) {
        h.store.add(_steps, berlin.startOf(d(day)).add(const Duration(hours: 10)),
            berlin.startOf(d(day)).add(const Duration(hours: 11)), 1000);
      }
      await h.run();
      h.uploader.batches.clear();
      // 23:00Z is local midnight (CET), so 23:30Z is 00:30 on the 29th.
      h.store.add(_steps, DateTime.utc(2026, 3, 28, 23, 30), DateTime.utc(2026, 3, 28, 23, 40), 55);
      await h.run();
      expect(h.uploader.all.map((x) => x.day.iso), ['2026-03-29']);
      expect(h.row('2026-03-29'), 1055);
    });
  });

  group('failures and state', () {
    test('a failed batch leaves the anchor untouched; accepted batches stay stored, the next run sends the rest', () async {
      final h = Harness();
      for (var i = 0; i < 100; i++) {
        h.steps(d('2026-10-19').addDays(-i).iso, 8, 100.0 + i);
      }
      h.uploader.failOnCall = 2;
      final r1 = await h.run();
      expect(r1.outcome, SyncOutcome.error);
      expect(r1.failedTypes, [_steps]);
      expect(r1.failureReasons[_steps], ActivityFailure.error);
      expect(await h.sync.store.anchor(h.link.scope, _steps), isNull);
      expect((await h.sync.store.sent(h.link.scope, _steps)).length, 10, reason: 'the first (newest) batch was accepted');
      h.uploader.failOnCall = null;
      final r2 = await h.run();
      expect(r2.outcome, SyncOutcome.success);
      expect(h.rows.length, 100);
      expect(r2['days_sent'], 90, reason: 'only the rest travels again');
      expect(r2['duplicates'], 0);
      expect(await h.sync.store.anchor(h.link.scope, _steps), isNotNull);
    });

    test('one type fails, the others go through', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 5, type: 'stepCount');
      h.steps('2026-10-18', 8, 5, type: 'flightsClimbed');
      h.uploader.failOnCall = 1;
      final r = await h.run({'stepCount', 'flightsClimbed'});
      expect(r.outcome, SyncOutcome.partial);
      expect(r.failedTypes.length, 1);
      expect(h.rows.length, 1);
    });

    test('server rejections are counted and make the type fail', () async {
      final h = Harness();
      for (var i = 0; i < 4; i++) {
        h.steps('2026-10-1$i', 8, 10);
      }
      h.uploader.rejectEvery = 2;
      final r = await h.run();
      expect(r['rejected'], 2);
      expect(r.outcome, SyncOutcome.error);
      expect(r.failureReasons[_steps], ActivityFailure.rejected);
      expect(await h.sync.store.sent(h.link.scope, _steps), isEmpty, reason: 'which days were turned down is unknown');
      expect(await h.sync.store.anchor(h.link.scope, _steps), isNull);
    });

    test('session mismatch reads and sends nothing; a held lock gives locked', () async {
      final h = Harness(session: const FixedSession('other', 'profile-a'));
      h.steps('2026-10-18', 8, 1);
      expect((await h.run()).outcome, SyncOutcome.sessionMismatch);
      expect(h.store.calls, isEmpty);
      final h2 = Harness();
      await h2.state.acquireRunLock(h2.link.scope, h2.clock);
      expect((await h2.run()).outcome, SyncOutcome.locked);
    });

    test('invalid arguments are refused before anything runs', () async {
      final h = Harness();
      expect(() => h.sync.syncNow(h.link, types: {'bodyMass'}), throwsArgumentError);
      expect(() => h.sync.syncNow(h.link, types: {_steps}, lookbackDays: 1826), throwsArgumentError);
    });

    test('a type without a server id is not read', () async {
      final h = Harness();
      final noId = ActivityDailySync(
        bridge: h.store,
        catalog: TypeCatalog.v1Default(),
        state: h.state,
        uploader: h.uploader,
        session: const FixedSession('user-a', 'profile-a'),
        calendar: const UtcCalendar(),
        clock: () => h.clock,
      );
      h.steps('2026-10-18', 8, 1);
      final r = await noId.syncNow(h.link, types: {_steps});
      expect(r.outcome, SyncOutcome.error);
      expect(r['no_vital_type_id'], 1);
      expect(h.store.calls, isEmpty);
    });

    test('forget() removes every local trace, resetUser does too, the server is untouched', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 100);
      await h.run();
      expect(h.kv.data.keys.where((k) => k.contains('/activity/')), isNotEmpty);
      await h.sync.forget(h.link.scope);
      expect(h.kv.data.keys.where((k) => k.contains('/activity/')), isEmpty);
      expect(h.rows.length, 1);
      await h.run();
      expect(h.kv.data.keys.where((k) => k.contains('/activity/')), isNotEmpty);
      await h.state.resetUser('user-a');
      expect(h.kv.data.keys.where((k) => k.contains('/activity/')), isEmpty);
    });

    test('forget(types) keeps the other types', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 100);
      h.steps('2026-10-18', 8, 100, type: 'flightsClimbed');
      await h.run({'stepCount', 'flightsClimbed'});
      await h.sync.forget(h.link.scope, types: ['stepCount']);
      expect(await h.sync.store.anchor(h.link.scope, 'stepCount'), isNull);
      expect(await h.sync.store.anchor(h.link.scope, 'flightsClimbed'), isNotNull);
    });
  });

  group('server answers (review P3 A1)', () {
    test('turned-down days are not stored as sent: the next run after activation sends them (review R1)', () async {
      final h = Harness();
      for (var i = 0; i < 5; i++) {
        h.steps(d('2026-10-18').addDays(-i).iso, 8, 1000.0 + i);
      }
      h.uploader.rejectAll = true; // mapping not active yet
      final r1 = await h.run();
      expect(r1.outcome, isNot(SyncOutcome.success));
      expect(r1.outcome, SyncOutcome.error);
      expect(r1.failedTypes, [_steps]);
      expect(r1.failureReasons, {_steps: ActivityFailure.rejected});
      expect(r1['rejected'], 5);
      expect(await h.sync.store.anchor(h.link.scope, _steps), isNull, reason: 'anchor must not advance');
      expect(await h.sync.store.sent(h.link.scope, _steps), isEmpty, reason: 'sent must stay empty');
      expect(h.rows, isEmpty);
      // still rejected, also with forceFull: nothing is committed
      final r2 = await h.run({_steps}, true);
      expect(r2.outcome, SyncOutcome.error);
      expect(await h.sync.store.sent(h.link.scope, _steps), isEmpty);
      // mapping activated: a plain run (no forceFull) sends everything
      h.uploader.rejectAll = false;
      final r3 = await h.run();
      expect(r3.outcome, SyncOutcome.success);
      expect(h.rows.length, 5);
      expect((await h.sync.store.sent(h.link.scope, _steps)).length, 5);
      expect(await h.sync.store.anchor(h.link.scope, _steps), isNotNull);
    });

    test('a rejected middle batch keeps the earlier ones, stops the type, and the rest follows later', () async {
      final h = Harness();
      for (var i = 0; i < 100; i++) {
        h.steps(d('2026-10-19').addDays(-i).iso, 8, 100.0 + i);
      }
      h.uploader.rejectCall = 2;
      final r1 = await h.run();
      expect(r1.outcome, SyncOutcome.error);
      expect(r1.failureReasons[_steps], ActivityFailure.rejected);
      expect(h.uploader.calls, 2, reason: 'no more calls after a turned-down batch');
      expect((await h.sync.store.sent(h.link.scope, _steps)).length, 10);
      expect(await h.sync.store.anchor(h.link.scope, _steps), isNull);
      h.uploader.rejectCall = null;
      final r2 = await h.run();
      expect(r2.outcome, SyncOutcome.success);
      expect(r2['days_sent'], 90);
      expect(h.rows.length, 100);
    });

    test('dropped echo is not an acceptance either', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 100);
      h.uploader.echoAll = true;
      final r = await h.run();
      expect(r.outcome, SyncOutcome.error);
      expect(r.failureReasons[_steps], ActivityFailure.echo);
      expect(await h.sync.store.sent(h.link.scope, _steps), isEmpty);
      expect(await h.sync.store.anchor(h.link.scope, _steps), isNull);
    });

    test('an answer whose counters do not cover the batch is not trusted', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 100);
      h.steps('2026-10-17', 8, 100);
      h.uploader.silent = true;
      final r = await h.run();
      expect(r.outcome, SyncOutcome.error);
      expect(r.failureReasons[_steps], ActivityFailure.answerMismatch);
      expect(await h.sync.store.sent(h.link.scope, _steps), isEmpty);
    });

    test('one of two types is turned down: partial, the other type is committed', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 5, type: 'stepCount');
      h.steps('2026-10-18', 8, 5, type: 'flightsClimbed');
      h.uploader.rejectCall = 1;
      final r = await h.run({'stepCount', 'flightsClimbed'});
      expect(r.outcome, SyncOutcome.partial);
      expect(r.failedTypes.length, 1);
      expect(r.failureReasons.values.single, ActivityFailure.rejected);
      final ok = ['stepCount', 'flightsClimbed'].firstWhere((t) => !r.failedTypes.contains(t));
      expect(await h.sync.store.anchor(h.link.scope, ok), isNotNull);
      expect(await h.sync.store.anchor(h.link.scope, r.failedTypes.single), isNull);
    });
  });

  group('progress and abort (review P3 A2)', () {
    test('progress is reported before the first and after every accepted batch', () async {
      final h = Harness();
      for (var i = 0; i < 100; i++) {
        h.steps(d('2026-10-19').addDays(-i).iso, 8, 100.0 + i);
      }
      final seen = <ActivityProgress>[];
      final r = await h.sync.syncNow(h.link, types: {_steps}, onProgress: seen.add);
      expect(r.outcome, SyncOutcome.success);
      expect(seen.map((p) => p.batchesDone), [0, 1, 2, 3]);
      expect(seen.map((p) => p.daysDone), [0, 10, 55, 100], reason: 'newest period first');
      expect(seen.every((p) => p.batchesTotal == 3 && p.daysTotal == 100), isTrue);
      expect(seen.every((p) => p.platformType == _steps && p.typeIndex == 0 && p.typeCount == 1), isTrue);
    });

    test('shouldStop ends the run between batches: accepted batches stay, no anchor, the next run goes on', () async {
      final h = Harness();
      for (var i = 0; i < 100; i++) {
        h.steps(d('2026-10-19').addDays(-i).iso, 8, 100.0 + i);
      }
      final r1 = await h.sync.syncNow(h.link, types: {_steps}, shouldStop: () => h.uploader.calls >= 1);
      expect(r1.stopped, isTrue);
      expect(r1.outcome, SyncOutcome.partial);
      expect(r1.incompleteTypes, [_steps]);
      expect(r1.failedTypes, isEmpty);
      expect(h.uploader.calls, 1);
      expect((await h.sync.store.sent(h.link.scope, _steps)).length, 10);
      expect(await h.sync.store.anchor(h.link.scope, _steps), isNull);
      // the lock is free again
      final r2 = await h.run();
      expect(r2.outcome, SyncOutcome.success);
      expect(r2.stopped, isFalse);
      expect(r2['days_sent'], 90);
      expect(h.rows.length, 100);
    });

    test('shouldStop before the first type reads and sends nothing', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 100);
      final r = await h.sync.syncNow(h.link, types: {_steps, 'flightsClimbed'}, shouldStop: () => true);
      expect(r.stopped, isTrue);
      expect(r.incompleteTypes, [_steps, 'flightsClimbed']);
      expect(h.store.calls, isEmpty);
      expect(h.uploader.calls, 0);
    });

    test('stopping between two types keeps the finished one', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 5, type: 'stepCount');
      h.steps('2026-10-18', 8, 5, type: 'flightsClimbed');
      final r = await h.sync.syncNow(h.link,
          types: {'stepCount', 'flightsClimbed'}, shouldStop: () => h.uploader.calls >= 1);
      expect(r.stopped, isTrue);
      expect(r.incompleteTypes, ['flightsClimbed']);
      expect(await h.sync.store.anchor(h.link.scope, 'stepCount'), isNotNull);
      expect(await h.sync.store.anchor(h.link.scope, 'flightsClimbed'), isNull);
    });

    test('every accepted batch renews the run lock, so a long run is not taken over as stale', () async {
      final h = Harness();
      final scope = h.link.scope;
      final t0 = DateTime.utc(2026, 10, 19, 12);
      expect(await h.state.acquireRunLock(scope, t0), isTrue);
      await h.state.renewRunLock(scope, t0.add(const Duration(minutes: 9)));
      expect(await h.state.acquireRunLock(scope, t0.add(const Duration(minutes: 15))), isFalse);
      await h.state.releaseRunLock(scope);
    });
  });

  group('time zone of the server (review A3)', () {
    test('a changed timezone_id sends the whole look-back again', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 100);
      h.steps('2026-10-10', 8, 200);
      await h.run();
      expect(await h.sync.store.serverTimeZone(h.link.scope), 'Europe/Berlin');
      h.uploader.batches.clear();
      h.uploader.timezoneId = 'America/New_York';
      h.steps('2026-10-19', 9, 1); // some change so that the run has work
      final r = await h.run();
      expect(r.timezoneChanged, isTrue);
      expect(r['timezone_resend'], 1);
      final resent = h.uploader.all.map((x) => x.day.iso).toSet();
      expect(resent, containsAll(['2026-10-10', '2026-10-18', '2026-10-19']));
      // Stable afterwards.
      h.uploader.batches.clear();
      final r2 = await h.run();
      expect(r2.timezoneChanged, isFalse);
      expect(h.uploader.batches, isEmpty);
    });

    test('noteServerTimeZone: first value is not a change', () async {
      final h = Harness();
      expect(await h.sync.noteServerTimeZone(h.link.scope, 'Europe/Berlin'), isFalse);
      expect(await h.sync.noteServerTimeZone(h.link.scope, 'Europe/Berlin'), isFalse);
      expect(await h.sync.noteServerTimeZone(h.link.scope, 'Asia/Tokyo'), isTrue);
      expect(await h.sync.noteServerTimeZone(h.link.scope, null), isFalse);
    });

    test('the device zone changes: the whole look-back is read, changed days are sent', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 100);
      await h.run();
      h.uploader.batches.clear();
      h.store.zone = 'Asia/Tokyo';
      h.steps('2026-10-19', 9, 5);
      final r = await h.run();
      expect(r['full_window_reads'], 1);
      expect(h.uploader.all.map((x) => x.day.iso), ['2026-10-19']);
    });

    test('an aborted resend does not lose the zone change: the next run finishes it, once', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 100);
      h.steps('2026-10-10', 8, 200);
      await h.run();
      h.uploader.batches.clear();
      h.uploader.timezoneId = 'America/New_York';
      h.steps('2026-10-19', 9, 1);
      final calls0 = h.uploader.calls;
      // stop as soon as the first (normal) upload is through: the resend pass starts and is cut off
      final r1 = await h.sync.syncNow(h.link, types: {_steps}, shouldStop: () => h.uploader.calls > calls0);
      expect(r1.timezoneChanged, isTrue);
      expect(r1.stopped, isTrue);
      expect(await h.sync.store.serverTimeZone(h.link.scope), 'Europe/Berlin', reason: 'zone is kept until the resend is done');
      expect(await h.sync.store.pendingTimeZone(h.link.scope), 'America/New_York');
      h.uploader.batches.clear();
      final r2 = await h.run(); // nothing new, but the resend is still open
      expect(r2.timezoneChanged, isTrue);
      expect(r2.outcome, SyncOutcome.success);
      expect(h.uploader.all.map((x) => x.day.iso).toSet(), {'2026-10-10', '2026-10-18', '2026-10-19'});
      expect(h.uploader.all.length, 3, reason: 'the look-back goes out once, not twice');
      expect(await h.sync.store.serverTimeZone(h.link.scope), 'America/New_York');
      expect(await h.sync.store.pendingTimeZone(h.link.scope), isNull);
      h.uploader.batches.clear();
      final r3 = await h.run();
      expect(r3.timezoneChanged, isFalse);
      expect(h.uploader.batches, isEmpty);
    });

    test('a failed resend stays open as well', () async {
      final h = Harness();
      h.steps('2026-10-18', 8, 100);
      await h.run();
      h.uploader.timezoneId = 'America/New_York';
      h.steps('2026-10-19', 9, 1);
      final calls0 = h.uploader.calls;
      h.uploader.failOnCall = calls0 + 2; // normal upload ok, resend fails
      final r1 = await h.run();
      expect(r1.outcome, SyncOutcome.error);
      expect(await h.sync.store.pendingTimeZone(h.link.scope), 'America/New_York');
      expect(await h.sync.store.serverTimeZone(h.link.scope), 'Europe/Berlin');
      h.uploader.failOnCall = null;
      final r2 = await h.run();
      expect(r2.outcome, SyncOutcome.success);
      expect(await h.sync.store.serverTimeZone(h.link.scope), 'America/New_York');
      expect(await h.sync.store.pendingTimeZone(h.link.scope), isNull);
    });
  });

  group('UUID index', () {
    test('keeps the recent days only, in monthly shards, and forgets the rest', () async {
      final h = Harness(config: const ActivityDailyConfig(indexDays: 10));
      h.steps('2026-10-18', 8, 1, uuid: 'recent');
      h.steps('2026-10-05', 8, 1, uuid: 'too-old');
      await h.run();
      final scope = h.link.scope;
      final found = await h.sync.store.lookup(scope, _steps, {'recent', 'too-old'});
      expect(found.keys, ['recent']);
      expect(found['recent'], {d('2026-10-18')});
      expect(h.kv.data.keys.where((k) => k.contains('/activity/idx/')), ['user-a/profile-a/apple_health/activity/idx/stepCount/2026-10']);
    });

    test('a deleted UUID outside the index window falls back to the full read, not to a delete', () async {
      final h = Harness(config: const ActivityDailyConfig(indexDays: 10));
      h.steps('2026-09-01', 8, 700, uuid: 'old');
      h.steps('2026-10-18', 8, 300);
      await h.run();
      h.uploader.batches.clear();
      h.store.remove(_steps, 'old');
      final r = await h.run();
      expect(r['unknown_deletions'], 1);
      expect(r.emptiedDays[_steps], [d('2026-09-01')]);
      expect(h.uploader.batches, isEmpty);
    });

    test('multi-day samples are stored with all their days', () async {
      final h = Harness();
      h.store.add(_steps, DateTime.utc(2026, 10, 17, 23, 0), DateTime.utc(2026, 10, 19, 1, 0), 100, uuid: 'long');
      await h.run();
      final found = await h.sync.store.lookup(h.link.scope, _steps, {'long'});
      expect(found['long'], {d('2026-10-17'), d('2026-10-18'), d('2026-10-19')});
    });

    test('paged reference queries are followed to the end', () async {
      final h = Harness(config: const ActivityDailyConfig(refsPageLimit: 3));
      for (var i = 0; i < 10; i++) {
        h.steps('2026-10-18', 8, 1, minutes: 1, uuid: 's$i');
      }
      await h.run();
      final found = await h.sync.store.lookup(h.link.scope, _steps, {for (var i = 0; i < 10; i++) 's$i'});
      expect(found.length, 10);
      expect(h.row('2026-10-18'), 10);
    });
  });

  group('state outside the backup (review P3 A3)', () {
    late Directory dir;
    late FileKeyValueStore files;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('ah_activity_state_');
      files = FileKeyValueStore(Directory('${dir.path}/state'));
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<List<String>> activityKeys(KeyValueStore s) async => [for (final k in await s.keys()) if (k.contains('/activity/')) k];

    test('with a separate store no health data reaches the main (SharedPreferences) store', () async {
      final h = Harness(activityKv: files);
      h.steps('2026-10-18', 8, 100, uuid: 'x1');
      h.steps('2026-10-17', 8, 50, uuid: 'x2');
      final r = await h.run();
      expect(r.outcome, SyncOutcome.success);
      expect(await activityKeys(h.kv), isEmpty);
      final keys = await activityKeys(files);
      expect(keys, containsAll(<String>[
        'user-a/profile-a/apple_health/activity/anchor/stepCount',
        'user-a/profile-a/apple_health/activity/sent/stepCount',
        'user-a/profile-a/apple_health/activity/idx/stepCount/2026-10',
        'user-a/profile-a/apple_health/activity/server_tz',
      ]));
      // nothing but the engine's other keys (lock is gone) in the main store
      for (final v in h.kv.data.values) {
        expect(v.contains('2026-10-18'), isFalse, reason: 'no per-day value in the main store');
      }
      // and an incremental run works from the files alone
      h.uploader.batches.clear();
      h.steps('2026-10-19', 9, 7);
      final r2 = await h.run();
      expect(r2.outcome, SyncOutcome.success);
      expect(h.uploader.all.map((x) => x.day.iso), ['2026-10-19']);
    });

    test('state of an earlier version is moved to the files and removed from the main store; nothing is sent again', () async {
      // earlier version: everything in one store
      final old = Harness();
      old.steps('2026-10-18', 8, 100, uuid: 'x1');
      old.steps('2026-10-17', 8, 50, uuid: 'x2');
      await old.run();
      final legacyKeys = await activityKeys(old.kv);
      expect(legacyKeys.length, greaterThan(2));
      final other = '${old.link.scope.prefix}sync_token/heartRate';
      await old.kv.set(other, 'keep me'); // not ours: must stay
      // new version on the same data
      final state = SyncStateStore(old.kv, activityKv: files);
      final sync = ActivityDailySync(
          bridge: old.store,
          catalog: testCatalog(),
          state: state,
          uploader: old.uploader,
          session: const FixedSession('user-a', 'profile-a'),
          calendar: const UtcCalendar(),
          clock: () => _now);
      old.uploader.batches.clear();
      final r = await sync.syncNow(old.link, types: {_steps});
      expect(r.outcome, SyncOutcome.success);
      expect(r['migrated_keys'], legacyKeys.length);
      expect(await activityKeys(old.kv), isEmpty, reason: 'deleted from SharedPreferences after the takeover');
      expect(await old.kv.get(other), 'keep me');
      expect((await activityKeys(files)).toSet(), legacyKeys.toSet());
      expect(old.uploader.batches, isEmpty, reason: 'anchor and sent values came along');
      // the index came along too: a deletion is found through it, not through the full read
      old.store.remove(_steps, 'x1');
      final r2 = await sync.syncNow(old.link, types: {_steps});
      expect(r2['unknown_deletions'], 0);
      expect(r2.emptiedDays[_steps], [d('2026-10-18')]);
      // second start: nothing left to move
      final r3 = await sync.syncNow(old.link, types: {_steps});
      expect(r3['migrated_keys'], 0);
    });

    test('a key that already exists in the state store wins; the old one is just removed', () async {
      final h = Harness(activityKv: files);
      const k = 'user-a/profile-a/apple_health/activity/server_tz';
      await h.kv.set(k, 'Asia/Tokyo');
      await files.set(k, 'Europe/Berlin');
      expect(await h.state.activityKv!.get(k), 'Europe/Berlin');
      h.steps('2026-10-18', 8, 1);
      await h.run();
      expect(await h.kv.get(k), isNull);
      expect(await files.get(k), 'Europe/Berlin');
    });

    test('if the takeover fails, the old keys stay and the run goes on', () async {
      final old = Harness();
      old.steps('2026-10-18', 8, 100);
      await old.run();
      final legacyKeys = await activityKeys(old.kv);
      final broken = _FailingStore(files)..failSet = true;
      final sync = ActivityDailySync(
          bridge: old.store,
          catalog: testCatalog(),
          state: SyncStateStore(old.kv, activityKv: broken),
          uploader: old.uploader,
          session: const FixedSession('user-a', 'profile-a'),
          calendar: const UtcCalendar(),
          clock: () => _now);
      final r = await sync.syncNow(old.link, types: {_steps});
      expect(r['migration_failed'], 1);
      expect((await activityKeys(old.kv)).toSet(), legacyKeys.toSet(), reason: 'nothing lost');
    });

    test('forget() and resetUser clear both stores, also leftovers in the main store', () async {
      final h = Harness(activityKv: files);
      h.steps('2026-10-18', 8, 100);
      await h.run();
      await h.kv.set('user-a/profile-a/apple_health/activity/sent/flightsClimbed', '{}'); // leftover
      await h.sync.forget(h.link.scope);
      expect(await activityKeys(files), isEmpty);
      expect(await activityKeys(h.kv), isEmpty);
      await h.run();
      expect(await activityKeys(files), isNotEmpty);
      await h.kv.set('user-a/profile-a/apple_health/activity/sent/stepCount', '{}');
      await h.state.resetUser('user-a');
      expect(await activityKeys(files), isEmpty);
      expect(await activityKeys(h.kv), isEmpty);
    });

    test('forget(types) removes a leftover of that type in the main store too, so it cannot come back', () async {
      final h = Harness(activityKv: files);
      await h.kv.set('user-a/profile-a/apple_health/activity/sent/stepCount', '{"2026-10-18":1}');
      await h.kv.set('user-a/profile-a/apple_health/activity/anchor/stepCount', '{"a":"1","lb":365}');
      await h.sync.forget(h.link.scope, types: [_steps]);
      h.steps('2026-10-18', 8, 100);
      final r = await h.run();
      expect(r['migrated_keys'], 0);
      expect(h.row('2026-10-18'), 100);
    });

    test('the UUID index covers 7 days by default', () async {
      expect(const ActivityDailyConfig().indexDays, 7);
      final h = Harness(activityKv: files);
      h.steps('2026-10-19', 8, 1, uuid: 'today');
      h.steps('2026-10-13', 8, 1, uuid: 'seven');
      h.steps('2026-10-12', 8, 1, uuid: 'eight');
      await h.run();
      final found = await h.sync.store.lookup(h.link.scope, _steps, {'today', 'seven', 'eight'});
      expect(found.keys.toSet(), {'today', 'seven'});
      // deleting an older sample still ends up right: full read, compare, no delete
      h.uploader.batches.clear();
      h.store.remove(_steps, 'eight');
      final r = await h.run();
      expect(r['unknown_deletions'], 1);
      expect(h.uploader.batches, isEmpty);
      expect(r.emptiedDays[_steps], [d('2026-10-12')]);
    });
  });
}

/// Store that can be made to fail on writes.
class _FailingStore implements KeyValueStore {
  _FailingStore(this.inner);
  final KeyValueStore inner;
  bool failSet = false;
  @override
  Future<String?> get(String key) => inner.get(key);
  @override
  Future<void> set(String key, String value) async {
    if (failSet) throw const FileSystemException('disk full');
    await inner.set(key, value);
  }

  @override
  Future<void> remove(String key) => inner.remove(key);
  @override
  Future<Iterable<String>> keys() => inner.keys();
}
