# anchored_health

Building blocks for syncing health data between a Flutter app and Apple Health
(HealthKit): anchored incremental reads **including deletions**, blood pressure
as one correlated value, and sync identifiers for the values an app writes back.
On Android the engine is prepared for Health Connect via the package
[`health`](https://pub.dev/packages/health).

The repository contains two Dart/Flutter packages. Apps consume them as a Git
dependency pinned to a commit SHA. All test values are synthetic.

## Packages

| Package | Path | Content |
|---|---|---|
| `anchored_health_native` | `packages/anchored_health_native` | Flutter plugin with the Pigeon API `AnchoredHealthApi`. **iOS (Swift):** authorization over the union of all types (optionally date of birth/biological sex and the blood pressure correlation in the read set), `anchoredQuery` per type with `deletedObjects` and anchor round-trip (Base64, `NSKeyedArchiver`), sample model with `HKDevice`, `sourceRevision`, metadata and blood pressure correlation, `save` with `SyncIdentifier`/`SyncVersion`/`ExternalUUID`/`WasUserEntered`/`WasTakenInLab`/`TimeZone`/`BloodGlucoseMealTime` and an optional device name, `delete`. **Android:** no native code; the Dart facade throws `HealthPlatformUnsupported`. |
| `anchored_health_engine` | `packages/anchored_health_engine` | Sync engine. The core (`package:anchored_health_engine/anchored_health_engine.dart`) has no platform code: `HealthBridge` interface, type mapping (vital types <-> HealthKit/Health Connect), anchor/token state per (user, profile, platform, type), echo protection, dedupe, blood pressure as one type, series classification for sensor glucose and the import flow. `package:anchored_health_engine/native_bridge.dart` contains `NativeHealthBridge`, the iOS implementation on top of `anchored_health_native`. |

**No assessment:** records have no field for status, reference range, zone or
target range. A test checks the complete field list.

Engine 0.1.3 also imports HRV **SDNN** in milliseconds and VO2 max in
`ml/kg/min`, without writing either type back. Source precision, timestamps and
provenance are preserved. SDNN is not substituted with Health Connect RMSSD.
Apps must explicitly select the new read types; an upgrade grants no permissions.

## Interface (summary)

```dart
abstract class HealthBridge {
  HealthPlatform get platform;            // apple_health | health_connect
  bool get firstRunIncludesHistory;       // iOS true (nil anchor returns history + anchor)
  Future<bool> isAvailable();
  Future<bool> requestAuthorization({required Set<String> read, required Set<String> write, bool characteristics});
  Future<AuthorizationRequestStatus> authorizationRequestStatus({...});
  Future<WritePermission> writePermission(String platformType);
  Future<ChangesPage> changes(String platformType, {String? token, DateTime? from, DateTime? to, int limit});
  Future<String?> baselineToken(String platformType);        // Android: token before the backfill
  Future<List<HealthSample>> read(String platformType, {required DateTime from, required DateTime to});
  Future<List<String?>> write(List<HealthWriteRequest> requests);
  Future<int> delete(String platformType, List<String> ids);
  Future<HealthCharacteristics?> characteristics();
}
```

Everything that holds state or talks to a network is injected into the engine:

| Interface | Purpose |
|---|---|
| `KeyValueStore` | anchors/tokens, backfill cursor, series sources, run lock |
| `HealthUploader` | upload single records, series batches, deletions and run logs to the app's backend |
| `ExportLedger` | recognize the app's own exports (echo stage 3) |
| `SeriesPreferenceStore` | one series source per profile × vital type |
| `DedupeIndex` (optional) | skip uploads of known records |
| `SessionProvider` | run only if the signed-in user and active profile match the connection |

Local keys: `<uid>/<pid>/<platform>/sync_token/<platform_type>`,
`.../backfill/<platform_type>`, `.../series_sources`, `.../run_lock`,
`.../last_run`. The installation id lives outside of them
(`SyncStateStore.deviceIdKey`, default `anchored_health/device_id`) and survives
`resetUser(uid)`.

**Hash contract `content_hash`:** sha256 (hex) over
`vital_type_id|measured_at|end_at|value_numeric|value_secondary|source_package|source_device_name`.
Times in UTC to the second (`2026-09-01T08:00:05Z`), numbers with at most 6
decimals without trailing zeros, `null` as empty text. A server that recomputes
the hash must use exactly this format.

## Daily activity totals (0.3.0, read only)

Steps, walking/running distance, active energy, flights climbed and exercise
minutes are not single readings but **one sum per local calendar day**. They
use their own path next to `HealthSyncEngine` (`syncNow` skips these types, it
would otherwise upload single samples):

| Platform type (HealthKit) | `VitalKey` | Canonical unit |
|---|---|---|
| `stepCount` | `steps` | `count` |
| `distanceWalkingRunning` | `walkingRunningDistance` | `m` |
| `activeEnergyBurned` | `activeEnergy` | `kcal` |
| `flightsClimbed` | `flightsClimbed` | `count` |
| `appleExerciseTime` | `exerciseMinutes` | `min` |

* **Native (iOS):** `HKStatisticsCollectionQuery` with `cumulativeSum` over all
  sources and local midnight of the device as day boundary (23 and 25 hour days
  are single days). HealthKit itself merges overlapping sources (iPhone and
  Apple Watch); the plugin never splits by source and never adds per-device
  values up. A day without data is missing, never 0.
* **Read:** `ActivityDailyReader.readDailyTotals(type, lookbackDays: 365)`
  (default 365, at most 1825 days, today included; `complete` is `false` for
  today).
* **Sync:** `ActivityDailySync.syncNow(link, types: {...})` finds the touched
  days with an anchored reference query (only UUID/start/end), reads exactly
  those days, compares with the last accepted value and uploads changes through
  `ActivityDailyUploader.ingestDaily` (app: RPC `health_ingest_daily`). The anchor
  is stored only after all batches of a type succeeded.
* **What counts as accepted:** only a batch the server really took. `rejected`
  > 0 (inactive mapping, type off for the connection, consent missing, wrong
  unit), `echo` > 0, or counters that do not add up to the batch fail the type
  (`ActivitySyncResult.failedTypes`, reason in `failureReasons`, constants in
  `ActivityFailure`) and are **not** stored as sent; the anchor stays. The next run
  sends the days again, so the run that happens before the mappings are active
  loses nothing. The uploader must return the server's counters as they are
  (`ActivityIngestResult.fromJson`).
* **Progress and abort:** every accepted batch is stored as sent at once (a
  failure in batch n of 41 only repeats the rest) and renews the run lock.
  `syncNow(..., onProgress: ..., shouldStop: ...)` reports `ActivityProgress`
  (type, batches, days; no values) and asks `shouldStop` before every type and
  batch (watchdog or "Cancel"); `true` ends the run cleanly
  (`ActivitySyncResult.stopped`, `incompleteTypes`, outcome `partial`), the
  next run continues with what is left.
* **Local state outside the backup:** the per-day values and the UUID index are
  health data. Give `SyncStateStore` a second store for them:
  `SyncStateStore(prefsStore, activityKv: await openBackupExcludedStateStore())`
  (`package:anchored_health_engine/native_bridge.dart`). It is a directory in
  Application Support marked `NSURLIsExcludedFromBackupKey` by the plugin
  (`prepareStateDirectory`), one file per key, written atomically
  (`FileKeyValueStore`); SharedPreferences cannot be excluded from backups.
  Keys an earlier version wrote to the main store are moved over on the first
  `syncNow` of a connection and removed from there (`migrated_keys`);
  `forget` and `resetUser` clear both stores. Without `activityKv` everything
  stays in the one store as before (then that store must not be backed up).
* **Changes and deletions:** a local index (UUID -> days of the last 7 days,
  `ActivityDailyConfig.indexDays`, monthly shards under
  `<uid>/<pid>/<platform>/activity/idx/...`) tells which
  days a deletion touches; an unknown or older UUID recomputes the whole
  look-back and compares it with the sent values (one statistics query, an
  upload only for days that really changed). A
  late sample (old start, new insertion) recomputes its old day. An empty read
  **never** deletes anything and is never sent as 0: days that lost all data
  are only reported (`ActivitySyncResult.emptiedDays`).
* **Contract of the server** (`health_ingest_daily`): one merged sum per type
  and day under one fixed `source_package`
  (`ActivityDailyConfig.sourcePackage`, never change it for an existing
  profile), no `external_version`, no `deleted` (tombstones only on an explicit
  user request, never created by the engine), batches of one type and a limited
  period (<= 2000 elements, <= 45 days per batch, newest first). The answer's
  `timezone_id` is stored; when it changes the whole look-back is sent again.
  The new zone is only kept after that resend went through (an abort or error in
  between leaves the resend open for the next run).
* **Revocation:** `ActivityDailySync.forget(scope)` removes anchors, sent values
  and the index of a connection (`SyncStateStore.resetUser` does it too). The
  server is not touched.
* **Android:** placeholder only (`UnsupportedActivityDailyBridge`, catalog
  entries with `importSupported: false`); Health Connect follows in a later
  package.

```dart
final sync = ActivityDailySync(
  bridge: nativeBridge,                       // NativeHealthBridge implements ActivityDailyBridge
  catalog: catalog,                           // withVitalTypeIds(...) for the five daily types
  state: SyncStateStore(myKeyValueStore, activityKv: await openBackupExcludedStateStore()),
  uploader: myDailyUploader,                  // rpc('health_ingest_daily', {p_link_id, p_days, p_run_id})
  session: mySession,
);
final r = await sync.syncNow(link, types: activityPlatformTypes.toSet());
```

Read permission: the app requests the five platform types in `read` of
`requestAuthorization` (read only, nothing is written). Info.plist needs no extra
key per type: the existing `NSHealthShareUsageDescription` must name the
activity values.

## App-specific configuration

Nothing app-specific is hard-coded. The defaults are neutral placeholders; an
app sets its own values:

| Setting | Type | Default | Purpose |
|---|---|---|---|
| `EngineConfig.ownSourcePackages` | `Set<String>` | `{'com.example.app'}` | The app's own bundle id(s)/package name(s). Samples from these sources are dropped (echo stage 1). |
| `EngineConfig.syncIdentifierPrefix` | `String` | `'app:'` | Prefix of the sync identifiers the app writes. Samples carrying it are dropped (echo stage 2). |
| `HealthWriteRequest.syncIdentifierPrefix` | `String` | `'app:'` (`defaultSyncIdentifierPrefix`) | Prefix used when writing; must equal `EngineConfig.syncIdentifierPrefix`. |
| `NativeHealthBridge.deviceName` | `String?` | `null` | Name of the `HKDevice` attached to written values (e.g. the app name); `null` writes no device. |
| `SyncStateStore(deviceIdKey:)` | `String` | `'anchored_health/device_id'` | Storage key of the installation id. |
| `TypeCatalog` | entries | `TypeCatalog.v1Default()` | Type mapping; apps insert their server ids via `withVitalTypeIds` or load the whole catalog from their backend. Series-source allowlists (third-party CGM apps) can be extended per entry. |

## Integration (Git dependency with SHA pin)

```yaml
dependencies:
  anchored_health_engine:
    git:
      url: https://github.com/<owner>/anchored_health.git
      ref: <commit-sha>          # always a full commit SHA, never a branch
      path: packages/anchored_health_engine
  anchored_health_native:
    git:
      url: https://github.com/<owner>/anchored_health.git
      ref: <commit-sha>          # the same SHA as above
      path: packages/anchored_health_native
```

`anchored_health_engine` depends on `anchored_health_native` through a relative
path. pub resolves it within the same Git commit, so the second entry must use
the same SHA. It is not strictly needed but makes the plugin explicit in the
app's dependency list.

Requirements in the app: iOS 15 or later, the HealthKit capability and the
entitlement `com.apple.developer.healthkit`, `NSHealthShareUsageDescription` and
`NSHealthUpdateUsageDescription`. The plugin supports Swift Package Manager
(`ios/anchored_health_native/Package.swift`) and CocoaPods
(`ios/anchored_health_native.podspec`). Plugin registration only sets up the
Pigeon channel. It never touches windows or the root view controller, and the
`HKHealthStore` is created on the first call (UIScene-safe).

Usage (sketch):

```dart
import 'package:anchored_health_engine/anchored_health_engine.dart';
import 'package:anchored_health_engine/native_bridge.dart';

final engine = HealthSyncEngine(
  bridge: NativeHealthBridge(deviceName: 'My App'),
  catalog: TypeCatalog.v1Default().withVitalTypeIds(idsFromServer),
  state: SyncStateStore(myKeyValueStore),
  uploader: myUploader,
  ledger: myLedger,
  session: mySession,
  config: const EngineConfig(
    ownSourcePackages: {'com.mycompany.myapp'},
    syncIdentifierPrefix: 'myapp:',
  ),
);
final result = await engine.syncNow(link, types: {'bloodPressure', 'bodyMass', 'bloodGlucose'});
```

## Development

```bash
# Run with both supported Flutter versions (e.g. 3.41.x and 3.47.x)
cd packages/anchored_health_native && flutter analyze && flutter test
cd packages/anchored_health_engine && flutter analyze && flutter test
cd packages/anchored_health_native/example && flutter analyze && flutter test
# Regenerate Pigeon
cd packages/anchored_health_native && dart run pigeon --input pigeons/messages.dart
# iOS build (SPM) and Swift tests
cd packages/anchored_health_native/example && flutter build ios --simulator --debug --no-codesign
cd ios && xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,id=<simulator-udid>' -only-testing:RunnerTests
```

With Xcode 27, `flutter build ios --simulator` under Flutter 3.41 can fail at
`lipo -verify_arch` ("does not contain architectures arm64 x86_64"). This is a
toolchain issue, not a plugin issue. The CocoaPods path can still be checked:
first `flutter build ios --simulator --config-only`, then
`xcodebuild ... ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build`.

## Limits (v0.1.0)

- Only a real iPhone can verify: the permission dialog, reading and writing with
  permission, the blood pressure correlation in the dialog and in
  `deletedObjects`, background delivery. Simulator tests cover logic, mapping
  and the build.
- Android: Dart stub only. A `HealthBridge` implementation on top of the package
  `health` is not included yet. The engine already handles Android semantics
  (baseline token, re-read window, pairing blood pressure halves) and is tested
  with a fake bridge.
- No export direction (outbox/ledger maintenance) and no background sync
  (observer queries). The write paths in plugin and bridge exist.
- The built-in type catalog is a default; apps usually load the authoritative
  mapping from their backend.

## License

MIT, see [LICENSE](LICENSE).
