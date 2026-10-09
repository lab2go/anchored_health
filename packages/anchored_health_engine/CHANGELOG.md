## 0.1.1

- Fix: the blood pressure correlation type is never part of the read authorization set anymore. HealthKit rejects it with an uncatchable NSInvalidArgumentException ("Authorization to read the following types is disallowed"), which terminated the app. Only the systolic and diastolic quantity types are requested; `includeBloodPressureCorrelation` now defaults to false and is ignored natively.

## 0.1.0

- Initial release: `HealthBridge` interface, `NativeHealthBridge` (iOS), default
  type catalog (including a series-source allowlist for CGM apps), record mapping
  with a fixed content-hash contract, three-stage echo filter, dedupe, blood
  pressure pairing, series classification (allowlist/density, sticky) and
  one-series-source-per-profile filter, sync state (anchors/tokens, backfill
  cursor, run lock, installation id), import engine with page continuation,
  re-read window, throttling and backfill of older windows.
