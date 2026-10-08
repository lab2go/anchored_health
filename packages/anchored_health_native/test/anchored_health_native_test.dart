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
}
