import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models.dart';
import '../types.dart';
import 'type_catalog.dart';

/// An upload record for `HealthUploader.importBatch` or the arrays of
/// `HealthUploader.importSeriesBatch`. Deliberately **without** status,
/// reference range, zone or any assessment.
class VitalRecord {
  const VitalRecord({
    required this.externalId,
    required this.vitalKey,
    required this.vitalTypeId,
    required this.platformType,
    required this.measuredAt,
    required this.sourcePackage,
    required this.valueNumeric,
    required this.unit,
    required this.backfillClass,
    required this.contentHash,
    required this.mapVersion,
    this.externalVersion,
    this.endAt,
    this.timezoneId,
    this.sourceDeviceName,
    this.sourceName,
    this.recordingMethod = RecordingMethod.unknown,
    this.valueSecondary,
    this.unknownFields = 0,
  });

  final String externalId;
  final int? externalVersion;
  final VitalKey vitalKey;
  final String vitalTypeId;
  final String platformType;
  final DateTime measuredAt;
  final DateTime? endAt;
  final String? timezoneId;
  final String sourcePackage;
  final String? sourceDeviceName;

  /// Display name of the data source (HealthSample.sourceName, e.g. "Withings"). Display only:
  /// NOT part of [ContentHash] (dedupe stays unchanged).
  final String? sourceName;
  final RecordingMethod recordingMethod;

  /// Canonical value; blood pressure = systolic.
  final double valueNumeric;

  /// Blood pressure diastolic, otherwise null.
  final double? valueSecondary;
  final String unit;
  final BackfillClass backfillClass;
  final String contentHash;
  final int mapVersion;

  /// Number of required platform fields that were set to UNKNOWN.
  final int unknownFields;

  bool get isSeries => backfillClass == BackfillClass.series;

  /// JSON for the single-record upload.
  Map<String, Object?> toJson() => {
        'external_id': externalId,
        'external_version': externalVersion,
        'vital_type_id': vitalTypeId,
        'platform_type': platformType,
        'measured_at': measuredAt.toUtc().toIso8601String(),
        'end_at': endAt?.toUtc().toIso8601String(),
        'timezone_id': timezoneId,
        'source_package': sourcePackage,
        'source_device_name': sourceDeviceName,
        'source_name': sourceName,
        'recording_method': recordingMethod.name,
        'value_numeric': valueNumeric,
        'value_secondary': valueSecondary,
        'unit': unit,
        'granularity': 'raw',
        'content_hash': contentHash,
        'map_version': mapVersion,
        'unknown_fields': unknownFields,
      };
}

/// Hash contract for `content_hash`: sha256 (hex) over
/// `vital_type_id|measured_at|end_at|value_numeric|value_secondary|source_package|source_device_name`.
/// Times in UTC to the second (`YYYY-MM-DDTHH:MM:SSZ`), numbers with at most 6
/// decimals without trailing zeros, `null` as empty text. No profile id.
class ContentHash {
  static String compute({
    required String vitalTypeId,
    required DateTime measuredAt,
    DateTime? endAt,
    required double valueNumeric,
    double? valueSecondary,
    required String sourcePackage,
    String? sourceDeviceName,
  }) {
    final canonical = canonicalString(
      vitalTypeId: vitalTypeId,
      measuredAt: measuredAt,
      endAt: endAt,
      valueNumeric: valueNumeric,
      valueSecondary: valueSecondary,
      sourcePackage: sourcePackage,
      sourceDeviceName: sourceDeviceName,
    );
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  static String canonicalString({
    required String vitalTypeId,
    required DateTime measuredAt,
    DateTime? endAt,
    required double valueNumeric,
    double? valueSecondary,
    required String sourcePackage,
    String? sourceDeviceName,
  }) =>
      [
        vitalTypeId,
        formatTime(measuredAt),
        endAt == null ? '' : formatTime(endAt),
        formatNumber(valueNumeric),
        valueSecondary == null ? '' : formatNumber(valueSecondary),
        sourcePackage,
        sourceDeviceName ?? '',
      ].join('|');

  static String formatTime(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
        'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
  }

  static String formatNumber(double v) {
    var s = v.toStringAsFixed(6);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    if (s == '-0') s = '0';
    return s;
  }
}

/// Why a sample did not become a record.
enum MappingSkip { noEntry, noVitalTypeId, missingValue, incompatibleUnit }

class MappingResult {
  const MappingResult.ok(VitalRecord this.record) : skip = null;
  const MappingResult.skipped(MappingSkip this.skip) : record = null;
  final VitalRecord? record;
  final MappingSkip? skip;
}

/// Sample -> record via a catalog entry. Rounding happens only for display:
/// the full platform precision is kept after conversion.
class VitalMapper {
  const VitalMapper();

  MappingResult map(HealthSample s, TypeMappingEntry? entry) {
    if (entry == null) return const MappingResult.skipped(MappingSkip.noEntry);
    final typeId = entry.vitalTypeId;
    if (typeId == null) return const MappingResult.skipped(MappingSkip.noVitalTypeId);
    if (s.unit != null && s.unit != entry.unitPlatform) {
      return const MappingResult.skipped(MappingSkip.incompatibleUnit);
    }

    double primary;
    double? secondary;
    if (entry.vitalKey == VitalKey.bloodPressure) {
      if (s.systolic == null || s.diastolic == null) {
        return const MappingResult.skipped(MappingSkip.missingValue);
      }
      primary = entry.toCanonical(s.systolic!);
      secondary = entry.toCanonical(s.diastolic!);
    } else {
      if (s.value == null) return const MappingResult.skipped(MappingSkip.missingValue);
      primary = entry.toCanonical(s.value!);
    }

    final endAt = s.end.isAtSameMomentAs(s.start) ? null : s.end;
    final hash = ContentHash.compute(
      vitalTypeId: typeId,
      measuredAt: s.start,
      endAt: endAt,
      valueNumeric: primary,
      valueSecondary: secondary,
      sourcePackage: s.sourcePackage,
      sourceDeviceName: s.deviceName,
    );
    return MappingResult.ok(VitalRecord(
      externalId: s.externalId,
      externalVersion: s.syncVersion,
      vitalKey: entry.vitalKey,
      vitalTypeId: typeId,
      platformType: s.platformType,
      measuredAt: s.start,
      endAt: endAt,
      timezoneId: s.timeZoneId,
      sourcePackage: s.sourcePackage,
      sourceDeviceName: s.deviceName,
      sourceName: s.sourceName,
      recordingMethod: s.recordingMethod,
      valueNumeric: primary,
      valueSecondary: secondary,
      unit: entry.unitCanonical,
      backfillClass: entry.backfillClass,
      contentHash: hash,
      mapVersion: entry.mapVersion,
    ));
  }
}
