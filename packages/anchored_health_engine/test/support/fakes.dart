// Test doubles: all values are synthetic, no real health or personal data.
import 'package:anchored_health_engine/anchored_health_engine.dart';

final t0 = DateTime.utc(2026, 9, 1, 8);

HealthSample sample({
  required String id,
  String type = 'bodyMass',
  DateTime? at,
  double? value = 70,
  double? sys,
  double? dia,
  String source = 'com.example.scale',
  String? unit,
  String? device,
  String? syncIdentifier,
  int? syncVersion,
  String? externalUuid,
}) {
  final t = at ?? t0;
  return HealthSample(
    externalId: id,
    platformType: type,
    start: t,
    end: t,
    value: sys != null ? null : value,
    systolic: sys,
    diastolic: dia,
    unit: unit,
    sourcePackage: source,
    deviceName: device,
    syncIdentifier: syncIdentifier,
    syncVersion: syncVersion,
    externalUuid: externalUuid,
  );
}

/// Simulates HealthKit anchors (iOS) or changes tokens (Android) via a
/// running insertion number per type.
class FakeHealthBridge implements HealthBridge {
  FakeHealthBridge({this.platform = HealthPlatform.appleHealth, bool? firstRunIncludesHistory})
      : firstRunIncludesHistory = firstRunIncludesHistory ?? platform == HealthPlatform.appleHealth;

  @override
  final HealthPlatform platform;
  @override
  final bool firstRunIncludesHistory;

  final Map<String, List<(int, Object)>> _log = {};
  int _seq = 0;
  final List<String> calls = [];
  final Set<String> expireTokenFor = {};
  final List<HealthWriteRequest> written = [];

  void add(HealthSample s) => _log.putIfAbsent(s.platformType, () => []).add((++_seq, s));

  void addAll(Iterable<HealthSample> ss) => ss.forEach(add);

  /// Store under a different type key (Android blood pressure halves).
  void addAs(String type, HealthSample s) => _log.putIfAbsent(type, () => []).add((++_seq, s));

  void deleteId(String type, String id) =>
      _log.putIfAbsent(type, () => []).add((++_seq, HealthDeletion(externalId: id)));

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> requestAuthorization({required Set<String> read, required Set<String> write, bool characteristics = false}) async =>
      true;

  @override
  Future<AuthorizationRequestStatus> authorizationRequestStatus(
          {required Set<String> read, required Set<String> write, bool characteristics = false}) async =>
      AuthorizationRequestStatus.unnecessary;

  @override
  Future<WritePermission> writePermission(String platformType) async => WritePermission.authorized;

  bool _inWindow(HealthSample s, DateTime? from, DateTime? to) =>
      (from == null || !s.start.isBefore(from)) && (to == null || s.start.isBefore(to));

  @override
  Future<ChangesPage> changes(String platformType,
      {String? token, DateTime? from, DateTime? to, int limit = 1000}) async {
    calls.add('changes:$platformType:${token ?? '-'}:${from?.toIso8601String() ?? '-'}');
    if (expireTokenFor.remove(platformType)) {
      return ChangesPage(samples: const [], deletions: const [], nextToken: null, hasMore: false, tokenExpired: true);
    }
    final anchor = int.tryParse(token ?? '') ?? 0;
    final items = (_log[platformType] ?? []).where((e) => e.$1 > anchor).toList();
    final samples = <HealthSample>[];
    final deletions = <HealthDeletion>[];
    var last = anchor;
    for (final (seq, obj) in items) {
      if (limit > 0 && samples.length + deletions.length >= limit) break;
      last = seq;
      if (obj is HealthSample) {
        if (_inWindow(obj, from, to)) samples.add(obj);
      } else if (obj is HealthDeletion) {
        deletions.add(obj);
      }
    }
    final hasMore = items.isNotEmpty && last < items.last.$1;
    return ChangesPage(samples: samples, deletions: deletions, nextToken: '$last', hasMore: hasMore);
  }

  @override
  Future<String?> baselineToken(String platformType) async {
    calls.add('baseline:$platformType');
    final items = _log[platformType] ?? [];
    return '${items.isEmpty ? 0 : items.last.$1}';
  }

  @override
  Future<List<HealthSample>> read(String platformType, {required DateTime from, required DateTime to}) async {
    calls.add('read:$platformType:${from.toIso8601String()}');
    return [
      for (final (_, o) in _log[platformType] ?? <(int, Object)>[])
        if (o is HealthSample && _inWindow(o, from, to)) o
    ];
  }

  @override
  Future<List<String?>> write(List<HealthWriteRequest> requests) async {
    written.addAll(requests);
    return [for (final r in requests) 'hk-${r.sourceRowId}'];
  }

  @override
  Future<int> delete(String platformType, List<String> ids) async => ids.length;

