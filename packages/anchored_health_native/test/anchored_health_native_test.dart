import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anchored_health_native/anchored_health_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android/other platforms: stub throws "not supported"', () async {
    final n = AnchoredHealthNative(isSupportedPlatform: false);
    expect(await n.isHealthDataAvailable(), isFalse);
    expect(() => n.requestAuthorization(read: ['bodyMass'], write: []), throwsA(isA<HealthPlatformUnsupported>()));
    expect(() => n.anchoredQuery(type: 'bodyMass'), throwsA(isA<HealthPlatformUnsupported>()));
    expect(() => n.delete('bodyMass', ['x']), throwsA(isA<HealthPlatformUnsupported>()));
    expect(() => n.dailyTotals(type: 'stepCount', fromDay: '2026-10-01', toDay: '2026-10-19'),
        throwsA(isA<HealthPlatformUnsupported>()));
    expect(() => n.sampleRefs(type: 'stepCount'), throwsA(isA<HealthPlatformUnsupported>()));
  });

  test('default without override follows the target platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(AnchoredHealthNative().isSupportedPlatform, isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(AnchoredHealthNative().isSupportedPlatform, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  test('Pigeon channel: anchoredQuery encodes request and response', () async {
    const channel = 'dev.flutter.pigeon.anchored_health_native.AnchoredHealthApi.anchoredQuery';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = AnchoredHealthApi.pigeonChannelCodec;
    HkAnchoredQueryRequest? seen;
    messenger.setMockMessageHandler(channel, (ByteData? message) async {
      final args = codec.decodeMessage(message) as List<Object?>;
      seen = args.first as HkAnchoredQueryRequest;
      final result = HkAnchoredQueryResult(
        samples: [
          HkSample(
            uuid: 'U1',
            type: 'bodyMass',
            startMs: 1,
            endMs: 1,
            value: 70.5,
            unit: 'kg',
            source: HkSource(bundleId: 'com.example.scale', name: 'Scale'),
            metadata: {'HKWasUserEntered': true},
          )
        ],
        deleted: [HkDeletedObject(uuid: 'D1', syncIdentifier: 'app:x', syncVersion: 2)],
        nextAnchor: 'QQ==',
      );
      return codec.encodeMessage(<Object?>[result]);
    });
    final n = AnchoredHealthNative(isSupportedPlatform: true);
    final r = await n.anchoredQuery(type: 'bodyMass', anchor: 'AA==', limit: 10, from: DateTime.utc(2026, 1, 1));
    expect(seen!.type, 'bodyMass');
    expect(seen!.anchor, 'AA==');
    expect(seen!.limit, 10);
    expect(seen!.fromMs, DateTime.utc(2026, 1, 1).millisecondsSinceEpoch);
    expect(r.samples.single.value, 70.5);
    expect(r.samples.single.metadata['HKWasUserEntered'], true);
    expect(r.deleted.single.syncVersion, 2);
    expect(r.nextAnchor, 'QQ==');
    messenger.setMockMessageHandler(channel, null);
  });

  test('Pigeon channel: dailyTotals sends inclusive local days and returns days without gaps filled', () async {
    const channel = 'dev.flutter.pigeon.anchored_health_native.AnchoredHealthApi.dailyTotals';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = AnchoredHealthApi.pigeonChannelCodec;
    HkDailyTotalsRequest? seen;
    messenger.setMockMessageHandler(channel, (ByteData? message) async {
      seen = (codec.decodeMessage(message) as List<Object?>).first as HkDailyTotalsRequest;
      return codec.encodeMessage(<Object?>[
        HkDailyTotalsResult(
          timeZoneId: 'Europe/Berlin',
          days: [
            HkDailyTotal(day: '2026-03-28', value: 8000, startMs: 1, endMs: 2),
            // 2026-03-29 has no data: not returned (no data is not 0)
            HkDailyTotal(day: '2026-03-30', value: 9000, startMs: 3, endMs: 4),
          ],
        )
      ]);
    });
    final n = AnchoredHealthNative(isSupportedPlatform: true);
    final r = await n.dailyTotals(type: 'stepCount', fromDay: '2026-03-28', toDay: '2026-03-30');
    expect((seen!.type, seen!.fromDay, seen!.toDay), ('stepCount', '2026-03-28', '2026-03-30'));
    expect(r.timeZoneId, 'Europe/Berlin');
    expect(r.days.map((d) => d.day), ['2026-03-28', '2026-03-30']);
    messenger.setMockMessageHandler(channel, null);
  });

  test('Pigeon channel: sampleRefs encodes the window and returns references and deleted UUIDs', () async {
    const channel = 'dev.flutter.pigeon.anchored_health_native.AnchoredHealthApi.sampleRefs';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = AnchoredHealthApi.pigeonChannelCodec;
    HkSampleRefsRequest? seen;
    messenger.setMockMessageHandler(channel, (ByteData? message) async {
      seen = (codec.decodeMessage(message) as List<Object?>).first as HkSampleRefsRequest;
      return codec.encodeMessage(<Object?>[
        HkSampleRefsResult(
          refs: [HkSampleRef(uuid: 'U1', startMs: 10, endMs: 20)],
          deletedUuids: ['D1'],
          nextAnchor: 'QQ==',
        )
      ]);
    });
    final n = AnchoredHealthNative(isSupportedPlatform: true);
    final r = await n.sampleRefs(type: 'stepCount', anchor: 'AA==', limit: 50, from: DateTime.utc(2026, 9, 1));
    expect(seen!.type, 'stepCount');
    expect(seen!.anchor, 'AA==');
    expect(seen!.limit, 50);
    expect(seen!.fromMs, DateTime.utc(2026, 9, 1).millisecondsSinceEpoch);
    expect(seen!.toMs, isNull);
    expect(r.refs.single.uuid, 'U1');
    expect(r.deletedUuids, ['D1']);
    expect(r.nextAnchor, 'QQ==');
    messenger.setMockMessageHandler(channel, null);
  });
}
