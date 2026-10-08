// Pigeon interface AnchoredHealthApi (Dart <-> Swift).
// Generate: dart run pigeon --input pigeons/messages.dart
// Times are milliseconds since epoch (UTC). Types are platform type keys
// (e.g. "bloodPressure", "bodyMass"), see README.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    swiftOut:
        'ios/anchored_health_native/Sources/anchored_health_native/Messages.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'anchored_health_native',
  ),
)
/// Result of `getRequestStatusForAuthorization`.
enum HkRequestStatus {
  /// Status unknown (error or not available).
  unknown,

  /// The dialog has never been shown for at least one type.
  shouldRequest,

  /// The dialog has already been shown for all types.
  unnecessary,
}

/// Result of `authorizationStatus(for:)` (only write access can be queried).
enum HkWriteStatus { notDetermined, sharingDenied, sharingAuthorized, unknown }

/// Source of a sample (`HKSourceRevision`).
class HkSource {
  HkSource({required this.bundleId, required this.name});
  String bundleId;
  String name;
  String? version;
  String? productType;
  String? operatingSystemVersion;
}

/// Measuring device (`HKDevice`), all fields optional.
class HkDevice {
  String? name;
  String? model;
  String? manufacturer;
  String? hardwareVersion;
  String? firmwareVersion;
  String? softwareVersion;
  String? localIdentifier;
  String? udiDeviceIdentifier;
}

/// Blood pressure from an `HKCorrelation` (mmHg).
class HkBloodPressure {
  HkBloodPressure({
    required this.systolic,
    required this.diastolic,
  });
  double systolic;
  double diastolic;
  String? systolicUuid;
  String? diastolicUuid;
}

/// A sample that was read. For blood pressure, `uuid` is the UUID of the
/// correlation, `value` is null and `bloodPressure` is set.
class HkSample {
  HkSample({
    required this.uuid,
    required this.type,
    required this.startMs,
    required this.endMs,
    required this.source,
    required this.metadata,
  });
  String uuid;
  String type;
  int startMs;
  int endMs;

  /// Value in the fixed plugin unit of the type (see `unit`).
  double? value;
  String? unit;
  HkBloodPressure? bloodPressure;
  HkSource source;
  HkDevice? device;

  /// HealthKit metadata: strings, numbers, bools; dates as ms since epoch,
  /// quantities as text.
  Map<String?, Object?> metadata;
}

/// Deleted object from `deletedObjects` of the anchored query.
class HkDeletedObject {
  HkDeletedObject({required this.uuid});
  String uuid;
  String? syncIdentifier;
  int? syncVersion;
}

class HkAnchoredQueryRequest {
  HkAnchoredQueryRequest({required this.type, required this.limit});
  String type;

  /// Base64 of an `HKQueryAnchor` archived with NSKeyedArchiver; null = first run.
  String? anchor;

  /// Maximum number of samples per call (0 = no limit).
  int limit;

  /// Optional time window on the sample start time, `fromMs` inclusive,
  /// `toMs` exclusive.
  int? fromMs;
  int? toMs;
}

class HkAnchoredQueryResult {
  HkAnchoredQueryResult({
    required this.samples,
    required this.deleted,
  });
  List<HkSample> samples;
  List<HkDeletedObject> deleted;
  String? nextAnchor;
}

/// Sample to write. For blood pressure set `systolic`/`diastolic` (creates
/// exactly one `HKCorrelation`), otherwise `value`.
class HkSaveRequest {
  HkSaveRequest({
    required this.type,
    required this.startMs,
    required this.endMs,
    required this.syncIdentifier,
    required this.syncVersion,
    required this.wasUserEntered,
  });
  String type;
  int startMs;
  int endMs;
  double? value;
  double? systolic;
  double? diastolic;

  /// `HKMetadataKeySyncIdentifier`, e.g. `app:<row_id>`. Must not be empty.
  String syncIdentifier;

  /// `HKMetadataKeySyncVersion` (export version of the row).
  int syncVersion;

  /// `HKMetadataKeyExternalUUID` (row id).
  String? externalUuid;
  bool wasUserEntered;
  bool? wasTakenInLab;

  /// IANA time zone for `HKMetadataKeyTimeZone`.
  String? timeZone;

  /// `HKBloodGlucoseMealTime`: 1 = preprandial, 2 = postprandial.
  int? bloodGlucoseMealTime;

  /// Name of the `HKDevice` attached to the written objects; null = no device.
  String? deviceName;
}

class HkCharacteristics {
  int? birthYear;
  int? birthMonth;
  int? birthDay;

  /// "female", "male", "other" or null (not set / no permission).
  String? biologicalSex;
}

@HostApi()
abstract class AnchoredHealthApi {
  /// `HKHealthStore.isHealthDataAvailable()`.
  bool isHealthDataAvailable();

  /// Platform types supported by the plugin.
  List<String> supportedTypes();

  /// Fixed unit per type in which `value` is delivered/expected.
  String unitFor(String type);

  /// Whether `requestAuthorization` would still show a dialog for this set.
  @async
  HkRequestStatus requestStatus(
    List<String> read,
    List<String> write,
    bool characteristics,
    bool includeBloodPressureCorrelation,
  );

  /// One dialog for the union of all types. `true` = the dialog ran without
  /// error (says nothing about the granted permissions).
  @async
  bool requestAuthorization(
    List<String> read,
    List<String> write,
    bool characteristics,
    bool includeBloodPressureCorrelation,
  );

  /// Write status per type (read status cannot be queried in HealthKit).
  HkWriteStatus writeStatus(String type);

  @async
  HkAnchoredQueryResult anchoredQuery(HkAnchoredQueryRequest request);

  /// Saves all samples in one call; returns UUIDs in input order (for blood
  /// pressure the UUID of the correlation).
  @async
  List<String> save(List<HkSaveRequest> samples);

  /// Deletes own objects by UUID; returns the number of deleted objects.
  @async
  int delete(String type, List<String> uuids);

  /// Date of birth / biological sex (comparison only, nothing is stored).
  HkCharacteristics characteristics();
}
