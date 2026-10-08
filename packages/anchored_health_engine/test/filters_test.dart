import 'package:flutter_test/flutter_test.dart';
import 'package:anchored_health_engine/anchored_health_engine.dart';

import 'support/fakes.dart';

void main() {
  const ios = HealthPlatform.appleHealth;
  const hc = HealthPlatform.healthConnect;

  group('echo protection', () {
    test('stage 1: own bundle id is dropped', () async {
      final f = EchoFilter(ownSourcePackages: {ownBundle}, ledger: InMemoryExportLedger());
      final r = await f.apply(ios, [sample(id: '1', source: ownBundle), sample(id: '2')]);
      expect(r.kept.map((s) => s.externalId), ['2']);
      expect(r.dropped[EchoStage.ownSource], 1);
    });

    test('stage 2: own sync identifier prefix (iCloud copy) is dropped, ledger patch', () async {
      final f = EchoFilter(ownSourcePackages: {ownBundle}, ledger: InMemoryExportLedger());
      final r = await f.apply(ios, [
        sample(id: 'hk-1', source: 'com.apple.Health', syncIdentifier: 'app:row-1'),
        sample(id: 'hk-2', source: 'com.example.other', syncIdentifier: 'vendor:abc'),
      ]);
      expect(r.kept.map((s) => s.externalId), ['hk-2'], reason: 'foreign sync identifiers stay');
      expect(r.dropped[EchoStage.ownSyncIdentifier], 1);
      expect(r.ledgerPatches, [const LedgerPatch(sourceRowId: 'row-1', platformRecordId: 'hk-1')]);
    });

    test('stage 2: ExternalUUID in the ledger is dropped', () async {
      final f = EchoFilter(ownSourcePackages: {}, ledger: InMemoryExportLedger(sourceRowIds: {'row-9'}));
      final r = await f.apply(ios, [sample(id: 'hk-9', externalUuid: 'row-9'), sample(id: 'x', externalUuid: 'foreign')]);
      expect(r.kept.map((s) => s.externalId), ['x']);
      expect(r.ledgerPatches.single.sourceRowId, 'row-9');
    });

    test('sync identifier forms lab:, :sys, :dia yield the source row', () {
      final f = EchoFilter(ownSourcePackages: {}, ledger: InMemoryExportLedger());
      expect(f.sourceRowIdFromSyncIdentifier('app:lab:m-1'), 'm-1');
      expect(f.sourceRowIdFromSyncIdentifier('app:v-1:sys'), 'v-1');
      expect(f.sourceRowIdFromSyncIdentifier('app:v-1:dia'), 'v-1');
      expect(f.sourceRowIdFromSyncIdentifier('other:v-1'), isNull);
    });

    test('custom sync identifier prefix', () async {
      final f = EchoFilter(ownSourcePackages: {}, ledger: InMemoryExportLedger(), syncIdentifierPrefix: 'acme:');
      final r = await f.apply(ios, [
        sample(id: 'hk-1', syncIdentifier: 'acme:row-1'),
        sample(id: 'hk-2', syncIdentifier: 'app:row-2'),
      ]);
      expect(r.kept.map((s) => s.externalId), ['hk-2']);
      expect(r.ledgerPatches.single.sourceRowId, 'row-1');
    });

    test('stage 3: platform id or sync identifier in the ledger is dropped', () async {
      final f = EchoFilter(
          ownSourcePackages: {},
          ledger: InMemoryExportLedger(platformRecordIds: {'hc-1'}, syncIdentifiers: {'app:row-7'}));
      final r = await f.apply(hc, [
        sample(id: 'hc-1'),
        sample(id: 'hc-2', syncIdentifier: 'app:row-7'),
        sample(id: 'hc-3'),
      ]);
      expect(r.kept.map((s) => s.externalId), ['hc-3']);
      expect(r.dropped[EchoStage.ledger], 2);
      expect(r.dropped[EchoStage.ownSyncIdentifier], isNull, reason: 'stage 2 is iOS only');
    });
  });

  group('Dedupe', () {
    final entry = testCatalog().entryFor(ios, 'bodyMass', VitalKey.bodyWeight);
    VitalRecord rec(String id, double v, {int? version}) =>
        const VitalMapper().map(
          HealthSample(
              externalId: id,
              platformType: 'bodyMass',
              start: t0,
              end: t0,
              value: v,
              sourcePackage: 'com.example.scale',
              syncVersion: version),
          entry,
        ).record!;

    test('same external_id: the later entry wins (change log)', () async {
      final r = await const Deduper().dedupe([rec('a', 70), rec('a', 71)]);
      expect(r.kept.single.valueNumeric, 71);
      expect(r.duplicates, 1);
    });

    test('same hash with a different id (copy from another device) => duplicate', () async {
      final r = await const Deduper().dedupe([rec('a', 70), rec('b', 70)]);
      expect(r.kept.map((x) => x.externalId), ['a']);
      expect(r.duplicates, 1);
    });

    test('deleted ids and known hashes are skipped', () async {
      final known = rec('k', 80).contentHash;
      final r = await Deduper(index: InMemoryDedupeIndex(deleted: {'d'}, hashes: {known}))
          .dedupe([rec('d', 60), rec('k2', 80), rec('n', 90)]);
      expect(r.kept.map((x) => x.externalId), ['n']);
      expect(r.skippedDeleted, 1);
      expect(r.duplicates, 1);
    });
  });

  group('blood pressure pairing', () {
    HealthSample half(String id, String type, double v, {DateTime? at, String src = 'com.example.cuff'}) =>
        sample(id: id, type: type, value: v, at: at, source: src);

    test('Android: two halves with the same uuid => one record', () {
      final r = const BloodPressurePairing(pairedType: 'BloodPressureRecord').pairBySameId([
        half('r1', 'bloodPressureSystolic', 131),
        half('r1', 'bloodPressureDiastolic', 84),
        sample(id: 'w', value: 70),
      ]);
      final bp = r.samples.firstWhere((s) => s.platformType == 'BloodPressureRecord');
      expect(bp.externalId, 'r1');
      expect(bp.systolic, 131);
      expect(bp.diastolic, 84);
      expect(r.samples, hasLength(2));
      expect(r.unpaired, isEmpty);
    });

    test('unpaired half is reported, not guessed', () {
      final r = const BloodPressurePairing().pairBySameId([half('r1', 'bloodPressureSystolic', 131)]);
      expect(r.samples, isEmpty);
      expect(r.unpaired.single.externalId, 'r1');
    });

    test('iOS fallback: pairing via time and source, id = systolic sample', () {
      final r = const BloodPressurePairing().pairByTimeAndSource([
        half('s1', 'bloodPressureSystolic', 120),
        half('d1', 'bloodPressureDiastolic', 80),
        half('s2', 'bloodPressureSystolic', 125, src: 'other'),
      ]);
      expect(r.samples.single.externalId, 's1');
      expect(r.samples.single.diastolic, 80);
      expect(r.unpaired.single.externalId, 's2');
    });
  });

  group('series (CGM)', () {
    final seriesEntry = testCatalog().entryFor(ios, 'bloodGlucose', VitalKey.glucoseSensor)!;
    List<HealthSample> run(String src, int n, Duration step, {String prefix = 'g'}) => [
          for (var i = 0; i < n; i++)
            sample(id: '$prefix$i', type: 'bloodGlucose', value: 100.0 + i, source: src, at: t0.add(step * i))
        ];

    test('allowlist: Dexcom G7 is a series, a meter gives single values', () {
      final c = const SeriesClassifier().classify(
        samples: [...run('com.dexcom.g7app', 2, const Duration(minutes: 5)), sample(id: 'm', type: 'bloodGlucose', source: 'com.example.meter')],
        seriesEntry: seriesEntry,
        stickySources: {},
      );
      expect(c.series, hasLength(2));
      expect(c.single.single.externalId, 'm');
      expect(c.newlyStickySources, {'com.dexcom.g7app'});
    });

    test('density: 6 values in 60 min => series, 5 not, 6 over 61 min not', () {
      const cls = SeriesClassifier();
      expect(cls.isDense(run('x', 6, const Duration(minutes: 12))), isTrue);
      expect(cls.isDense(run('x', 5, const Duration(minutes: 5))), isFalse);
      expect(cls.isDense(run('x', 6, const Duration(minutes: 12, seconds: 13))), isFalse);
    });

    test('sticky source stays a series even with a small delta', () {
      final c = const SeriesClassifier().classify(
        samples: run('xdrip.unknown', 2, const Duration(minutes: 5)),
        seriesEntry: seriesEntry,
        stickySources: {'xdrip.unknown'},
      );
      expect(c.series, hasLength(2));
    });

    test('series source filter: first source becomes default, second is skipped', () {
      final d = const SeriesSourceFilter().apply(
        series: [...run('com.dexcom.g7app', 3, const Duration(minutes: 5)), ...run('com.example.xdrip', 2, const Duration(minutes: 5), prefix: 'x')],
        preferredSource: null,
      );
      expect(d.preferredSource, 'com.dexcom.g7app');
      expect(d.preferenceIsNew, isTrue);
      expect(d.kept, hasLength(3));
      expect(d.skippedOtherSource, 2);
      expect(d.detectedOtherSources, {'com.example.xdrip'});
    });
  });

  group('plausibility', () {
    const p = PlausibilityCheck();
    test('deviation => mismatch, agreement => match, missing data => unknown', () {
      const h = HealthCharacteristics(birthYear: 1980, biologicalSex: 'female');
      expect(p.compare(profileBirthYear: 1980, profileSex: 'weiblich', health: h), PlausibilityResult.match);
      expect(p.compare(profileBirthYear: 2015, profileSex: 'female', health: h), PlausibilityResult.mismatch);
      expect(p.compare(profileBirthYear: 1980, profileSex: 'male', health: h), PlausibilityResult.mismatch);
      expect(p.compare(profileBirthYear: null, profileSex: 'female', health: h), PlausibilityResult.unknown);
      expect(p.compare(profileBirthYear: 1980, profileSex: 'female', health: const HealthCharacteristics()),
          PlausibilityResult.unknown);
    });
  });
}
