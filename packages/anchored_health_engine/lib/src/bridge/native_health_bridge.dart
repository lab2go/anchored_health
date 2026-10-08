import 'package:anchored_health_native/anchored_health_native.dart';

import '../models.dart';
import '../types.dart';
import 'health_bridge.dart';

/// Raw HealthKit metadata keys (checked against the SDK constants by a Swift
/// test: `RunnerTests.testMetadataKeyRawValues`).
abstract final class HealthKitMetadataKeys {
  static const syncIdentifier = 'HKMetadataKeySyncIdentifier';
  static const syncVersion = 'HKMetadataKeySyncVersion';
  static const externalUuid = 'HKExternalUUID';
  static const wasUserEntered = 'HKWasUserEntered';
  static const timeZone = 'HKTimeZone';
  static const wasTakenInLab = 'HKWasTakenInLab';
  static const bloodGlucoseMealTime = 'HKBloodGlucoseMealTime';
}

/// iOS implementation of [HealthBridge] via `anchored_health_native`.
/// On iOS, only this plugin should call `requestAuthorization`.
class NativeHealthBridge implements HealthBridge {
  NativeHealthBridge({
    AnchoredHealthNative? native,
    this.includeBloodPressureCorrelation = true,
    this.deviceName,
  }) : native = native ?? AnchoredHealthNative();

  final AnchoredHealthNative native;

  /// Also request the correlation type in the read set.
  final bool includeBloodPressureCorrelation;

  /// Name of the `HKDevice` attached to written values (e.g. the app name);
  /// null = no device.
  final String? deviceName;

  @override
  HealthPlatform get platform => HealthPlatform.appleHealth;

  @override
  bool get firstRunIncludesHistory => true;

  @override
  Future<bool> isAvailable() => native.isHealthDataAvailable();

  @override
  Future<bool> requestAuthorization({
    required Set<String> read,
    required Set<String> write,
    bool characteristics = false,
  }) =>
      native.requestAuthorization(
        read: read.toList(),
        write: write.toList(),
        characteristics: characteristics,
        includeBloodPressureCorrelation: includeBloodPressureCorrelation,
      );

  @override
  Future<AuthorizationRequestStatus> authorizationRequestStatus({
    required Set<String> read,
    required Set<String> write,
    bool characteristics = false,
  }) async {
    final s = await native.requestStatus(
      read: read.toList(),
      write: write.toList(),
      characteristics: characteristics,
      includeBloodPressureCorrelation: includeBloodPressureCorrelation,
    );
    return switch (s) {
      HkRequestStatus.shouldRequest => AuthorizationRequestStatus.shouldRequest,
      HkRequestStatus.unnecessary => AuthorizationRequestStatus.unnecessary,
      HkRequestStatus.unknown => AuthorizationRequestStatus.unknown,
    };
  }

  @override
  Future<WritePermission> writePermission(String platformType) async {
    final s = await native.writeStatus(platformType);
    return switch (s) {
      HkWriteStatus.sharingAuthorized => WritePermission.authorized,
      HkWriteStatus.sharingDenied => WritePermission.denied,
      HkWriteStatus.notDetermined => WritePermission.notDetermined,
      HkWriteStatus.unknown => WritePermission.unknown,
    };
  }

  @override
  Future<ChangesPage> changes(
    String platformType, {
    String? token,
    DateTime? from,
    DateTime? to,
    int limit = 1000,
  }) async {
    final r = await native.anchoredQuery(
      type: platformType,
      anchor: token,
      limit: limit,
      from: from,
      to: to,
    );
    final hasMore = limit > 0 && (r.samples.length >= limit || r.deleted.length >= limit);
    return ChangesPage(
      samples: r.samples.map(sampleFromNative).toList(),
      deletions: r.deleted
          .map((d) => HealthDeletion(
                externalId: d.uuid,
                syncIdentifier: d.syncIdentifier,
                syncVersion: d.syncVersion,
              ))
          .toList(),
      nextToken: r.nextAnchor ?? token,
      hasMore: hasMore,
    );
  }

  /// iOS has no baseline token (history comes with the `nil` anchor).
  @override
  Future<String?> baselineToken(String platformType) async => null;

  /// Window read via anchored query starting with a `nil` anchor; the anchor
  /// is discarded.
  @override
  Future<List<HealthSample>> read(
    String platformType, {
    required DateTime from,
    required DateTime to,
    int limit = 1000,
  }) async {
    final out = <HealthSample>[];
    String? anchor;
    while (true) {
      final page = await changes(platformType, token: anchor, from: from, to: to, limit: limit);
      out.addAll(page.samples);
      if (!page.hasMore || page.nextToken == anchor) break;
      anchor = page.nextToken;
    }
    return out;
  }

  @override
  Future<List<String?>> write(List<HealthWriteRequest> requests) async {
    final ids = await native.save([for (final r in requests) saveRequestFor(r, deviceName: deviceName)]);
    return ids.cast<String?>();
  }

  @override
  Future<int> delete(String platformType, List<String> ids) => native.delete(platformType, ids);

  @override
  Future<HealthCharacteristics?> characteristics() async {
    final c = await native.characteristics();
    return HealthCharacteristics(birthYear: c.birthYear, biologicalSex: c.biologicalSex);
  }

  /// Pigeon sample -> engine sample.
  static HealthSample sampleFromNative(HkSample s) {
    final md = <String, Object?>{
      for (final e in s.metadata.entries)
        if (e.key != null) e.key!: e.value
    };
    final wasUserEntered = md[HealthKitMetadataKeys.wasUserEntered];
    final sv = md[HealthKitMetadataKeys.syncVersion];
    return HealthSample(
      externalId: s.uuid,
      platformType: s.type,
      start: DateTime.fromMillisecondsSinceEpoch(s.startMs, isUtc: true),
      end: DateTime.fromMillisecondsSinceEpoch(s.endMs, isUtc: true),
      value: s.value,
      systolic: s.bloodPressure?.systolic,
      diastolic: s.bloodPressure?.diastolic,
      unit: s.unit,
      sourcePackage: s.source.bundleId,
      sourceName: s.source.name,
      deviceName: s.device?.model,
      deviceManufacturer: s.device?.manufacturer,
      recordingMethod: wasUserEntered == true
          ? RecordingMethod.manual
          : (wasUserEntered == false ? RecordingMethod.automatic : RecordingMethod.unknown),
      metadata: md,
      syncIdentifier: md[HealthKitMetadataKeys.syncIdentifier] as String?,
      syncVersion: sv is int ? sv : (sv is num ? sv.toInt() : null),
      externalUuid: md[HealthKitMetadataKeys.externalUuid] as String?,
      timeZoneId: md[HealthKitMetadataKeys.timeZone] as String?,
    );
  }

  /// Engine request -> Pigeon save request (sync metadata).
  static HkSaveRequest saveRequestFor(HealthWriteRequest r, {String? deviceName}) => HkSaveRequest(
        type: r.platformType,
        startMs: r.start.toUtc().millisecondsSinceEpoch,
        endMs: (r.end ?? r.start).toUtc().millisecondsSinceEpoch,
        value: r.value,
        systolic: r.systolic,
        diastolic: r.diastolic,
        syncIdentifier: r.syncIdentifier,
        syncVersion: r.exportVersion,
        externalUuid: r.sourceRowId,
        wasUserEntered: r.wasUserEntered,
        wasTakenInLab: r.wasTakenInLab,
        timeZone: r.timeZoneId,
        bloodGlucoseMealTime: r.bloodGlucoseMealTime,
        deviceName: deviceName,
      );
}
