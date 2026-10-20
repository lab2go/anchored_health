import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'sync_state_store.dart';

/// [KeyValueStore] in a directory: one file per key, written atomically (temp
/// file, then rename). For local state that must not be part of a backup
/// (SharedPreferences cannot be excluded): give it a directory that is marked
/// excluded, e.g. from `openBackupExcludedStateStore` (iOS
/// `NSURLIsExcludedFromBackupKey`, set on the directory, so it covers every
/// file in it).
///
/// Keys (`<uid>/<pid>/<platform>/activity/idx/<type>/<month>`) become file
/// names by percent-encoding; a key whose name would be too long for the file
/// system gets a hash name and keeps the key in the first line of the file.
///
/// **Missing directory** (the system or the user removed it): with
/// [recreateDirectory] the store asks the app for it instead of creating a plain,
/// unmarked directory itself. `openBackupExcludedStateStore` passes the native
/// `prepareStateDirectory`, which creates it again **with** the exclusion mark.
/// Without the callback a missing directory is created as it is (the caller
/// has to care about the mark, or does not need one).
///
/// A file that cannot be read (damaged) makes [get] throw
/// [StateDamagedException]; [remove] deletes it by key.
class FileKeyValueStore implements KeyValueStore {
  FileKeyValueStore(this.directory, {this.recreateDirectory});

  final Directory directory;

  /// Creates the directory again (marked, see above); must leave it in place.
  final Future<void> Function()? recreateDirectory;

  static final Random _random = Random();
  static int _tmpCounter = 0;

  static const _suffix = '.v';
  static const _tmpSuffix = '.tmp';
  static const _hashed = 'h-';
  static const _maxNameBytes = 180;

  /// File name of [key].
  static String fileNameOf(String key) {
    final enc = Uri.encodeComponent(key);
    if (utf8.encode(enc).length <= _maxNameBytes) return '$enc$_suffix';
    return '$_hashed${sha256.convert(utf8.encode(key))}$_suffix';
  }

  static bool _isHashedName(String name) => name.startsWith(_hashed) && name.length == _hashed.length + 64 + _suffix.length;

  File _file(String key) => File('${directory.path}${Platform.pathSeparator}${fileNameOf(key)}');

  Future<void> _ensureDir() async {
    if (await directory.exists()) return;
    final again = recreateDirectory;
    if (again == null) {
      await directory.create(recursive: true);
      return;
    }
    await again();
    if (!await directory.exists()) {
      throw FileSystemException('state directory could not be created again', directory.path);
    }
  }

  /// Unique per write (two writers or a leftover of a crash never share a temp file).
  File _tmpFile(File target) {
    final id = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${(_tmpCounter++).toRadixString(36)}${_random.nextInt(1 << 32).toRadixString(36)}';
    return File('${target.path}.$id$_tmpSuffix');
  }

  @override
  Future<String?> get(String key) async {
    final f = _file(key);
    final String text;
    try {
      text = utf8.decode(await f.readAsBytes());
    } on PathNotFoundException {
      return null;
    } on FormatException {
      throw StateDamagedException(key); // not valid UTF-8
    }
    return _decode(key, text);
  }

  /// A hashed name keeps `key\n` in front of the value (for [keys] and as a check).
  static String _encode(String key, String value) =>
      _isHashedName(fileNameOf(key)) ? '$key\n$value' : value;

  static String? _decode(String key, String text) {
    if (!_isHashedName(fileNameOf(key))) return text;
    final nl = text.indexOf('\n');
    if (nl < 0 || text.substring(0, nl) != key) return null;
    return text.substring(nl + 1);
  }

  @override
  Future<void> set(String key, String value) async {
    await _ensureDir();
    final f = _file(key);
    final tmp = _tmpFile(f);
    try {
      await tmp.writeAsString(_encode(key, value), flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // the original error is the one that matters
      }
      rethrow;
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      await _file(key).delete();
    } on PathNotFoundException {
      // already gone
    }
  }

  @override
  Future<Iterable<String>> keys() async {
    if (!await directory.exists()) return const [];
    final out = <String>[];
    await for (final e in directory.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.endsWith(_suffix)) continue; // temp files and foreign files
      if (_isHashedName(name)) {
        try {
          final text = utf8.decode(await e.readAsBytes());
          final nl = text.indexOf('\n');
          if (nl > 0) out.add(text.substring(0, nl));
        } on FileSystemException {
          // vanished while listing
        } on FormatException {
          // damaged: its key is unknown; get/remove by key still work
        }
      } else {
        try {
          out.add(Uri.decodeComponent(name.substring(0, name.length - _suffix.length)));
        } on FormatException {
          // not ours
        }
      }
    }
    return out;
  }

  static bool _isTempName(String path) => path.endsWith(_tmpSuffix) && path.contains('$_suffix.');

  /// Removes every file of the store (and leftover temp files). The directory stays.
  Future<void> clear() async {
    if (!await directory.exists()) return;
    await for (final e in directory.list(followLinks: false)) {
      if (e is File && (e.path.endsWith(_suffix) || _isTempName(e.path))) {
        await e.delete();
      }
    }
  }
}
