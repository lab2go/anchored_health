import '../types.dart';
import 'local_day.dart';

/// One element of `p_days` of the RPC `health_ingest_daily` (contract of P2).
///
/// Deliberately **without** `external_version` (corrections need no version) and
/// without `deleted` (a tombstone is only ever sent on an explicit user wish,
/// never by the engine, never because a read came back empty).
class ActivityIngestElement {
  const ActivityIngestElement({
    required this.vitalTypeId,
    required this.platformType,
    required this.vitalKey,
    required this.day,
    required this.valueNumeric,
    required this.sourcePackage,
    required this.unit,
    this.sourceName,
    this.mapVersion,
  });

  final String vitalTypeId;
  final String platformType;
  final VitalKey vitalKey;

  /// Local calendar day of the device (`YYYY-MM-DD`); the server cuts the real
  /// day boundaries.
  final LocalDay day;

  /// Daily sum >= 0 in the canonical unit.
  final double valueNumeric;

  /// Fixed name of the merged source (see `ActivityDailyConfig.sourcePackage`).
  final String sourcePackage;
  final String unit;

  /// Display name of the source (not part of any key).
  final String? sourceName;
  final int? mapVersion;

  /// Element for `p_days`.
  Map<String, Object?> toJson() => {
        'vital_type_id': vitalTypeId,
        'platform_type': platformType,
        'day': day.iso,
        'value_numeric': valueNumeric,
        'source_package': sourcePackage,
        'unit': unit,
        if (sourceName != null) 'source_name': sourceName,
        if (mapVersion != null) 'map_version': mapVersion,
      };
}

/// Return value of `health_ingest_daily`.
class ActivityIngestResult {
  const ActivityIngestResult({
    this.inserted = 0,
    this.updated = 0,
    this.deleted = 0,
    this.duplicates = 0,
    this.skippedDeleted = 0,
    this.echo = 0,
    this.rejected = 0,
    this.unknownFields = 0,
    this.timezoneId,
  });

  final int inserted;
  final int updated;
  final int deleted;
  final int duplicates;
  final int skippedDeleted;
  final int echo;
  final int rejected;
  final int unknownFields;

  /// `timezone_id` of the answer: the zone in which the server cut the days.
  /// The engine stores it and sends the whole look-back again when it changes.
  final String? timezoneId;

  /// From the RPC's JSON answer (`{inserted, updated, ..., timezone_id}`).
  factory ActivityIngestResult.fromJson(Map<String, Object?> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return ActivityIngestResult(
      inserted: n('inserted'),
      updated: n('updated'),
      deleted: n('deleted'),
      duplicates: n('duplicates'),
      skippedDeleted: n('skipped_deleted'),
      echo: n('echo'),
      rejected: n('rejected'),
      unknownFields: n('unknown_fields'),
      timezoneId: j['timezone_id'] as String?,
    );
  }
}

/// Interface to the app's backend for the daily totals. The app implements it
/// with `rpc('health_ingest_daily', {p_link_id, p_days, p_run_id})`.
abstract class ActivityDailyUploader {
  /// Sends one batch (<= 2000 elements, one type, a limited period).
  Future<ActivityIngestResult> ingestDaily(String linkId, List<ActivityIngestElement> days);
}

/// Forms batches: one type per batch, sorted by
/// day, at most [maxSize] elements and at most [maxSpanDays] days between the
/// first and the last day, so that everyday days and far-back corrections do
/// not travel in the same batch (review A3). Newest batch first.
List<List<ActivityIngestElement>> buildActivityBatches(
  Iterable<ActivityIngestElement> elements, {
  int maxSize = 2000,
  int maxSpanDays = 45,
}) {
  if (maxSize < 1 || maxSize > 2000) throw ArgumentError.value(maxSize, 'maxSize', 'must be 1..2000');
  if (maxSpanDays < 1) throw ArgumentError.value(maxSpanDays, 'maxSpanDays');
  final byType = <String, List<ActivityIngestElement>>{};
  for (final e in elements) {
    byType.putIfAbsent('${e.vitalTypeId}|${e.platformType}', () => []).add(e);
  }
  final batches = <List<ActivityIngestElement>>[];
  for (final group in byType.values) {
    group.sort((a, b) => a.day.compareTo(b.day));
    var current = <ActivityIngestElement>[];
    for (final e in group) {
      if (current.isNotEmpty &&
          (current.length >= maxSize || current.first.day.daysUntil(e.day) >= maxSpanDays)) {
        batches.add(current);
        current = <ActivityIngestElement>[];
      }
      current.add(e);
    }
    if (current.isNotEmpty) batches.add(current);
  }
  // Newest period first, so that today's value arrives before old corrections.
  batches.sort((a, b) => b.last.day.compareTo(a.last.day));
  return batches;
}