  @override
  Future<HealthCharacteristics?> characteristics() async =>
      const HealthCharacteristics(birthYear: 1980, biologicalSex: 'female');
}

/// Server fake: dedupes via external_id (upsert, version) and content_hash.
class FakeUploader implements HealthUploader {
  final Map<String, VitalRecord> rows = {};
  final Set<String> hashes = {};
  final List<List<VitalRecord>> batches = [];
  final List<SeriesBatch> seriesBatches = [];
  final List<String> deleted = [];
  final List<SyncRunLog> logs = [];
  int failImports = 0;

  @override
  Future<ImportBatchResult> importBatch(String linkId, List<VitalRecord> records) async {
    if (failImports > 0) {
      failImports--;
      throw StateError('backend unreachable');
    }
    batches.add(records);
    var ins = 0, upd = 0, dup = 0;
    for (final r in records) {
      final old = rows[r.externalId];
      if (old != null) {
        final newer = r.externalVersion == null || old.externalVersion == null || r.externalVersion! > old.externalVersion!;
        if (newer && old.contentHash != r.contentHash) {
          rows[r.externalId] = r;
          hashes.add(r.contentHash);
          upd++;
        } else {
          dup++;
        }
      } else if (hashes.contains(r.contentHash)) {
        dup++;
      } else {
        rows[r.externalId] = r;
        hashes.add(r.contentHash);
        ins++;
      }
    }
    return ImportBatchResult(inserted: ins, updated: upd, duplicates: dup);
  }

  @override
  Future<SeriesBatchResult> importSeriesBatch(String linkId, SeriesBatch batch) async {
    if (failImports > 0) {
      failImports--;
      throw StateError('backend unreachable');
    }
    seriesBatches.add(batch);
    var ins = 0, dup = 0;
    for (final r in batch.records) {
      if (rows.containsKey(r.externalId) || hashes.contains(r.contentHash)) {
        dup++;
      } else {
        rows[r.externalId] = r;
        hashes.add(r.contentHash);
        ins++;
      }
    }
    return SeriesBatchResult(inserted: ins, duplicates: dup);
  }

  @override
  Future<int> applyDeletions(String linkId, List<String> externalIds) async {
    deleted.addAll(externalIds);
    return externalIds.where(rows.containsKey).length;
  }

  @override
  Future<void> logRun(String linkId, SyncRunLog log) async => logs.add(log);
}

const vitalIds = <VitalKey, String>{
  VitalKey.bloodPressure: 'vt-bp',
  VitalKey.heartRate: 'vt-hr',
  VitalKey.restingHeartRate: 'vt-rhr',
  VitalKey.bodyWeight: 'vt-weight',
  VitalKey.bodyHeight: 'vt-height',
  VitalKey.bodyTemperature: 'vt-temp',
  VitalKey.oxygenSaturation: 'vt-spo2',
  VitalKey.respiratoryRate: 'vt-rr',
  VitalKey.bloodGlucose: 'vt-glucose',
  VitalKey.glucoseSensor: 'vt-cgm',
};

TypeCatalog testCatalog() => TypeCatalog.v1Default().withVitalTypeIds(vitalIds);

const ownBundle = 'com.example.myapp';
const ownPrefix = 'myapp:';

class EngineHarness {
  EngineHarness({
    HealthPlatform platform = HealthPlatform.appleHealth,
    DateTime? now,
    SessionProvider? session,
    InMemoryExportLedger? ledger,
    int pageLimit = 1000,
  })  : bridge = FakeHealthBridge(platform: platform),
        uploader = FakeUploader(),
        kv = InMemoryKeyValueStore(),
        ledger = ledger ?? InMemoryExportLedger(),
        link = HealthLink(linkId: 'link-1', userId: 'user-a', profileId: 'profile-a', platform: platform) {
    clockNow = now ?? DateTime.utc(2026, 10, 8, 12);
    state = SyncStateStore(kv);
    engine = HealthSyncEngine(
      bridge: bridge,
      catalog: testCatalog(),
      state: state,
      uploader: uploader,
      ledger: this.ledger,
      session: session ?? const FixedSession('user-a', 'profile-a'),
      config: EngineConfig(ownSourcePackages: {ownBundle}, syncIdentifierPrefix: ownPrefix, pageLimit: pageLimit),
      preferences: prefs,
      clock: () => clockNow,
    );
  }

  final FakeHealthBridge bridge;
  final FakeUploader uploader;
  final InMemoryKeyValueStore kv;
  final InMemoryExportLedger ledger;
  final HealthLink link;
  final prefs = InMemorySeriesPreferenceStore();
  late DateTime clockNow;
  late SyncStateStore state;
  late HealthSyncEngine engine;

  Future<SyncRunResult> sync(Set<String> types, {SyncTrigger trigger = SyncTrigger.manual}) =>
      engine.syncNow(link, types: types, trigger: trigger);
}
