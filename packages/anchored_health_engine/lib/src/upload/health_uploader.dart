import '../mapping/vital_record.dart';
import '../types.dart';

/// Interface to the app's backend. The app implements it (e.g. with RPCs of
/// its database); the engine knows no URL, no key and no client.
abstract class HealthUploader {
  /// Uploads single records (see [VitalRecord.toJson]), chunk <= 200.
  Future<ImportBatchResult> importBatch(String linkId, List<VitalRecord> records);

  /// Uploads a series batch (see [SeriesBatch.toRpcParams]), chunk 1,000-2,000.
  Future<SeriesBatchResult> importSeriesBatch(String linkId, SeriesBatch batch);

  /// Applies deletions by external id; returns the number of deleted rows.
  Future<int> applyDeletions(String linkId, List<String> externalIds);

  /// Writes a run log entry: counters only, never values.
  Future<void> logRun(String linkId, SyncRunLog log);
}

class ImportBatchResult {
  const ImportBatchResult({
    this.inserted = 0,
    this.updated = 0,
    this.duplicates = 0,
    this.skippedDeleted = 0,
    this.unknownFields = 0,
  });
  final int inserted;
  final int updated;
  final int duplicates;
  final int skippedDeleted;
  final int unknownFields;
}

class SeriesBatchResult {
  const SeriesBatchResult({
    this.inserted = 0,
    this.duplicates = 0,
    this.skippedDeleted = 0,
    this.skippedCompacted = 0,
    this.skippedOtherSource = 0,
  });
  final int inserted;
  final int duplicates;
  final int skippedDeleted;
  final int skippedCompacted;
  final int skippedOtherSource;
}

/// Array payload for a series upload (one source, one type).
class SeriesBatch {
  SeriesBatch({
    required this.vitalTypeId,
    required this.sourcePackage,
    required List<VitalRecord> records,
    this.timezoneId,
    this.sourceDeviceName,
  }) : records = List.unmodifiable(records) {
    for (final r in records) {
      if (r.vitalTypeId != vitalTypeId || r.sourcePackage != sourcePackage) {
        throw ArgumentError('SeriesBatch: mixed types/sources');
      }
    }
  }

  final String vitalTypeId;
  final String sourcePackage;
  final List<VitalRecord> records;
  final String? timezoneId;
  final String? sourceDeviceName;

  int get length => records.length;

  /// Parameters as named arrays (one entry per record).
  Map<String, Object?> toRpcParams(String linkId) => {
        'link_id': linkId,
        'vital_type_id': vitalTypeId,
        'source_package': sourcePackage,
        'measured_at': [for (final r in records) r.measuredAt.toUtc().toIso8601String()],
        'value_numeric': [for (final r in records) r.valueNumeric],
        'external_id': [for (final r in records) r.externalId],
        'content_hash': [for (final r in records) r.contentHash],
        'timezone_id': timezoneId,
        'source_device_name': sourceDeviceName,
      };
}

/// Run log entry of a sync run; never contains values.
class SyncRunLog {
  const SyncRunLog({
    required this.trigger,
    required this.outcome,
    required this.types,
    required this.counters,
    this.errorCode,
    this.windowStart,
    this.windowEnd,
    this.event,
  });
  final SyncTrigger trigger;
  final SyncOutcome outcome;
  final List<String> types;
  final Map<String, int> counters;
  final String? errorCode;
  final DateTime? windowStart;
  final DateTime? windowEnd;

  /// Event name, e.g. `source_detected`.
  final String? event;
}
