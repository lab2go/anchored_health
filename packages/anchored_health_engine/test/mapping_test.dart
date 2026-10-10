import 'package:flutter_test/flutter_test.dart';
import 'package:anchored_health_engine/anchored_health_engine.dart';

import 'support/fakes.dart';

void main() {
  final catalog = testCatalog();
  const mapper = VitalMapper();
  const ios = HealthPlatform.appleHealth;

  group('catalog v1', () {
    test('every v1 vital type is importable on iOS and Android', () {
      for (final p in HealthPlatform.values) {
        final keys = catalog.entries.where((e) => e.platform == p && e.importSupported).map((e) => e.vitalKey).toSet();
        expect(keys, VitalKey.values.toSet(), reason: p.id);
      }
    });

    test('bloodGlucose has exactly two targets: single value and series', () {
      final e = catalog.forPlatformType(ios, 'bloodGlucose');
      expect(e.map((x) => x.vitalKey).toSet(), {VitalKey.bloodGlucose, VitalKey.glucoseSensor});
      final series = e.firstWhere((x) => x.vitalKey == VitalKey.glucoseSensor);
      expect(series.backfillClass, BackfillClass.series);
      expect(series.backfillDefaultDays, 14);
      expect(series.backfillCapDays, 90);
      expect(series.exportSupported, isFalse, reason: 'series are never exported');
    });

    test('series allowlist contains Dexcom G7 and prefix patterns', () {
      final series = catalog.entryFor(ios, 'bloodGlucose', VitalKey.glucoseSensor)!;
      expect(series.matchesSeriesSource('com.dexcom.g7app'), isTrue);
      expect(series.matchesSeriesSource('com.dexcom.G6.OUS.de'), isTrue);
      expect(series.matchesSeriesSource('com.example.meter'), isFalse);
      expect(seriesPatternMatches('com.dexcom.g7app', 'com.dexcom.g7app.extra'), isFalse);
    });

    test('invalid series patterns are rejected', () {
      for (final bad in ['*dexcom', 'com.%', 'a*b', 'a**']) {
        expect(
            () => TypeCatalog([
                  TypeMappingEntry(
                      platform: ios,
                      platformType: 'bloodGlucose',
                      vitalKey: VitalKey.glucoseSensor,
                      unitPlatform: 'mg/dL',
                      backfillClass: BackfillClass.series,
                      seriesSources: [bad])
                ]),
            throwsArgumentError,
            reason: bad);
      }
    });

    test('sensor glucose is labelled apart from blood glucose', () {
      expect(VitalKey.glucoseSensor.label, 'Glucose (sensor)');
      expect(VitalKey.values.map((k) => k.label).toSet(), hasLength(VitalKey.values.length));
    });
  });

  group('Mapping', () {
    test('SpO2 0...1 from HealthKit becomes percent', () {
      final r = mapper
          .map(sample(id: 'a', type: 'oxygenSaturation', value: 0.97, unit: '%'),
              catalog.entryFor(ios, 'oxygenSaturation', VitalKey.oxygenSaturation))
          .record!;
      expect(r.valueNumeric, closeTo(97, 1e-9));
      expect(r.unit, '%');
    });

    test('blood pressure becomes one record: systolic + diastolic', () {
      final r = mapper
          .map(sample(id: 'bp1', type: 'bloodPressure', sys: 128, dia: 82, unit: 'mmHg'),
              catalog.entryFor(ios, 'bloodPressure', VitalKey.bloodPressure))
          .record!;
      expect(r.vitalTypeId, 'vt-bp');
      expect(r.valueNumeric, 128);
      expect(r.valueSecondary, 82);
      expect(r.unit, 'mmHg');
    });

    test('blood pressure without one half is skipped', () {
      final m = mapper.map(
          HealthSample(
              externalId: 'x',
              platformType: 'bloodPressure',
              start: t0,
              end: t0,
              systolic: 120,
              sourcePackage: 'p'),
          catalog.entryFor(ios, 'bloodPressure', VitalKey.bloodPressure));
      expect(m.skip, MappingSkip.missingValue);
    });

    test('wrong unit, missing catalog entry or vital_type_id => skipped', () {
      final entry = catalog.entryFor(ios, 'bodyMass', VitalKey.bodyWeight);
      expect(mapper.map(sample(id: 'a', unit: 'lb'), entry).skip, MappingSkip.incompatibleUnit);
      expect(mapper.map(sample(id: 'a'), null).skip, MappingSkip.noEntry);
      final noId = TypeCatalog.v1Default().entryFor(ios, 'bodyMass', VitalKey.bodyWeight);
      expect(mapper.map(sample(id: 'a'), noId).skip, MappingSkip.noVitalTypeId);
    });

    test('record carries no assessment', () {
      final r = mapper.map(sample(id: 'a', value: 72.4), catalog.entryFor(ios, 'bodyMass', VitalKey.bodyWeight)).record!;
      // Exhaustive list: adding a field like status/ref_*/zone makes this fail.
      expect(r.toJson().keys.toSet(), {
        'external_id', 'external_version', 'vital_type_id', 'platform_type', 'measured_at', 'end_at',
        'timezone_id', 'source_package', 'source_device_name', 'source_name', 'recording_method', 'value_numeric',
        'value_secondary', 'unit', 'granularity', 'content_hash', 'map_version', 'unknown_fields',
      });
    });
  });

  group('source_name', () {
    test('is carried to the record and the JSON, but not into the content hash', () {
      final entry = catalog.entryFor(ios, 'bodyMass', VitalKey.bodyWeight);
      final a = mapper.map(sample(id: 'a', value: 72.4, sourceName: 'Withings'), entry).record!;
      final b = mapper.map(sample(id: 'a', value: 72.4, sourceName: 'Other Name'), entry).record!;
      final c = mapper.map(sample(id: 'a', value: 72.4), entry).record!;
      expect(a.sourceName, 'Withings');
      expect(a.toJson()['source_name'], 'Withings');
      expect(c.toJson()['source_name'], isNull);
      expect(a.contentHash, b.contentHash, reason: 'source_name is display only');
      expect(a.contentHash, c.contentHash);
    });
  });

  group('content_hash', () {
    String h({String typeId = 'vt-weight', double v = 72.4, String src = 'com.example.scale', String? dev, DateTime? at}) =>
        ContentHash.compute(
            vitalTypeId: typeId, measuredAt: at ?? t0, valueNumeric: v, sourcePackage: src, sourceDeviceName: dev);

    test('canonical string is fixed', () {
      expect(
          ContentHash.canonicalString(
              vitalTypeId: 'vt-bp',
              measuredAt: DateTime.utc(2026, 9, 1, 8, 0, 5, 999),
              valueNumeric: 128,
              valueSecondary: 82.5,
              sourcePackage: 'com.example.cuff',
              sourceDeviceName: null),
          'vt-bp|2026-09-01T08:00:05Z||128|82.5|com.example.cuff|');
      expect(h(), hasLength(64));
    });

    test('stable across time zone and milliseconds, different per source/device/value', () {
      expect(h(at: DateTime.utc(2026, 9, 1, 8, 0, 0, 400)), h());
      expect(h(at: t0.toLocal()), h());
      expect(h(src: 'other'), isNot(h()));
      expect(h(dev: 'Watch'), isNot(h()));
      expect(h(v: 72.41), isNot(h()));
    });

    test('number format without trailing zeros', () {
      expect(ContentHash.formatNumber(72.40), '72.4');
      expect(ContentHash.formatNumber(120), '120');
      expect(ContentHash.formatNumber(0.1 + 0.2), '0.3');
      expect(ContentHash.formatNumber(-0.0), '0');
    });
  });
}
