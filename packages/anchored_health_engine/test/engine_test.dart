import 'package:flutter_test/flutter_test.dart';
import 'package:anchored_health_engine/anchored_health_engine.dart';

import 'support/fakes.dart';

void main() {
  group('iOS (anchor per type)', () {
    test('first run imports history and stores the anchor; second run 0 new rows', () async {
      final h = EngineHarness();
      h.bridge.addAll([
        sample(id: 'w1', value: 70.2, at: DateTime.utc(2024, 1, 1)),
        sample(id: 'w2', value: 70.6, at: DateTime.utc(2026, 9, 1)),
      ]);
      final r1 = await h.sync({'bodyMass'});
      expect(r1.outcome, SyncOutcome.success);
      expect(r1['imported'], 2, reason: 'discrete = everything the health store permits');
      expect((await h.state.token(h.link.scope, 'bodyMass'))!.value, '2');

      final r2 = await h.sync({'bodyMass'});
      expect(r2['imported'], 0);
      expect(h.uploader.rows, hasLength(2));
      expect(h.bridge.calls.last, startsWith('changes:bodyMass:2:'));
    });

    test('anchor only advances after a successful upload; retry imports the rest', () async {
      final h = EngineHarness();
      h.bridge.add(sample(id: 'w1'));
      h.uploader.failImports = 1;
      final r1 = await h.sync({'bodyMass'});
      expect(r1.outcome, SyncOutcome.error);
      expect(r1.failedTypes, ['bodyMass']);
      expect(await h.state.token(h.link.scope, 'bodyMass'), isNull);
      final r2 = await h.sync({'bodyMass'});
      expect(r2.outcome, SyncOutcome.success);
      expect(r2['imported'], 1);
    });

    test('paging: failure after page 1 resumes at page 2, first-run window stays', () async {
      final h = EngineHarness(pageLimit: 2);
      final now = h.clockNow;
      // Heart rate is series => first run from now-90 days.
      h.bridge.addAll([
        sample(id: 'old', type: 'heartRate', value: 60, unit: 'count/min', at: now.subtract(const Duration(days: 200))),
        for (var i = 0; i < 4; i++)
          sample(id: 'hr$i', type: 'heartRate', value: 60.0 + i, unit: 'count/min', at: now.subtract(Duration(days: 10 - i))),
      ]);
      // Page 1 succeeds, page 2 fails.
      final r1 = await _syncWithFailureOnSecondBatch(h, {'heartRate'});
      expect(r1.outcome, SyncOutcome.error);
      final tok = await h.state.token(h.link.scope, 'heartRate');
      expect(tok!.firstRunComplete, isFalse);
      expect(tok.firstRunFrom, now.subtract(const Duration(days: 90)));

      final r2 = await h.sync({'heartRate'});
      expect(r2.outcome, SyncOutcome.success);
      expect(h.uploader.rows.keys.toSet(), {'hr0', 'hr1', 'hr2', 'hr3'}, reason: 'old sample outside 90 days is never imported');
      expect((await h.state.token(h.link.scope, 'heartRate'))!.firstRunComplete, isTrue);
      final from = now.subtract(const Duration(days: 90)).toIso8601String();
      expect(h.bridge.calls, contains('changes:heartRate:3:$from'), reason: 'continuation with anchor AND first-run window');
      expect(h.uploader.seriesBatches, isNotEmpty, reason: 'heart rate goes through the series path');
    });

    test('deletions go to applyDeletions', () async {
      final h = EngineHarness();
      h.bridge.add(sample(id: 'w1'));
      await h.sync({'bodyMass'});
      h.bridge.deleteId('bodyMass', 'w1');
      final r = await h.sync({'bodyMass'});
      expect(h.uploader.deleted, ['w1']);
      expect(r['deleted'], 1);
    });

    test('blood pressure: correlation becomes one record with value_secondary', () async {
      final h = EngineHarness();
      h.bridge.add(sample(id: 'corr-1', type: 'bloodPressure', sys: 128, dia: 82, unit: 'mmHg'));
      await h.sync({'bloodPressure'});
      final row = h.uploader.rows['corr-1']!;
      expect(row.vitalTypeId, 'vt-bp');
      expect(row.valueNumeric, 128);
      expect(row.valueSecondary, 82);
    });

    test('echo: own exports and iCloud copies never come back', () async {
      final h = EngineHarness(ledger: InMemoryExportLedger(platformRecordIds: {'hk-own'}));
      h.bridge.addAll([
        sample(id: 'a', source: ownBundle),
        sample(id: 'b', source: 'com.apple.Health', syncIdentifier: 'myapp:row-5'),
        sample(id: 'hk-own', source: 'com.apple.Health'),
        sample(id: 'c', value: 71),
      ]);
      final r = await h.sync({'bodyMass'});
      expect(h.uploader.rows.keys, ['c']);
      expect(r['echo_dropped'], 3);
      expect(r.ledgerPatches.single.sourceRowId, 'row-5');
    });

    test('EngineConfig defaults are neutral placeholders', () {
      const c = EngineConfig();
      expect(c.ownSourcePackages, {'com.example.app'});
      expect(c.syncIdentifierPrefix, 'app:');
    });

    test('duplicate via content_hash (second device, different id)', () async {
      final h = EngineHarness();
      h.bridge.addAll([sample(id: 'ipad-1', value: 70), sample(id: 'iphone-1', value: 70)]);
      final r = await h.sync({'bodyMass'});
      expect(r['imported'], 1);
      expect(r['duplicates'], 1);
    });

    test('session mismatch => no read, no upload', () async {
      final h = EngineHarness(session: const FixedSession('user-b', 'profile-a'));
      h.bridge.add(sample(id: 'w1'));
      final r = await h.sync({'bodyMass'});
      expect(r.outcome, SyncOutcome.sessionMismatch);
      expect(h.bridge.calls, isEmpty);
      expect(h.uploader.batches, isEmpty);
      expect(h.kv.data, isEmpty);
    });

    test('run lock: parallel run is rejected', () async {
      final h = EngineHarness();
      await h.state.acquireRunLock(h.link.scope, h.clockNow);
      final r = await h.sync({'bodyMass'});
      expect(r.outcome, SyncOutcome.locked);
    });

    test('partial success: unknown type => partial, rest runs', () async {
      final h = EngineHarness();
      h.bridge.add(sample(id: 'w1'));
      final r = await h.sync({'bodyMass', 'stepCount'});
      expect(r.outcome, SyncOutcome.partial);
      expect(r.failedTypes, ['stepCount']);
      expect(r['imported'], 1);
    });

    test('run log contains counters only, no values', () async {
      final h = EngineHarness();
      h.bridge.add(sample(id: 'w1', value: 70.2));
      await h.sync({'bodyMass'});
      final log = h.uploader.logs.single;
      expect(log.counters.toString().contains('70.2'), isFalse);
    });
  });

  group('glucose: single value vs. series (CGM)', () {
    test('Dexcom G7 => series path, meter => single value; series only 14 days in first run', () async {
      final h = EngineHarness();
      final now = h.clockNow;
      h.bridge.addAll([
        sample(id: 'meter-1', type: 'bloodGlucose', value: 95, unit: 'mg/dL', source: 'com.example.meter', at: DateTime.utc(2025, 3, 1)),
        for (var i = 0; i < 12; i++)
          sample(
              id: 'g7-$i',
              type: 'bloodGlucose',
              value: 100.0 + i,
              unit: 'mg/dL',
              source: 'com.dexcom.g7app',
              at: now.subtract(const Duration(hours: 4)).add(Duration(minutes: 5 * i))),
        sample(id: 'g7-old', type: 'bloodGlucose', value: 99, unit: 'mg/dL', source: 'com.dexcom.g7app', at: now.subtract(const Duration(days: 30))),
      ]);
      final r = await h.sync({'bloodGlucose'});
      expect(r.outcome, SyncOutcome.success);
      expect(h.uploader.rows['meter-1']!.vitalTypeId, 'vt-glucose');
      expect(h.uploader.seriesBatches.single.vitalTypeId, 'vt-cgm');
      expect(h.uploader.seriesBatches.single.length, 12);
      expect(h.uploader.seriesBatches.single.sourcePackage, 'com.dexcom.g7app');
      expect(r['skipped_outside_window'], 1);
      expect(await h.prefs.preferredSource('profile-a', VitalKey.glucoseSensor), 'com.dexcom.g7app');
      expect(await h.state.seriesSources(h.link.scope), {'com.dexcom.g7app'});
      final params = h.uploader.seriesBatches.single.toRpcParams('link-1');
      expect((params['measured_at'] as List).length, 12);
      expect(params.keys, containsAll(['link_id', 'vital_type_id', 'source_package', 'value_numeric', 'external_id', 'content_hash']));
    });

    test('second series source is not uploaded but reported as source_detected', () async {
      final h = EngineHarness();
      await h.prefs.setPreferredSource('profile-a', VitalKey.glucoseSensor, 'com.dexcom.g7app');
      final now = h.clockNow;
      h.bridge.addAll([
        for (var i = 0; i < 6; i++)
          sample(id: 'x$i', type: 'bloodGlucose', value: 110, unit: 'mg/dL', source: 'com.example.cgmreader', at: now.subtract(Duration(minutes: 5 * i + 10))),
      ]);
      final r = await h.sync({'bloodGlucose'});
      expect(h.uploader.seriesBatches, isEmpty);
      expect(r['skipped_other_source'], 6);
      expect(r.detectedSources, {'com.example.cgmreader'});
      expect(h.uploader.logs.where((l) => l.event == 'source_detected'), hasLength(1));
    });

    test('series chunks: 2,500 values => chunks of 1,000', () async {
      final h = EngineHarness(pageLimit: 0);
      final now = h.clockNow;
      h.bridge.addAll([
        for (var i = 0; i < 2500; i++)
          sample(id: 'g$i', type: 'bloodGlucose', value: 100, unit: 'mg/dL', source: 'com.dexcom.g7app', at: now.subtract(Duration(minutes: i + 1))),
      ]);
      await h.sync({'bloodGlucose'});
      expect(h.uploader.seriesBatches.map((b) => b.length), [1000, 1000, 500]);
    });

    test('loading an older window: 7-day windows with cursor, anchor untouched', () async {
      final h = EngineHarness();
      final now = h.clockNow;
      h.bridge.addAll([
        for (var d = 1; d <= 20; d++)
          for (var i = 0; i < 6; i++)
            sample(id: 'g$d-$i', type: 'bloodGlucose', value: 100, unit: 'mg/dL', source: 'com.dexcom.g7app', at: now.subtract(Duration(days: d, minutes: 5 * i))),
      ]);
      await h.sync({'bloodGlucose'});
      final anchorBefore = (await h.state.token(h.link.scope, 'bloodGlucose'))!.value;
      final imported14 = h.uploader.rows.length;
      final r = await h.engine.extendBackfill(h.link, 'bloodGlucose',
          from: now.subtract(const Duration(days: 21)), to: now.subtract(const Duration(days: 14)));
      expect(r.outcome, SyncOutcome.success);
      expect(r['windows_done'], 1);
      expect(h.uploader.rows.length, greaterThan(imported14));
      expect((await h.state.token(h.link.scope, 'bloodGlucose'))!.value, anchorBefore);
      expect(await h.state.backfillCursor(h.link.scope, 'bloodGlucose'), isNull);
    });
  });

  group('Android semantics (changes token)', () {
    test('baseline token before backfill, then changes; blood pressure halves paired', () async {
      final h = EngineHarness(platform: HealthPlatform.healthConnect);
      final now = h.clockNow;
      // `health` delivers one BloodPressureRecord as two entries with the same uuid.
      h.bridge.addAs('BloodPressureRecord',
          sample(id: 'r1', type: 'bloodPressureSystolic', value: 131, at: now.subtract(const Duration(days: 2))));
      h.bridge.addAs('BloodPressureRecord',
          sample(id: 'r1', type: 'bloodPressureDiastolic', value: 84, at: now.subtract(const Duration(days: 2))));
      final r1 = await h.sync({'BloodPressureRecord'});
      expect(h.bridge.calls.take(2).toList(), ['baseline:BloodPressureRecord', startsWith('read:BloodPressureRecord')]);
      expect(r1['imported'], 1);
      final row = h.uploader.rows['r1']!;
      expect(row.valueNumeric, 131);
      expect(row.valueSecondary, 84);
      expect(row.externalVersion, isNull, reason: 'Android delivers no version');

      h.bridge.addAs('BloodPressureRecord',
          sample(id: 'r2', type: 'bloodPressureSystolic', value: 125, at: now.subtract(const Duration(hours: 1))));
      h.bridge.addAs('BloodPressureRecord',
          sample(id: 'r2', type: 'bloodPressureDiastolic', value: 80, at: now.subtract(const Duration(hours: 1))));
      h.bridge.addAs('BloodPressureRecord',
          sample(id: 'r3', type: 'bloodPressureSystolic', value: 140, at: now.subtract(const Duration(minutes: 5))));
      final r2 = await h.sync({'BloodPressureRecord'});
      expect(r2['imported'], 1);
      expect(r2['unpaired'], 1, reason: 'half without counterpart is counted, not guessed');
      expect(h.bridge.calls.last, startsWith('changes:BloodPressureRecord:2:'));
    });

    test('changesTokenExpired => re-read window (30 days) and new token', () async {
      final h = EngineHarness(platform: HealthPlatform.healthConnect);
      final now = h.clockNow;
      h.bridge.add(sample(id: 'w1', type: 'WeightRecord', at: now.subtract(const Duration(days: 3))));
      await h.sync({'WeightRecord'});
      h.bridge.add(sample(id: 'w2', type: 'WeightRecord', value: 71, at: now.subtract(const Duration(days: 1))));
      h.bridge.expireTokenFor.add('WeightRecord');
      h.clockNow = now.add(const Duration(hours: 1));
      final r = await h.sync({'WeightRecord'});
      expect(r['reread'], 1);
      expect(h.uploader.rows.keys.toSet(), {'w1', 'w2'});
      expect(r['imported'], 1, reason: 'w1 is a duplicate');
      expect(await h.state.token(h.link.scope, 'WeightRecord'), isNotNull);
    });

    test('token older than 25 days => re-read window', () async {
      final h = EngineHarness(platform: HealthPlatform.healthConnect);
      h.bridge.add(sample(id: 'w1', type: 'WeightRecord', at: h.clockNow.subtract(const Duration(days: 1))));
      await h.sync({'WeightRecord'});
      h.clockNow = h.clockNow.add(const Duration(days: 26));
      final r = await h.sync({'WeightRecord'});
      expect(r['reread'], 1);
    });

    test('throttling: background/resume run < 15 min after the last run => throttled', () async {
      final h = EngineHarness(platform: HealthPlatform.healthConnect);
      await h.sync({'WeightRecord'});
      h.clockNow = h.clockNow.add(const Duration(minutes: 5));
      final r = await h.sync({'WeightRecord'}, trigger: SyncTrigger.resume);
      expect(r.outcome, SyncOutcome.throttled);
    });
  });
}

