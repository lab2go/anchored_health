import 'package:flutter_test/flutter_test.dart';
import 'package:anchored_health_engine/anchored_health_engine.dart';
import 'support/fakes.dart';

void main() {
  final catalog = testCatalog();
  const mapper = VitalMapper();
  for (final c in <(VitalKey, String, String, double)>[
    (VitalKey.hrvSdnn, 'heartRateVariabilitySDNN', 'ms', 43.125),
    (VitalKey.vo2Max, 'vo2Max', 'ml/kg/min', 42.375),
  ]) {
    test('${c.$1.name}: precision, raw interval, provenance, no export', () {
      final entry = catalog.entryFor(HealthPlatform.appleHealth, c.$2, c.$1)!;
      final r = mapper.map(HealthSample(externalId: 'synthetic-1', platformType: c.$2,
          start: t0, end: t0.add(const Duration(minutes: 1)), value: c.$4,
          unit: c.$3, sourcePackage: 'example.watch', sourceName: 'Example source'), entry).record!;
      expect(r.valueNumeric, c.$4);
      expect(r.unit, c.$3);
      expect(r.endAt, t0.add(const Duration(minutes: 1)));
      expect(r.toJson()['granularity'], 'raw');
      expect(r.sourcePackage, 'example.watch');
      expect(r.sourceName, 'Example source');
      expect(entry.importSupported, isTrue);
      expect(entry.exportSupported, isFalse);
      expect(entry.backfillClass, BackfillClass.discrete);
      expect(catalog.exportEntry(HealthPlatform.appleHealth, c.$1), isNull);
      expect(mapper.map(sample(id: 'bad', type: c.$2, unit: 'wrong'), entry).skip,
          MappingSkip.incompatibleUnit);
      expect(mapper.map(sample(id: 'no-id', type: c.$2, unit: c.$3),
          TypeCatalog.v1Default().entryFor(HealthPlatform.appleHealth, c.$2, c.$1)).skip,
          MappingSkip.noVitalTypeId);
    });
  }
  test('SDNN never uses RMSSD on Health Connect', () {
    expect(catalog.entries.where((e) => e.platform == HealthPlatform.healthConnect &&
        e.vitalKey == VitalKey.hrvSdnn), isEmpty);
    expect(catalog.forPlatformType(HealthPlatform.healthConnect, 'HeartRateVariabilityRmssdRecord'), isEmpty);
    expect(catalog.importPlatformTypes(HealthPlatform.appleHealth),
        containsAll(<String>['heartRateVariabilitySDNN', 'vo2Max']));
  });
}
