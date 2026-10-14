## 0.1.2

- Construct VO2 max as milliliters / kilograms / minutes and use stable `ml/kg/min` transport spelling. Existing SDNN support remains in milliseconds; both types are read only.

## 0.1.1

- Fix: the blood pressure correlation type is never part of the read authorization set anymore. HealthKit rejects it with an uncatchable NSInvalidArgumentException ("Authorization to read the following types is disallowed"), which terminated the app. Only the systolic and diastolic quantity types are requested; `includeBloodPressureCorrelation` now defaults to false and is ignored natively.

## 0.1.0

- Initial release: Pigeon API `AnchoredHealthApi` with availability, types/units,
  request status, authorization (union of types, characteristics, optional blood
  pressure correlation), write status, anchored query with deletions and time
  window, save with sync metadata, delete (correlation including children),
  characteristics.
- Swift Package Manager and CocoaPods, iOS 15. Android: Dart stub only.