/// Makes the second import batch fail (page 2 of a first run).
Future<SyncRunResult> _syncWithFailureOnSecondBatch(EngineHarness h, Set<String> types) async {
  final failing = _FailSecond(h.uploader);
  final engine = HealthSyncEngine(
    bridge: h.bridge,
    catalog: testCatalog(),
    state: h.state,
    uploader: failing,
    ledger: h.ledger,
    session: const FixedSession('user-a', 'profile-a'),
    config: const EngineConfig(ownSourcePackages: {ownBundle}, syncIdentifierPrefix: ownPrefix, pageLimit: 2),
    preferences: h.prefs,
    clock: () => h.clockNow,
  );
  return engine.syncNow(h.link, types: types);
}

class _FailSecond implements HealthUploader {
  _FailSecond(this.inner);
  final FakeUploader inner;
  int n = 0;
  @override
  Future<ImportBatchResult> importBatch(String linkId, List<VitalRecord> records) {
    if (++n == 2) throw StateError('network down');
    return inner.importBatch(linkId, records);
  }

  @override
  Future<SeriesBatchResult> importSeriesBatch(String linkId, SeriesBatch batch) {
    if (++n == 2) throw StateError('network down');
    return inner.importSeriesBatch(linkId, batch);
  }
  @override
  Future<int> applyDeletions(String linkId, List<String> externalIds) => inner.applyDeletions(linkId, externalIds);
  @override
  Future<void> logRun(String linkId, SyncRunLog log) => inner.logRun(linkId, log);
}
