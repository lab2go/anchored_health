import 'package:flutter_test/flutter_test.dart';
import 'package:anchored_health_engine/anchored_health_engine.dart';
import 'package:anchored_health_engine/native_bridge.dart';
import 'package:anchored_health_native/anchored_health_native.dart';

import 'support/fakes.dart' show testCatalog;

/// Pigeon fake: no platform channels, synthetic values.
class FakeApi extends AnchoredHealthApi {
  final requests = <HkAnchoredQueryRequest>[];
  final saved = <HkSaveRequest>[];
  List<HkAnchoredQueryResult> pages = [];
  List<Object?> lastAuth = [];
  final dailyRequests = <HkDailyTotalsRequest>[];
  final refRequests = <HkSampleRefsRequest>[];
  HkDailyTotalsResult dailyResult = HkDailyTotalsResult(days: [], timeZoneId: '');
  List<HkSampleRefsResult> refPages = [];

  @override
  Future<HkDailyTotalsResult> dailyTotals(HkDailyTotalsRequest request) async {
    dailyRequests.add(request);
    return dailyResult;
  }

  @override
  Future<HkSampleRefsResult> sampleRefs(HkSampleRefsRequest request) async {
    refRequests.add(request);
    return refPages.isEmpty ? HkSampleRefsResult(refs: [], deletedUuids: [], nextAnchor: request.anchor) : refPages.removeAt(0);
  }

  @override
  Future<HkAnchoredQueryResult> anchoredQuery(HkAnchoredQueryRequest request) async {
    requests.add(request);
    return pages.isEmpty ? HkAnchoredQueryResult(samples: [], deleted: [], nextAnchor: request.anchor) : pages.removeAt(0);
  }

  @override
  Future<List<String>> save(List<HkSaveRequest> samples) async {
    saved.addAll(samples);
    return [for (var i = 0; i < samples.length; i++) 'UUID-$i'];
  }

  @override
  Future<bool> requestAuthorization(List<String> read, List<String> write, bool characteristics,
      bool includeBloodPressureCorrelation) async {
    lastAuth = [read, write, characteristics, includeBloodPressureCorrelation];
    return true;
  }

  @override
  Future<HkWriteStatus> writeStatus(String type) async => HkWriteStatus.sharingDenied;

  @override
  Future<HkCharacteristics> characteristics() async =>
      HkCharacteristics(birthYear: 1985, biologicalSex: 'male');
}

HkSample bpSample() => HkSample(
      uuid: 'CORR-1',
      type: 'bloodPressure',
      startMs: DateTime.utc(2026, 9, 1, 8).millisecondsSinceEpoch,
      endMs: DateTime.utc(2026, 9, 1, 8).millisecondsSinceEpoch,
      unit: 'mmHg',
      bloodPressure: HkBloodPressure(systolic: 128, diastolic: 82, systolicUuid: 'S', diastolicUuid: 'D'),
      source: HkSource(bundleId: 'com.example.cuff', name: 'Cuff'),
      device: HkDevice(name: 'Cuff', model: 'BP-7', manufacturer: 'Example'),
      metadata: {
        'HKWasUserEntered': false,
        'HKMetadataKeySyncIdentifier': 'vendor:42',
        'HKMetadataKeySyncVersion': 3,
        'HKTimeZone': 'UTC',
      },
    );

