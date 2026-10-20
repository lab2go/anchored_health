import 'dart:io';

import 'package:anchored_health_engine/file_store.dart';
import 'package:anchored_health_engine/native_bridge.dart' show openBackupExcludedStateStore;
import 'package:anchored_health_engine/anchored_health_engine.dart' show KeyValueStore, StateDamagedException;
import 'package:anchored_health_native/anchored_health_native.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends AnchoredHealthApi {
  _FakeApi(this.path);
  final String path;
  final List<String> names = [];
  Object? error;

  /// Like the native side: creates the directory (the real one also marks it).
  bool create = true;
  @override
  Future<String> prepareStateDirectory(String name) async {
    names.add(name);
    if (error != null) throw error!;
    if (create) Directory(path).createSync(recursive: true);
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

  test('temp files are unique: parallel writes of one key all succeed and leave nothing behind (review P3 D5)', () async {
    await Future.wait([for (var i = 0; i < 30; i++) store.set(k, 'wert-$i')]);
    final value = await store.get(k);
    expect(value, startsWith('wert-'));
    final names = Directory('${dir.path}/s').listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(names, [FileKeyValueStore.fileNameOf(k)]);
    // an old, half written temp file of a crashed write is neither a key nor in the way
    File('${dir.path}/s/${FileKeyValueStore.fileNameOf(k)}.abc.tmp').writeAsStringSync('half');
    await store.set(k, 'neu');
    expect((await store.keys()).toList(), [k]);
    await store.clear();
    expect(Directory('${dir.path}/s').listSync(), isEmpty);
  });

  test('a failed write removes its temp file and keeps the old value', () async {
    await store.set(k, 'alt');
    // a directory where the target file should be: the rename fails
    final target = File('${dir.path}/s/${FileKeyValueStore.fileNameOf('b/c')}');
    Directory(target.path).createSync();
    await expectLater(store.set('b/c', 'x'), throwsA(isA<FileSystemException>()));
    expect(Directory('${dir.path}/s').listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    expect(await store.get(k), 'alt');
  });

  test('a missing directory comes back only through recreateDirectory (the marked one), never as a plain directory', () async {
    var calls = 0;
    var create = false;
    final marked = FileKeyValueStore(Directory('${dir.path}/m'), recreateDirectory: () async {
      calls++;
      if (create) Directory('${dir.path}/m').createSync(recursive: true);
    });
    await expectLater(marked.set(k, 'v'), throwsA(isA<FileSystemException>()));
    expect(calls, 1);
    expect(Directory('${dir.path}/m').existsSync(), isFalse, reason: 'not created without the mark');
    create = true;
    await marked.set(k, 'v');
    expect(calls, 2);
    expect(await marked.get(k), 'v');
    await marked.set('a', 'b');
    expect(calls, 2, reason: 'the directory is there: no further call');
    expect(await FileKeyValueStore(Directory('${dir.path}/none')).keys(), isEmpty);
  });

  test('openBackupExcludedStateStore: a vanished directory is prepared (marked) again by the native call', () async {
    final api = _FakeApi('${dir.path}/native');
    final s = await openBackupExcludedStateStore(native: AnchoredHealthNative(api: api, isSupportedPlatform: true));
    await s.set('a/b', '1');
    expect(api.names.length, 1);
    Directory('${dir.path}/native').deleteSync(recursive: true);
    await s.set('a/b', '2');
    expect(api.names.length, 2, reason: 'the native side recreated and marked it');
    expect(await s.get('a/b'), '2');
    // if the native side cannot do it, nothing is written
    Directory('${dir.path}/native').deleteSync(recursive: true);
    api.error = StateError('backup_exclusion_failed');
    await expectLater(s.set('a/b', '3'), throwsStateError);
    expect(Directory('${dir.path}/native').existsSync(), isFalse);
  });

  test('a damaged file throws StateDamagedException from get and can be removed by key', () async {
    await store.set(k, 'v');
    final f = File('${dir.path}/s/${FileKeyValueStore.fileNameOf(k)}');
    f.writeAsBytesSync([0xff, 0xfe, 0x80]);
    await expectLater(store.get(k), throwsA(isA<StateDamagedException>()));
    expect(await store.keys(), contains(k), reason: 'the name still tells the key');
    await store.remove(k);
    expect(await store.get(k), isNull);
    // a damaged long-name file cannot tell its key, it is skipped when listing but removable by key
    final long = 'u/p/ios/activity/idx/${'x' * 400}/2026-10';
    await store.set(long, 'v');
    File('${dir.path}/s/${FileKeyValueStore.fileNameOf(long)}').writeAsBytesSync([0xff, 0xfe, 0x80]);
    expect(await store.keys(), isEmpty);
    await expectLater(store.get(long), throwsA(isA<StateDamagedException>()));
    await store.remove(long);
    expect(Directory('${dir.path}/s').listSync(), isEmpty);
  });
}
