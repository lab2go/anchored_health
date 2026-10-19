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
  sleepStage('Sleep stage', 'stage', null),

  // --- Daily totals (0.3.0, read only, one sum per local calendar day) ---

  /// Steps per day (HealthKit `stepCount`, cumulative sum over all sources).
  steps('Steps', 'count', '55423-8'),

  /// Walking and running distance per day, in meters.
  walkingRunningDistance('Distance (walking/running)', 'm', null),

  /// Active energy per day (HealthKit `activeEnergyBurned`), in kcal. The
  /// server type is "burned calories" (shown as "Active energy").
  activeEnergy('Active energy', 'kcal', null),

  /// Flights of stairs climbed per day.
  flightsClimbed('Flights climbed', 'count', null),

  /// Apple exercise time per day, in minutes.
  exerciseMinutes('Exercise time', 'min', null);

  const VitalKey(this.label, this.canonicalUnit, this.loinc);

  /// English display label (informational only; apps use their own names).
  final String label;

  /// Canonical storage unit.
  final String canonicalUnit;

  /// LOINC code, `null` = none.
  final String? loinc;
}

/// How a type is backfilled.
///
/// [dailySum]: one cumulative sum per local calendar day (steps, distance,
/// active energy, flights, exercise minutes). Read with `ActivityDailySync` /
/// `ActivityDailyReader`, never through `HealthSyncEngine.syncNow` (that would
/// upload single samples).
enum BackfillClass { discrete, series, aggregate, dailySum }

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
