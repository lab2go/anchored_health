# anchored_health_native

HealthKit bridge (Pigeon API `AnchoredHealthApi`, Swift). iOS only. On other
platforms the Dart facade throws `HealthPlatformUnsupported`.

Platform types: `bloodPressure` (HKCorrelation), `heartRate`, `restingHeartRate`,
`bodyMass`, `height`, `bodyTemperature`, `oxygenSaturation`, `respiratoryRate`,
`bloodGlucose`, plus read-only `heartRateVariabilitySDNN`, `bodyFatPercentage`,
`waistCircumference`, `vo2Max`. Every type has a fixed unit (`unitFor`).
Percentages follow the HealthKit convention (0...1).

Writing is allowed for blood pressure, heart rate, body mass, height, body
temperature, oxygen saturation and blood glucose. Blood pressure is saved as
exactly **one** `HKCorrelation`. The metadata is set on the correlation and on
both children; the children carry the sync identifier with the suffixes
`:sys`/`:dia`. An optional `deviceName` on the save request becomes the
`HKDevice` name of the written objects.

Regenerate Pigeon: `dart run pigeon --input pigeons/messages.dart`.
