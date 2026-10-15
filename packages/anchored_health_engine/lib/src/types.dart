/// Basic engine types (pure Dart, no platform dependency).
library;

/// Platform of a connection.
enum HealthPlatform {
  appleHealth('apple_health'),
  healthConnect('health_connect');

  const HealthPlatform(this.id);

  /// Stable string id (for storage keys and server payloads).
  final String id;
}

/// Vital type known to the engine. The server-side id (`vitalTypeId`) is
/// supplied through the catalog; the engine identifies types by this key.
enum VitalKey {
  bloodPressure('Blood pressure', 'mmHg', '85354-9'),
  heartRate('Heart rate', 'bpm', '8867-4'),
  restingHeartRate('Resting heart rate', 'bpm', '40443-4'),
  bodyWeight('Body weight', 'kg', '29463-7'),
  bodyHeight('Body height', 'cm', '8302-2'),
  bodyTemperature('Body temperature', '°C', '8310-5'),
  oxygenSaturation('Oxygen saturation', '%', '59408-5'),
  respiratoryRate('Respiratory rate', '/min', '9279-1'),
  bloodGlucose('Blood glucose (meter/manual)', 'mg/dL', '41653-7'),

  /// CGM series (interstitial glucose), kept apart from blood glucose readings.
  glucoseSensor('Glucose (sensor)', 'mg/dL', null),

  // --- Read only (0.2.0) ---

  /// Heart rate variability, SDNN (HealthKit only; Health Connect knows RMSSD).
  hrvSdnn('Heart rate variability (SDNN)', 'ms', null),

  /// VO2 max (cardio fitness estimate as recorded by the source).
  vo2Max('VO2 max', 'ml/kg/min', null),

  /// Body fat percentage.
  bodyFatPercentage('Body fat percentage', '%', null),

  /// Waist circumference (HealthKit only).
  waistCircumference('Waist circumference', 'cm', '8280-0'),

  /// One sleep analysis interval. Value = stage code (HealthKit numbering of
  /// HKCategoryValueSleepAnalysis): 0 in bed, 1 asleep (unspecified),
  /// 2 awake, 3 core, 4 deep, 5 REM. Start/end carry the interval.
  sleepStage('Sleep stage', 'stage', null);

  const VitalKey(this.label, this.canonicalUnit, this.loinc);

  /// English display label (informational only; apps use their own names).
  final String label;

  /// Canonical storage unit.
  final String canonicalUnit;

  /// LOINC code, `null` = none.
  final String? loinc;
}

/// How a type is backfilled.
enum BackfillClass { discrete, series, aggregate }

/// Recording method of a value.
enum RecordingMethod { automatic, manual, active, unknown }

/// Trigger of a sync run.
enum SyncTrigger { manual, resume, background, backfill, reread }

/// Outcome of a sync run.
enum SyncOutcome {
  success,
  partial,
  error,

  /// Session does not match the connection: nothing read, nothing uploaded.
  sessionMismatch,

  /// Another run holds the lock.
  locked,

  /// Health Connect: interval between runs too short.
  throttled,
}
