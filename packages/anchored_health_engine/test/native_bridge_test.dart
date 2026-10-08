import 'package:flutter_test/flutter_test.dart';
import 'package:anchored_health_engine/anchored_health_engine.dart';
import 'package:anchored_health_engine/native_bridge.dart';
import 'package:anchored_health_native/anchored_health_native.dart';

/// Pigeon fake: no platform channels, synthetic values.
class FakeApi extends AnchoredHealthApi {
  final requests = <HkAnchoredQueryRequest>[];
  final saved = <HkSaveRequest>[];
  List<HkAnchoredQueryResult> pages = [];
  List<Object?> lastAuth = [];

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
}
