import '../types.dart';

/// One mapping between a platform type and a [VitalKey]. Apps typically load
/// the catalog from their server; [TypeCatalog.v1Default] provides built-in
/// defaults for tests and as a fallback.
class TypeMappingEntry {
  const TypeMappingEntry({
    required this.platform,
    required this.platformType,
    required this.vitalKey,
    required this.unitPlatform,
    required this.backfillClass,
    this.factor = 1,
    this.offset = 0,
    this.backfillDefaultDays,
    this.backfillCapDays,
    this.seriesSources = const [],
    this.importSupported = true,
    this.exportSupported = false,
    this.mapVersion = 1,
    this.vitalTypeId,
  });

  final HealthPlatform platform;
  final String platformType;
  final VitalKey vitalKey;
  final String unitPlatform;

  /// canonical = platform × factor + offset
  final double factor;
  final double offset;
  final BackfillClass backfillClass;

  /// Default window when connecting; null = cap (or everything for discrete).
  final int? backfillDefaultDays;
  final int? backfillCapDays;

  /// Allowlist of series sources; patterns are exact or end with `*` (prefix).
  final List<String> seriesSources;
  final bool importSupported;
  final bool exportSupported;
  final int mapVersion;

  /// Server-side id of the vital type; without it no upload record is created.
  final String? vitalTypeId;

  String get unitCanonical => vitalKey.canonicalUnit;

  double toCanonical(double platformValue) => platformValue * factor + offset;

  double toPlatform(double canonicalValue) => (canonicalValue - offset) / factor;

  bool matchesSeriesSource(String sourcePackage) =>
      seriesSources.any((p) => seriesPatternMatches(p, sourcePackage));

  TypeMappingEntry withVitalTypeId(String id) => TypeMappingEntry(
        platform: platform,
        platformType: platformType,
        vitalKey: vitalKey,
        unitPlatform: unitPlatform,
        backfillClass: backfillClass,
        factor: factor,
        offset: offset,
        backfillDefaultDays: backfillDefaultDays,
        backfillCapDays: backfillCapDays,
        seriesSources: seriesSources,
        importSupported: importSupported,
        exportSupported: exportSupported,
        mapVersion: mapVersion,
        vitalTypeId: id,
      );
}

/// `*` is only allowed at the end (prefix match), otherwise exact match.
bool seriesPatternMatches(String pattern, String sourcePackage) {
  if (pattern.endsWith('*')) {
    return sourcePackage.startsWith(pattern.substring(0, pattern.length - 1));
  }
  return pattern == sourcePackage;
}

/// Catalog of all mappings.
class TypeCatalog {
  TypeCatalog(List<TypeMappingEntry> entries) : entries = List.unmodifiable(entries) {
    for (final e in entries) {
      for (final p in e.seriesSources) {
        if (p.isEmpty || p.startsWith('*') || p.contains('%') || p.indexOf('*') != p.lastIndexOf('*') ||
            (p.contains('*') && !p.endsWith('*'))) {
          throw ArgumentError('Invalid series source pattern: $p');
        }
      }
      if (e.backfillClass == BackfillClass.series &&
          e.backfillDefaultDays != null &&
          e.backfillCapDays != null &&
          e.backfillDefaultDays! > e.backfillCapDays!) {
        throw ArgumentError('backfill_default_days > backfill_cap_days: ${e.platformType}');
      }
    }
  }

  final List<TypeMappingEntry> entries;

  List<TypeMappingEntry> forPlatformType(HealthPlatform platform, String platformType) => entries
      .where((e) => e.platform == platform && e.platformType == platformType)
      .toList();

  TypeMappingEntry? entryFor(HealthPlatform platform, String platformType, VitalKey key) {
    for (final e in entries) {
      if (e.platform == platform && e.platformType == platformType && e.vitalKey == key) return e;
    }
    return null;
  }

  /// Export entry for a vital type (exactly one per platform).
  TypeMappingEntry? exportEntry(HealthPlatform platform, VitalKey key) {
    for (final e in entries) {
      if (e.platform == platform && e.vitalKey == key && e.exportSupported) return e;
    }
    return null;
  }

  /// Platform types that can be imported.
  Set<String> importPlatformTypes(HealthPlatform platform) => {
        for (final e in entries)
          if (e.platform == platform && e.importSupported) e.platformType
      };

  /// Inserts the server-side ids (one per [VitalKey]).
  TypeCatalog withVitalTypeIds(Map<VitalKey, String> ids) => TypeCatalog([
        for (final e in entries) ids.containsKey(e.vitalKey) ? e.withVitalTypeId(ids[e.vitalKey]!) : e
      ]);

  /// Built-in default catalog (version 1).
  factory TypeCatalog.v1Default() => TypeCatalog(_v1Entries);
}

/// Known iOS CGM apps whose glucose values are treated as a series. Bundle ids
/// of third-party apps; extend or override per app as needed.
const iosGlucoseSeriesSources = <String>[
  'com.dexcom.g7app',
  'com.dexcom.G6.OUS.*',
  'com.dexcom.dexcomoneplus',
  'com.dexcom.dexcomflex',
  'com.abbott.lingo.wellness',
  'com.senseonics.eversense365.*',
  'de.poeml.philipp.LibreWrist',
];

