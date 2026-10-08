/// Health sync engine.
///
/// Core without platform code: [HealthBridge] interface, type mapping,
/// anchor/token state, echo protection, dedupe, blood pressure as one type,
/// series classification. Storage, ledger and uploader are injected.
/// No assessment of values (no status, zones or reference ranges).
library;

export 'src/bridge/health_bridge.dart';
export 'src/engine/health_sync_engine.dart';
export 'src/mapping/type_catalog.dart';
export 'src/mapping/vital_record.dart';
export 'src/models.dart';
export 'src/state/sync_state_store.dart';
export 'src/sync/blood_pressure.dart';
export 'src/sync/dedupe.dart';
export 'src/sync/echo_filter.dart';
export 'src/sync/plausibility.dart';
export 'src/sync/series.dart';
export 'src/types.dart';
export 'src/upload/health_uploader.dart';
