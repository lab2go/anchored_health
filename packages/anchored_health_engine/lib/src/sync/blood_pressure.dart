import '../models.dart';

/// Blood pressure is **one** vital type: systolic in `value_numeric`,
/// diastolic in `value_secondary`. This class joins halves delivered
/// separately into one record; halves that cannot be paired are reported,
/// never guessed.
class BloodPressurePairing {
  const BloodPressurePairing({
    this.systolicType = 'bloodPressureSystolic',
    this.diastolicType = 'bloodPressureDiastolic',
    this.pairedType = 'bloodPressure',
  });

  final String systolicType;
  final String diastolicType;
  final String pairedType;

  /// Android (package `health`): one `BloodPressureRecord` arrives as two
  /// upsert entries with the **same** `uuid`. Pairing via
  /// [HealthSample.externalId].
  BloodPressurePairResult pairBySameId(List<HealthSample> samples) =>
      _pair(samples, (s) => s.externalId, (sys, dia) => sys.externalId);

  /// iOS fallback: anchors on both quantity types, pairing via start, end and
  /// source. `external_id` = UUID of the systolic sample.
  BloodPressurePairResult pairByTimeAndSource(List<HealthSample> samples) => _pair(
        samples,
        (s) => '${s.start.toUtc().microsecondsSinceEpoch}|'
            '${s.end.toUtc().microsecondsSinceEpoch}|${s.sourcePackage}',
        (sys, dia) => sys.externalId,
      );

  BloodPressurePairResult _pair(
    List<HealthSample> samples,
    String Function(HealthSample) key,
    String Function(HealthSample sys, HealthSample dia) idOf,
  ) {
    final others = <HealthSample>[];
    final sys = <String, HealthSample>{};
    final dia = <String, HealthSample>{};
    final order = <String>[];
    for (final s in samples) {
      if (s.platformType == systolicType || s.platformType == diastolicType) {
        final k = key(s);
        final target = s.platformType == systolicType ? sys : dia;
        if (!sys.containsKey(k) && !dia.containsKey(k)) order.add(k);
        target[k] = s;
      } else {
        others.add(s);
      }
    }
    final paired = <HealthSample>[];
    final unpaired = <HealthSample>[];
    for (final k in order) {
      final s = sys[k];
      final d = dia[k];
      if (s != null && d != null && s.value != null && d.value != null) {
        paired.add(s.copyWith(
          externalId: idOf(s, d),
          platformType: pairedType,
          systolic: s.value,
          diastolic: d.value,
        ));
      } else {
        if (s != null) unpaired.add(s);
        if (d != null) unpaired.add(d);
      }
    }
    return BloodPressurePairResult([...others, ...paired], unpaired);
  }
}

class BloodPressurePairResult {
  const BloodPressurePairResult(this.samples, this.unpaired);

  /// All non-blood-pressure samples plus paired blood pressure records.
  final List<HealthSample> samples;

  /// Halves without a counterpart (counted, not uploaded).
  final List<HealthSample> unpaired;
}
