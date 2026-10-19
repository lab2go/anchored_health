# anchored_health_native

HealthKit bridge (Pigeon API `AnchoredHealthApi`, Swift). iOS only. On other
platforms the Dart facade throws `HealthPlatformUnsupported`.

Platform types: `bloodPressure` (HKCorrelation), `heartRate`, `restingHeartRate`,
`bodyMass`, `height`, `bodyTemperature`, `oxygenSaturation`, `respiratoryRate`,
`bloodGlucose`, plus read-only `heartRateVariabilitySDNN`, `bodyFatPercentage`,
`waistCircumference`, `vo2Max`, `sleepAnalysis` (category type, value = stage code),
and the cumulative activity types `stepCount` (count), `distanceWalkingRunning` (m),
`activeEnergyBurned` (kcal), `flightsClimbed` (count), `appleExerciseTime` (min). Every type has a fixed unit (`unitFor`).
Percentages follow the HealthKit convention (0...1).

Writing is allowed for blood pressure, heart rate, body mass, height, body
temperature, oxygen saturation and blood glucose. Blood pressure is saved as
exactly **one** `HKCorrelation`. The metadata is set on the correlation and on
both children; the children carry the sync identifier with the suffixes
`:sys`/`:dia`. An optional `deviceName` on the save request becomes the
`HKDevice` name of the written objects.

## Daily totals (activity types)

`dailyTotals(type, fromDay, toDay)` returns one sum per **local calendar day**
of the device (`YYYY-MM-DD`, inclusive range) from
`HKStatisticsCollectionQuery` with `cumulativeSum`. Overlapping sources (iPhone
and Apple Watch) are merged by HealthKit itself because the statistics are never
split by source. Days with 23 or 25 hours are real calendar days. A day without
any sample is **not** in the result (no data is not 0). `sampleRefs(...)` is an
anchored query that only returns UUID, start and end (and deleted UUIDs), so
that a caller can find the days a change or deletion touches. Both calls reject
every type except the five cumulative activity types (`invalid_argument`).

Regenerate Pigeon: `dart run pigeon --input pigeons/messages.dart`.
