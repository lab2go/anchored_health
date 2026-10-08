## 0.1.0

- Initial release: `HealthBridge` interface, `NativeHealthBridge` (iOS), default
  type catalog (including a series-source allowlist for CGM apps), record mapping
  with a fixed content-hash contract, three-stage echo filter, dedupe, blood
  pressure pairing, series classification (allowlist/density, sticky) and
  one-series-source-per-profile filter, sync state (anchors/tokens, backfill
  cursor, run lock, installation id), import engine with page continuation,
  re-read window, throttling and backfill of older windows.
