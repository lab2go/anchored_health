import '../models.dart';
import '../types.dart';

/// Ledger of the app's own exports. The engine only queries in sets so that
/// a server or cache implementation stays cheap.
abstract class ExportLedger {
  /// Known platform record ids (HK UUID / HC id) among [ids].
  Future<Set<String>> knownPlatformRecordIds(Iterable<String> ids);

  /// Known sync identifiers among [ids] (Android blood pressure without UUID).
  Future<Set<String>> knownSyncIdentifiers(Iterable<String> ids);

  /// Known source row ids among [ids] (iOS `ExternalUUID`).
  Future<Set<String>> knownSourceRowIds(Iterable<String> ids);
}

/// Simple in-memory ledger (tests, debugging).
class InMemoryExportLedger implements ExportLedger {
  InMemoryExportLedger({
    Set<String>? platformRecordIds,
    Set<String>? syncIdentifiers,
    Set<String>? sourceRowIds,
  })  : platformRecordIds = platformRecordIds ?? {},
        syncIdentifiers = syncIdentifiers ?? {},
        sourceRowIds = sourceRowIds ?? {};

  final Set<String> platformRecordIds;
  final Set<String> syncIdentifiers;
  final Set<String> sourceRowIds;

  @override
  Future<Set<String>> knownPlatformRecordIds(Iterable<String> ids) async =>
      ids.where(platformRecordIds.contains).toSet();

  @override
  Future<Set<String>> knownSyncIdentifiers(Iterable<String> ids) async =>
      ids.where(syncIdentifiers.contains).toSet();

  @override
  Future<Set<String>> knownSourceRowIds(Iterable<String> ids) async =>
      ids.where(sourceRowIds.contains).toSet();
}

enum EchoStage {
  /// Stage 1: the source is the app itself.
  ownSource,

  /// Stage 2 (iOS only): own sync identifier prefix or ExternalUUID in the ledger.
  ownSyncIdentifier,

  /// Stage 3: platform id or sync identifier is in the ledger.
  ledger,
}

/// Ledger patch from stage 2: our export has the id [platformRecordId] in the health store.
class LedgerPatch {
  const LedgerPatch({required this.sourceRowId, required this.platformRecordId});
  final String sourceRowId;
  final String platformRecordId;

  @override
  bool operator ==(Object other) =>
      other is LedgerPatch &&
      other.sourceRowId == sourceRowId &&
      other.platformRecordId == platformRecordId;

  @override
  int get hashCode => Object.hash(sourceRowId, platformRecordId);
}

class EchoFilterResult {
  const EchoFilterResult({
    required this.kept,
    required this.dropped,
    required this.ledgerPatches,
  });
  final List<HealthSample> kept;
  final Map<EchoStage, int> dropped;
  final List<LedgerPatch> ledgerPatches;

  int get droppedTotal => dropped.values.fold(0, (a, b) => a + b);
}

/// Three-stage echo filter, order stage 1 -> 2 -> 3. A value exported by the
/// app must never come back as an import.
class EchoFilter {
  EchoFilter({
    required this.ownSourcePackages,
    required this.ledger,
    this.syncIdentifierPrefix = defaultSyncIdentifierPrefix,
  });

  /// The app's own bundle/package ids, e.g. `com.example.app`.
  final Set<String> ownSourcePackages;
  final ExportLedger ledger;
  final String syncIdentifierPrefix;

  Future<EchoFilterResult> apply(HealthPlatform platform, List<HealthSample> samples) async {
    final dropped = <EchoStage, int>{};
    final patches = <LedgerPatch>{};
    void drop(EchoStage s) => dropped[s] = (dropped[s] ?? 0) + 1;

    // Stage 1
    final afterA = <HealthSample>[];
    for (final s in samples) {
      if (ownSourcePackages.contains(s.sourcePackage)) {
        drop(EchoStage.ownSource);
      } else {
        afterA.add(s);
      }
    }

    // Stage 2 (iOS only; Android returns no clientRecordId when reading)
    final afterB = <HealthSample>[];
    if (platform == HealthPlatform.appleHealth) {
      final uuids = afterA.map((s) => s.externalUuid).whereType<String>().toSet();
      final knownRows = uuids.isEmpty ? <String>{} : await ledger.knownSourceRowIds(uuids);
      for (final s in afterA) {
        final sid = s.syncIdentifier;
        final ownSid = sid != null && sid.startsWith(syncIdentifierPrefix);
        final ownUuid = s.externalUuid != null && knownRows.contains(s.externalUuid);
        if (ownSid || ownUuid) {
          drop(EchoStage.ownSyncIdentifier);
          final row = ownUuid ? s.externalUuid! : sourceRowIdFromSyncIdentifier(sid!);
          if (row != null) {
            patches.add(LedgerPatch(sourceRowId: row, platformRecordId: s.externalId));
          }
        } else {
          afterB.add(s);
        }
      }
    } else {
      afterB.addAll(afterA);
    }

    // Stage 3
    final ids = afterB.map((s) => s.externalId).toSet();
    final sids = afterB.map((s) => s.syncIdentifier).whereType<String>().toSet();
    final knownIds = ids.isEmpty ? <String>{} : await ledger.knownPlatformRecordIds(ids);
    final knownSids = sids.isEmpty ? <String>{} : await ledger.knownSyncIdentifiers(sids);
    final kept = <HealthSample>[];
    for (final s in afterB) {
      if (knownIds.contains(s.externalId) ||
          (s.syncIdentifier != null && knownSids.contains(s.syncIdentifier))) {
        drop(EchoStage.ledger);
      } else {
        kept.add(s);
      }
    }
    return EchoFilterResult(kept: kept, dropped: dropped, ledgerPatches: patches.toList());
  }

  /// `<prefix><id>`, `<prefix>lab:<id>` (laboratory values), children
  /// `...:sys`/`...:dia` -> `<id>`.
  String? sourceRowIdFromSyncIdentifier(String sid) {
    if (!sid.startsWith(syncIdentifierPrefix)) return null;
    var rest = sid.substring(syncIdentifierPrefix.length);
    if (rest.startsWith('lab:')) rest = rest.substring(4);
    for (final suffix in const [':sys', ':dia']) {
      if (rest.endsWith(suffix)) rest = rest.substring(0, rest.length - suffix.length);
    }
    return rest.isEmpty ? null : rest;
  }
}