void main() {
  test('HKTimeZone: IANA names pass, offsets are normalised to GMT+-hh:mm, junk becomes null', () {
    for (final ok in ['Europe/Berlin', 'UTC', 'GMT', 'America/Argentina/Buenos_Aires', 'Etc/GMT+2']) {
      expect(NativeHealthBridge.sanitizeTimeZoneId(ok), ok, reason: ok);
    }
    const normalised = {
      'GMT+02:00': 'GMT+02:00',
      'GMT+01:00': 'GMT+01:00',
      'GMT-04:00': 'GMT-04:00',
      'GMT+2': 'GMT+02:00',
      'GMT+0200': 'GMT+02:00',
      'UTC-0530': 'GMT-05:30',
      'UTC+05:30': 'GMT+05:30',
      'GMT+14:00': 'GMT+14:00',
      'GMT+00:00': 'GMT+00:00',
      ' GMT+02:00 ': 'GMT+02:00',
    };
    normalised.forEach((raw, want) {
      expect(NativeHealthBridge.sanitizeTimeZoneId(raw), want, reason: raw);
    });
    for (final bad in [
      'GMT+15:00', 'GMT+99', 'GMT+02:60', 'GMT+', 'GMT+02:0', 'GMT+020000', 'UTC+1:2:3',
      '', '  ', 'Mars/Olympus Mons', 'x' * 65, 42, null
    ]) {
      expect(NativeHealthBridge.sanitizeTimeZoneId(bad), isNull, reason: '$bad');
    }
    final s = NativeHealthBridge.sampleFromNative(HkSample(
        uuid: 'TZ-1', type: 'sleepAnalysis', startMs: 0, endMs: 60000, value: 3, unit: 'stage',
        source: HkSource(bundleId: 'com.example.ring', name: 'Ring'), metadata: {'HKTimeZone': 'GMT-04:00'}));
    expect(s.timeZoneId, 'GMT-04:00');
  });

  test('Pigeon sample -> engine sample: correlation, device, metadata', () {
    final s = NativeHealthBridge.sampleFromNative(bpSample());
    expect(s.externalId, 'CORR-1');
    expect(s.systolic, 128);
    expect(s.diastolic, 82);
    expect(s.value, isNull);
    expect(s.sourcePackage, 'com.example.cuff');
    expect(s.deviceName, 'BP-7', reason: 'source_device_name = HKDevice.model');
    expect(s.recordingMethod, RecordingMethod.automatic);
    expect(s.syncIdentifier, 'vendor:42');
    expect(s.syncVersion, 3);
    expect(s.timeZoneId, 'UTC');
    expect(s.start.isUtc, isTrue);
  });

  test('export request -> Pigeon: sync identifier, sync version, ExternalUUID, lab flag', () {
    final r = NativeHealthBridge.saveRequestFor(HealthWriteRequest(
      platformType: 'bloodGlucose',
      start: DateTime.utc(2026, 9, 1, 7),
      value: 92,
      sourceRowId: 'row-1',
      exportVersion: 4,
      wasUserEntered: false,
      wasTakenInLab: true,
      timeZoneId: 'UTC',
      bloodGlucoseMealTime: 1,
    ));
    expect(r.syncIdentifier, 'app:row-1');
    expect(r.deviceName, isNull);
    expect(r.syncVersion, 4);
    expect(r.externalUuid, 'row-1');
    expect(r.wasTakenInLab, isTrue);
    expect(r.endMs, r.startMs);
    expect(r.bloodGlucoseMealTime, 1);
  });

  test('changes: anchor passed through, hasMore on a full page, window in ms', () async {
    final api = FakeApi()
      ..pages = [
        HkAnchoredQueryResult(samples: [bpSample(), bpSample()], deleted: [HkDeletedObject(uuid: 'X', syncIdentifier: 'app:r', syncVersion: 2)], nextAnchor: 'A2'),
        HkAnchoredQueryResult(samples: [], deleted: [], nextAnchor: 'A3'),
      ];
    final b = NativeHealthBridge(native: AnchoredHealthNative(api: api, isSupportedPlatform: true));
    final from = DateTime.utc(2026, 9, 1);
    final p1 = await b.changes('bloodPressure', token: 'A1', from: from, limit: 2);
    expect(p1.hasMore, isTrue);
    expect(p1.nextToken, 'A2');
    expect(p1.deletions.single.syncIdentifier, 'app:r');
    expect(api.requests.single.anchor, 'A1');
    expect(api.requests.single.fromMs, from.millisecondsSinceEpoch);
    final p2 = await b.changes('bloodPressure', token: 'A2', limit: 2);
    expect(p2.hasMore, isFalse);
    expect(p2.nextToken, 'A3');
  });

  test('read: window read over several pages, starts with a nil anchor', () async {
    final api = FakeApi()
      ..pages = [
        HkAnchoredQueryResult(samples: [bpSample()], deleted: [], nextAnchor: 'B1'),
        HkAnchoredQueryResult(samples: [bpSample()], deleted: [], nextAnchor: 'B2'),
        HkAnchoredQueryResult(samples: [], deleted: [], nextAnchor: 'B2'),
      ];
    final b = NativeHealthBridge(native: AnchoredHealthNative(api: api, isSupportedPlatform: true));
    final out = await b.read('bloodPressure', from: DateTime.utc(2026, 8, 1), to: DateTime.utc(2026, 9, 1), limit: 1);
    expect(out, hasLength(2));
    expect(api.requests.first.anchor, isNull);
    expect(api.requests.first.toMs, DateTime.utc(2026, 9, 1).millisecondsSinceEpoch);
  });

  test('authorization: one call, correlation switch passed through', () async {
    final api = FakeApi();
    final b = NativeHealthBridge(
        native: AnchoredHealthNative(api: api, isSupportedPlatform: true), includeBloodPressureCorrelation: false);
    await b.requestAuthorization(read: {'bloodPressure'}, write: {'bodyMass'}, characteristics: true);
    expect(api.lastAuth, [
      ['bloodPressure'],
      ['bodyMass'],
      true,
      false
    ]);
    expect(await b.writePermission('bodyMass'), WritePermission.denied);
    expect((await b.characteristics())!.birthYear, 1985);
  });

  test('write returns the UUIDs in input order', () async {
    final api = FakeApi();
    final b = NativeHealthBridge(native: AnchoredHealthNative(api: api, isSupportedPlatform: true));
    final ids = await b.write([
      HealthWriteRequest(platformType: 'bodyMass', start: DateTime.utc(2026), value: 70, sourceRowId: 'a', exportVersion: 1, wasUserEntered: true),
      HealthWriteRequest(platformType: 'bloodPressure', start: DateTime.utc(2026), systolic: 120, diastolic: 80, sourceRowId: 'b', exportVersion: 1, wasUserEntered: true),
    ]);
    expect(ids, ['UUID-0', 'UUID-1']);
    expect(api.saved[1].systolic, 120);
    expect(api.saved[0].deviceName, isNull);
  });

  test('write: configured device name and sync identifier prefix', () async {
    final api = FakeApi();
    final b = NativeHealthBridge(native: AnchoredHealthNative(api: api, isSupportedPlatform: true), deviceName: 'Example App');
    await b.write([
      HealthWriteRequest(
          platformType: 'bodyMass',
          start: DateTime.utc(2026),
          value: 70,
          sourceRowId: 'a',
          exportVersion: 1,
          wasUserEntered: true,
          syncIdentifierPrefix: 'acme:'),
    ]);
    expect(api.saved.single.deviceName, 'Example App');
    expect(api.saved.single.syncIdentifier, 'acme:a');
  });

  test('unsupported platform: facade throws, availability false', () async {
    final n = AnchoredHealthNative(api: FakeApi(), isSupportedPlatform: false);
    expect(await n.isHealthDataAvailable(), isFalse);
    expect(() => n.anchoredQuery(type: 'bodyMass'), throwsA(isA<HealthPlatformUnsupported>()));
    expect(() => n.save(const []), throwsA(isA<UnsupportedError>()));
  });

  test('dailyTotals: day labels pass through, junk labels are ignored, zone is reported', () async {
    final api = FakeApi()
      ..dailyResult = HkDailyTotalsResult(timeZoneId: 'Europe/Berlin', days: [
        HkDailyTotal(day: '2026-03-28', value: 8000, startMs: 1, endMs: 2),
        HkDailyTotal(day: '2026-03-29', value: 7000.5, startMs: 2, endMs: 3),
        HkDailyTotal(day: 'garbage', value: 1, startMs: 3, endMs: 4),
      ]);
    final bridge = NativeHealthBridge(native: AnchoredHealthNative(api: api, isSupportedPlatform: true));
    final page = await bridge.dailyTotals('stepCount', from: LocalDay.parse('2026-03-28'), to: LocalDay.parse('2026-03-30'));
    expect((api.dailyRequests.single.type, api.dailyRequests.single.fromDay, api.dailyRequests.single.toDay),
        ('stepCount', '2026-03-28', '2026-03-30'));
    expect(page.days.map((d) => (d.day.iso, d.value)), [('2026-03-28', 8000.0), ('2026-03-29', 7000.5)]);
    expect(page.timeZoneId, 'Europe/Berlin');
    api.dailyResult = HkDailyTotalsResult(days: [], timeZoneId: '');
    expect((await bridge.dailyTotals('stepCount', from: LocalDay.parse('2026-03-28'), to: LocalDay.parse('2026-03-28'))).timeZoneId, isNull);
  });

  test('sampleRefs: UTC instants, deleted UUIDs, anchor kept when nothing new, hasMore on a full page', () async {
    final api = FakeApi()
      ..refPages = [
        HkSampleRefsResult(
            refs: [HkSampleRef(uuid: 'U1', startMs: 1000, endMs: 2000), HkSampleRef(uuid: 'U2', startMs: 3000, endMs: 3000)],
            deletedUuids: ['D1'],
            nextAnchor: 'A2'),
        HkSampleRefsResult(refs: [], deletedUuids: [], nextAnchor: null),
      ];
    final bridge = NativeHealthBridge(native: AnchoredHealthNative(api: api, isSupportedPlatform: true));
    final p1 = await bridge.sampleRefs('stepCount', anchor: 'A1', limit: 2, from: DateTime.utc(2026, 9, 1));
    expect(api.refRequests.single.anchor, 'A1');
    expect(api.refRequests.single.fromMs, DateTime.utc(2026, 9, 1).millisecondsSinceEpoch);
    expect(p1.refs.map((r) => r.uuid), ['U1', 'U2']);
    expect(p1.refs.first.start, DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true));
    expect(p1.deletedUuids, ['D1']);
    expect(p1.hasMore, isTrue);
    expect(p1.nextAnchor, 'A2');
    final p2 = await bridge.sampleRefs('stepCount', anchor: 'A2', limit: 2);
    expect(p2.hasMore, isFalse);
    expect(p2.nextAnchor, 'A2', reason: 'no new anchor: keep the old one');
  });

  test('the native bridge feeds ActivityDailySync end to end (fake Pigeon API)', () async {
    final api = FakeApi()
      ..dailyResult = HkDailyTotalsResult(timeZoneId: 'Europe/Berlin', days: [
        HkDailyTotal(day: '2026-10-18', value: 4321, startMs: 1, endMs: 2),
      ])
      ..refPages = [
        HkSampleRefsResult(refs: [HkSampleRef(uuid: 'U1', startMs: 1, endMs: 2)], deletedUuids: [], nextAnchor: 'A1')
      ];
    final bridge = NativeHealthBridge(native: AnchoredHealthNative(api: api, isSupportedPlatform: true));
    final sent = <ActivityIngestElement>[];
    final sync = ActivityDailySync(
      bridge: bridge,
      catalog: testCatalog(),
      state: SyncStateStore(InMemoryKeyValueStore()),
      uploader: _Collect(sent),
      session: const FixedSession('u', 'p'),
      clock: () => DateTime.now(),
    );
    final link = const HealthLink(linkId: 'l', userId: 'u', profileId: 'p', platform: HealthPlatform.appleHealth);
    final r = await sync.syncNow(link, types: {'stepCount'}, lookbackDays: 1825);
    expect(r.outcome, SyncOutcome.success);
    expect(api.dailyRequests.single.type, 'stepCount');
    expect(api.refRequests.first.anchor, isNull);
    expect(api.refRequests.first.fromMs, isNotNull, reason: 'the first run only indexes the recent window');
    expect(api.refRequests.first.limit, 5000);
    expect(sent.single.day.iso, '2026-10-18');
    expect(sent.single.valueNumeric, 4321);
  });
}

class _Collect implements ActivityDailyUploader {
  _Collect(this.sent);
  final List<ActivityIngestElement> sent;
  @override
  Future<ActivityIngestResult> ingestDaily(String linkId, List<ActivityIngestElement> days) async {
    sent.addAll(days);
    return ActivityIngestResult(inserted: days.length); // the answer must account for the batch (review P3 A1)
  }
}
