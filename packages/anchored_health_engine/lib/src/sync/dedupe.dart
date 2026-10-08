import '../mapping/vital_record.dart';

/// Known keys checked before the upload. The final dedupe is done by the
/// server; this index only saves uploads (e.g. a cache from the last run).
abstract class DedupeIndex {
  Future<Set<String>> knownExternalIds(Iterable<String> ids);
  Future<Set<String>> knownContentHashes(Iterable<String> hashes);

  /// Keys of records deleted on the server (tombstones).
  Future<Set<String>> deletedExternalIds(Iterable<String> ids);
}

class EmptyDedupeIndex implements DedupeIndex {
  const EmptyDedupeIndex();
  @override
  Future<Set<String>> knownExternalIds(Iterable<String> ids) async => {};
  @override
  Future<Set<String>> knownContentHashes(Iterable<String> hashes) async => {};
  @override
  Future<Set<String>> deletedExternalIds(Iterable<String> ids) async => {};
}

class InMemoryDedupeIndex implements DedupeIndex {
  InMemoryDedupeIndex({Set<String>? externalIds, Set<String>? hashes, Set<String>? deleted})
      : externalIds = externalIds ?? {},
        hashes = hashes ?? {},
        deleted = deleted ?? {};
  final Set<String> externalIds;
  final Set<String> hashes;
  final Set<String> deleted;
  @override
  Future<Set<String>> knownExternalIds(Iterable<String> ids) async => ids.where(externalIds.contains).toSet();
  @override
  Future<Set<String>> knownContentHashes(Iterable<String> h) async => h.where(hashes.contains).toSet();
  @override
  Future<Set<String>> deletedExternalIds(Iterable<String> ids) async => ids.where(deleted.contains).toSet();
}

class DedupeResult {
  const DedupeResult({
    required this.kept,
    required this.duplicates,
    required this.skippedDeleted,
  });
  final List<VitalRecord> kept;
  final int duplicates;
  final int skippedDeleted;
}

/// Duplicate = same `external_id` **or** same `content_hash` **or** key in the
/// deleted set. Conflict tolerances play no role here (display only).
class Deduper {
  const Deduper({this.index = const EmptyDedupeIndex()});
  final DedupeIndex index;

  /// Within a batch, the **later** entry wins for the same `external_id`
  /// (change log order; Android has no version). Same hash with a different
  /// id => the first stays, the second counts as a duplicate.
  Future<DedupeResult> dedupe(List<VitalRecord> records, {bool skipKnownExternalIds = false}) async {
    var duplicates = 0;
    final byId = <String, VitalRecord>{};
    for (final r in records) {
      if (byId.containsKey(r.externalId)) duplicates++;
      byId.remove(r.externalId); // order: later wins
      byId[r.externalId] = r;
    }
    final seenHashes = <String>{};
    final unique = <VitalRecord>[];
    for (final r in byId.values) {
      if (!seenHashes.add(r.contentHash)) {
        duplicates++;
      } else {
        unique.add(r);
      }
    }

    final ids = unique.map((r) => r.externalId).toList();
    final deleted = await index.deletedExternalIds(ids);
    final knownHashes = await index.knownContentHashes(unique.map((r) => r.contentHash));
    final knownIds = skipKnownExternalIds ? await index.knownExternalIds(ids) : <String>{};
    var skippedDeleted = 0;
    final kept = <VitalRecord>[];
    for (final r in unique) {
      if (deleted.contains(r.externalId)) {
        skippedDeleted++;
      } else if (knownIds.contains(r.externalId)) {
        duplicates++;
      } else if (knownHashes.contains(r.contentHash)) {
        // Same content already stored (e.g. iCloud copy with a different id).
        duplicates++;
      } else {
        kept.add(r);
      }
    }
    return DedupeResult(kept: kept, duplicates: duplicates, skippedDeleted: skippedDeleted);
  }
}
