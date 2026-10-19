import 'package:anchored_health_native/anchored_health_native.dart';

import '../activity/activity_bridge.dart';
import '../activity/local_day.dart';
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
class NativeHealthBridge implements HealthBridge, ActivityDailyBridge {
  NativeHealthBridge({
    AnchoredHealthNative? native,
    this.includeBloodPressureCorrelation = false,
    this.deviceName,
  }) : native = native ?? AnchoredHealthNative();

  final AnchoredHealthNative native;

  /// Deprecated and ignored by the native side: HealthKit disallows correlation
  /// types in the read set (the app would be terminated), so only the systolic
  /// and diastolic quantity types are requested.
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

  /// Daily totals of a cumulative activity type (`HKStatisticsCollectionQuery`,
  /// `cumulativeSum`, local day boundaries of the device).
  @override
  Future<DailyTotalsPage> dailyTotals(String platformType, {required LocalDay from, required LocalDay to}) async {
    final r = await native.dailyTotals(type: platformType, fromDay: from.iso, toDay: to.iso);
    final days = <DailyTotal>[];
    for (final d in r.days) {
      final day = LocalDay.tryParse(d.day);
      if (day == null) continue; // not a day label: ignore instead of guessing
      days.add(DailyTotal(day: day, value: d.value));
    }
    return DailyTotalsPage(days: days, timeZoneId: r.timeZoneId.isEmpty ? null : r.timeZoneId);
  }

  /// Sample references since [anchor] of a cumulative activity type.
  @override
  Future<ActivityRefsPage> sampleRefs(String platformType, {String? anchor, DateTime? from, int limit = 5000}) async {
    final r = await native.sampleRefs(type: platformType, anchor: anchor, limit: limit, from: from);
    final hasMore = limit > 0 && (r.refs.length >= limit || r.deletedUuids.length >= limit);
    return ActivityRefsPage(
      refs: [
        for (final x in r.refs)
          ActivitySampleRef(
            uuid: x.uuid,
            start: DateTime.fromMillisecondsSinceEpoch(x.startMs, isUtc: true),
            end: DateTime.fromMillisecondsSinceEpoch(x.endMs, isUtc: true),
          )
      ],
      deletedUuids: r.deletedUuids,
      nextAnchor: r.nextAnchor ?? anchor,
      hasMore: hasMore,
    );
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
      timeZoneId: sanitizeTimeZoneId(md[HealthKitMetadataKeys.timeZone]),
    );
  }

  /// HKTimeZone of foreign sources is free text. Offset spellings such as
  /// `GMT+02:00` / `UTC-0530` are kept (the server reads them as fixed
  /// offsets, east positive) and written in one canonical form `GMT±hh:mm`;
  /// dropping them would move night sleep to the wrong day without any hint.
  /// Impossible offsets (more than 14 h, 60+ minutes), empty or overlong
  /// values and anything that is not an IANA-looking name become null.
  static String? sanitizeTimeZoneId(Object? raw) {
    if (raw is! String) return null;
    final t = raw.trim();
    if (t.isEmpty || t.length > 64) return null;
    final off = RegExp(r'^(?:GMT|UTC)([+-])([0-9]{1,2})(?::?([0-9]{2}))?$').firstMatch(t);
    if (off != null) {
      final h = int.parse(off.group(2)!);
      final m = int.parse(off.group(3) ?? '0');
      if (h > 14 || m >= 60) return null;
      return 'GMT${off.group(1)}${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    }
    if (RegExp(r'^(GMT|UTC)[+-]').hasMatch(t)) return null;
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+)*$').hasMatch(t)) return null;
    return t;
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
