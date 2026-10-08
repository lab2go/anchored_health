/// Platform-neutral data models between bridge and engine.
library;

import 'types.dart';

/// Default prefix of the sync identifier (iOS `HKMetadataKeySyncIdentifier`)
/// and client record id (Android) of values the app writes. Apps should set
/// their own prefix via [HealthWriteRequest.syncIdentifierPrefix] and
/// `EngineConfig.syncIdentifierPrefix`.
const defaultSyncIdentifierPrefix = 'app:';

/// A value read from Apple Health / Health Connect.
///
/// Blood pressure: [systolic]/[diastolic] set, [value] null, [externalId] =
/// correlation UUID (iOS) or record id (Android).
class HealthSample {
  const HealthSample({
    required this.externalId,
    required this.platformType,
    required this.start,
    required this.end,
    required this.sourcePackage,
    this.value,
    this.systolic,
    this.diastolic,
    this.unit,
    this.sourceName,
    this.deviceName,
    this.deviceManufacturer,
    this.recordingMethod = RecordingMethod.unknown,
    this.metadata = const {},
    this.syncIdentifier,
    this.syncVersion,
    this.externalUuid,
    this.timeZoneId,
  });

  /// Platform id of the record (HK UUID / HC record id).
  final String externalId;

  /// Platform type, e.g. `bloodPressure`, `bodyMass`, `bloodGlucose`.
  final String platformType;
  final DateTime start;
  final DateTime end;

  /// Value in the platform unit [unit] (converted via the catalog).
  final double? value;
  final double? systolic;
  final double? diastolic;
  final String? unit;

  /// iOS: bundle id of the source; Android: `dataOrigin.packageName`.
  final String sourcePackage;
  final String? sourceName;

  /// Device model (`HKDevice.model`, iOS only).
  final String? deviceName;
  final String? deviceManufacturer;
  final RecordingMethod recordingMethod;
  final Map<String, Object?> metadata;

  /// iOS `HKMetadataKeySyncIdentifier` (echo stage 2).
  final String? syncIdentifier;

  /// iOS `HKMetadataKeySyncVersion`; always null on Android.
  final int? syncVersion;

  /// iOS `HKMetadataKeyExternalUUID` (for own exports: the source row id).
  final String? externalUuid;

  /// IANA zone from `HKMetadataKeyTimeZone` or HC `ZoneOffset`.
  final String? timeZoneId;

  bool get isBloodPressure => systolic != null || diastolic != null;

  HealthSample copyWith({
    String? externalId,
    String? platformType,
    double? systolic,
    double? diastolic,
  }) =>
      HealthSample(
        externalId: externalId ?? this.externalId,
        platformType: platformType ?? this.platformType,
        start: start,
        end: end,
        sourcePackage: sourcePackage,
        value: value,
        systolic: systolic ?? this.systolic,
        diastolic: diastolic ?? this.diastolic,
        unit: unit,
        sourceName: sourceName,
        deviceName: deviceName,
        deviceManufacturer: deviceManufacturer,
        recordingMethod: recordingMethod,
        metadata: metadata,
        syncIdentifier: syncIdentifier,
        syncVersion: syncVersion,
        externalUuid: externalUuid,
        timeZoneId: timeZoneId,
      );

  @override
  String toString() =>
      'HealthSample($platformType $externalId ${start.toUtc().toIso8601String()} '
      '${value ?? '$systolic/$diastolic'} $sourcePackage)';
}

/// A platform id deleted in the health store.
class HealthDeletion {
  const HealthDeletion({
    required this.externalId,
    this.syncIdentifier,
    this.syncVersion,
  });
  final String externalId;
  final String? syncIdentifier;
  final int? syncVersion;
}

/// One page of an anchored/changes query or a window read.
class ChangesPage {
  const ChangesPage({
    required this.samples,
    required this.deletions,
    required this.nextToken,
    required this.hasMore,
    this.tokenExpired = false,
  });

  final List<HealthSample> samples;
  final List<HealthDeletion> deletions;

  /// iOS: Base64 anchor; Android: changes token. Persist only after a
  /// successful upload.
  final String? nextToken;
  final bool hasMore;

  /// Android `changesTokenExpired` => re-read window.
  final bool tokenExpired;
}

/// Request to write an app value to the health store (export).
class HealthWriteRequest {
  const HealthWriteRequest({
    required this.platformType,
    required this.start,
    required this.sourceRowId,
    required this.exportVersion,
    required this.wasUserEntered,
    this.end,
    this.value,
    this.systolic,
    this.diastolic,
    this.wasTakenInLab,
    this.timeZoneId,
    this.bloodGlucoseMealTime,
    this.syncIdentifierPrefix = defaultSyncIdentifierPrefix,
  });

  final String platformType;
  final DateTime start;
  final DateTime? end;

  /// Value in the platform unit of the type.
  final double? value;
  final double? systolic;
  final double? diastolic;

  /// Id of the source row in the app's own store.
  final String sourceRowId;

  /// Export version => SyncVersion / clientRecordVersion.
  final int exportVersion;
  final bool wasUserEntered;
  final bool? wasTakenInLab;
  final String? timeZoneId;

  /// 1 = before a meal, 2 = after a meal.
  final int? bloodGlucoseMealTime;

  /// App-specific prefix of [syncIdentifier]; must match
  /// `EngineConfig.syncIdentifierPrefix` so the echo filter recognizes the value.
  final String syncIdentifierPrefix;

  /// `<prefix><row_id>` (echo stage 2, ledger `sync_identifier`).
  String get syncIdentifier => '$syncIdentifierPrefix$sourceRowId';
}

/// Characteristics for the plausibility check (comparison only, never stored).
class HealthCharacteristics {
  const HealthCharacteristics({this.birthYear, this.biologicalSex});
  final int? birthYear;

  /// `female`, `male`, `other` or null.
  final String? biologicalSex;
}

enum AuthorizationRequestStatus { unknown, shouldRequest, unnecessary }

enum WritePermission { notDetermined, denied, authorized, unknown }