/// Known Android CGM apps whose glucose values are treated as a series.
const androidGlucoseSeriesSources = <String>[
  'com.dexcom.g7',
  'com.dexcom.d1plus',
  'com.dexcom.g6.region3.*',
  'com.abbott.lingo.wellness',
  'com.eveningoutpost.dexdrip',
  'tk.glucodata',
];

const _ios = HealthPlatform.appleHealth;
const _hc = HealthPlatform.healthConnect;

const _v1Entries = <TypeMappingEntry>[
  // --- Apple Health (platform types of anchored_health_native) ---
  TypeMappingEntry(
      platform: _ios,
      platformType: 'bloodPressure',
      vitalKey: VitalKey.bloodPressure,
      unitPlatform: 'mmHg',
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _ios,
      platformType: 'heartRate',
      vitalKey: VitalKey.heartRate,
      unitPlatform: 'count/min',
      backfillClass: BackfillClass.series,
      backfillDefaultDays: 90,
      backfillCapDays: 90,
      exportSupported: true),
  TypeMappingEntry(
      platform: _ios,
      platformType: 'restingHeartRate',
      vitalKey: VitalKey.restingHeartRate,
      unitPlatform: 'count/min',
      backfillClass: BackfillClass.aggregate,
      backfillCapDays: 365),
  TypeMappingEntry(
      platform: _ios,
      platformType: 'bodyMass',
      vitalKey: VitalKey.bodyWeight,
      unitPlatform: 'kg',
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _ios,
      platformType: 'height',
      vitalKey: VitalKey.bodyHeight,
      unitPlatform: 'cm',
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _ios,
      platformType: 'bodyTemperature',
      vitalKey: VitalKey.bodyTemperature,
      unitPlatform: 'degC',
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _ios,
      platformType: 'oxygenSaturation',
      vitalKey: VitalKey.oxygenSaturation,
      unitPlatform: '%',
      factor: 100, // HealthKit delivers 0...1
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _ios,
      platformType: 'respiratoryRate',
      vitalKey: VitalKey.respiratoryRate,
      unitPlatform: 'count/min',
      backfillClass: BackfillClass.discrete),
  TypeMappingEntry(
      platform: _ios,
      platformType: 'bloodGlucose',
      vitalKey: VitalKey.bloodGlucose,
      unitPlatform: 'mg/dL',
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _ios,
      platformType: 'bloodGlucose',
      vitalKey: VitalKey.glucoseSensor,
      unitPlatform: 'mg/dL',
      backfillClass: BackfillClass.series,
      backfillDefaultDays: 14,
      backfillCapDays: 90,
      seriesSources: iosGlucoseSeriesSources),
  // --- Health Connect (record names) ---
  TypeMappingEntry(
      platform: _hc,
      platformType: 'BloodPressureRecord',
      vitalKey: VitalKey.bloodPressure,
      unitPlatform: 'mmHg',
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _hc,
      platformType: 'HeartRateRecord',
      vitalKey: VitalKey.heartRate,
      unitPlatform: 'bpm',
      backfillClass: BackfillClass.series,
      backfillDefaultDays: 90,
      backfillCapDays: 90,
      exportSupported: true),
  TypeMappingEntry(
      platform: _hc,
      platformType: 'RestingHeartRateRecord',
      vitalKey: VitalKey.restingHeartRate,
      unitPlatform: 'bpm',
      backfillClass: BackfillClass.aggregate,
      backfillCapDays: 365),
  TypeMappingEntry(
      platform: _hc,
      platformType: 'WeightRecord',
      vitalKey: VitalKey.bodyWeight,
      unitPlatform: 'kg',
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _hc,
      platformType: 'HeightRecord',
      vitalKey: VitalKey.bodyHeight,
      unitPlatform: 'm',
      factor: 100,
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _hc,
      platformType: 'BodyTemperatureRecord',
      vitalKey: VitalKey.bodyTemperature,
      unitPlatform: 'degC',
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _hc,
      platformType: 'OxygenSaturationRecord',
      vitalKey: VitalKey.oxygenSaturation,
      unitPlatform: '%',
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _hc,
      platformType: 'RespiratoryRateRecord',
      vitalKey: VitalKey.respiratoryRate,
      unitPlatform: '/min',
      backfillClass: BackfillClass.discrete),
  TypeMappingEntry(
      platform: _hc,
      platformType: 'BloodGlucoseRecord',
      vitalKey: VitalKey.bloodGlucose,
      unitPlatform: 'mg/dL',
      backfillClass: BackfillClass.discrete,
      exportSupported: true),
  TypeMappingEntry(
      platform: _hc,
      platformType: 'BloodGlucoseRecord',
      vitalKey: VitalKey.glucoseSensor,
      unitPlatform: 'mg/dL',
      backfillClass: BackfillClass.series,
      backfillDefaultDays: 14,
      backfillCapDays: 90,
      seriesSources: androidGlucoseSeriesSources),
];
