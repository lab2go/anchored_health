import 'dart:io';

import 'package:anchored_health_engine/file_store.dart';
import 'package:anchored_health_engine/native_bridge.dart' show openBackupExcludedStateStore;
import 'package:anchored_health_engine/anchored_health_engine.dart' show KeyValueStore;
import 'package:anchored_health_native/anchored_health_native.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends AnchoredHealthApi {
  _FakeApi(this.path);
  final String path;
  final List<String> names = [];
  Object? error;
  @override
  Future<String> prepareStateDirectory(String name) async {
    names.add(name);
    if (error != null) throw error!;
    return path;
  }
}

void main() {
  late Directory dir;
  late FileKeyValueStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ah_file_store_');
    store = FileKeyValueStore(Directory('${dir.path}/s'));
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  const k = 'user-a/profile-a/apple_health/activity/idx/stepCount/2026-10';

  test('set, get, overwrite, remove, keys; the directory is created on the first write', () async {
    expect(await store.get(k), isNull);
    expect(await store.keys(), isEmpty);
    expect(Directory('${dir.path}/s').existsSync(), isFalse);
    await store.set(k, '{"u":"2026-10-18"}');
    expect(await store.get(k), '{"u":"2026-10-18"}');
    await store.set(k, 'neu');
    expect(await store.get(k), 'neu');
    await store.set('b/c', 'x');
    expect((await store.keys()).toSet(), {k, 'b/c'});
    await store.remove(k);
    await store.remove(k); // already gone: no error
    expect(await store.get(k), isNull);
    expect((await store.keys()).toSet(), {'b/c'});
  });

  test('unicode and special characters round-trip; empty value is a value', () async {
    await store.set('a b/ü:ß?#%', 'wert ä ö €');
    await store.set('leer', '');
    expect(await store.get('a b/ü:ß?#%'), 'wert ä ö €');
    expect(await store.get('leer'), '');
    expect((await store.keys()).toSet(), {'a b/ü:ß?#%', 'leer'});
  });

  test('writes are atomic: no temp file is left behind, foreign files are ignored', () async {
    await store.set(k, 'v');
    File('${dir.path}/s/fremd.txt').writeAsStringSync('x');
    File('${dir.path}/s/halb.v.tmp').writeAsStringSync('x');
    final names = Directory('${dir.path}/s').listSync().map((e) => e.uri.pathSegments.last).toSet();
    expect(names, containsAll(<String>[FileKeyValueStore.fileNameOf(k), 'fremd.txt']));
    expect((await store.keys()).toList(), [k]);
  });

  test('a very long key gets a hash file name and still lists and reads', () async {
    final long = 'u/p/ios/activity/idx/${'x' * 400}/2026-10';
    expect(FileKeyValueStore.fileNameOf(long).length, lessThan(100));
    await store.set(long, 'v1');
    await store.set('$long-2', 'v2');
    expect(await store.get(long), 'v1');
    expect(await store.get('$long-2'), 'v2');
    expect((await store.keys()).toSet(), {long, '$long-2'});
    await store.remove(long);
    expect((await store.keys()).toList(), ['$long-2']);
  });

  test('clear() empties the store and keeps the directory', () async {
    await store.set(k, 'v');
    await store.set('a', 'b');
    await store.clear();
    expect(await store.keys(), isEmpty);
    expect(Directory('${dir.path}/s').existsSync(), isTrue);
  });

  test('openBackupExcludedStateStore: asks the native side for the directory and uses it', () async {
    final api = _FakeApi('${dir.path}/native');
    final KeyValueStore s = await openBackupExcludedStateStore(
        native: AnchoredHealthNative(api: api, isSupportedPlatform: true));
    expect(api.names, ['anchored_health_state']);
    await s.set('a/b', 'c');
    expect(File('${dir.path}/native/${FileKeyValueStore.fileNameOf('a/b')}').existsSync(), isTrue);
    await openBackupExcludedStateStore(
        native: AnchoredHealthNative(api: api, isSupportedPlatform: true), directoryName: 'andere');
    expect(api.names.last, 'andere');
  });

  test('openBackupExcludedStateStore: no store if the exclusion fails or the platform is not iOS', () async {
    final api = _FakeApi('${dir.path}/native')..error = StateError('backup_exclusion_failed');
    await expectLater(
        openBackupExcludedStateStore(native: AnchoredHealthNative(api: api, isSupportedPlatform: true)),
        throwsStateError);
    await expectLater(
        openBackupExcludedStateStore(native: AnchoredHealthNative(api: api, isSupportedPlatform: false)),
        throwsA(isA<HealthPlatformUnsupported>()));
  });
}
