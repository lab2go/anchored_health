## 0.2.0 (draft, no tag)

- Sleep analysis intervals and stage codes; 365-day initial window.
- Preserve SDNN and compound VO2 units from 0.1.3/0.1.2.
- Time zone metadata: IANA names pass unchanged; offset spellings (GMT+02:00, UTC-0530) are kept and written as GMT+-hh:mm (east positive) instead of being dropped; impossible offsets give null. Read-only category authorization.

## 0.1.3

- Read-only HRV (SDNN, milliseconds) and VO2 max (ml/kg/min) mappings. SDNN has no Health Connect counterpart in this catalog; RMSSD is not substituted.
- VO2 max keeps the precision and provenance supplied by the source. No assessment or extra write authorization.

## 0.1.2

- Include the source display name in transported records without changing the content hash or deduplication identity.

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
