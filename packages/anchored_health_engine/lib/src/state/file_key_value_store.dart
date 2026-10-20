import 'dart:convert';
import 'dart:io';

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
class FileKeyValueStore implements KeyValueStore {
  FileKeyValueStore(this.directory);

  final Directory directory;

  static const _suffix = '.v';
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
    if (!await directory.exists()) await directory.create(recursive: true);
  }

  @override
  Future<String?> get(String key) async {
    final f = _file(key);
    final String text;
    try {
      text = await f.readAsString();
    } on PathNotFoundException {
      return null;
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
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(_encode(key, value), flush: true);
    await tmp.rename(f.path);
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
          final text = await e.readAsString();
          final nl = text.indexOf('\n');
          if (nl > 0) out.add(text.substring(0, nl));
        } on FileSystemException {
          // vanished while listing
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

  /// Removes every file of the store (and leftover temp files). The directory stays.
  Future<void> clear() async {
    if (!await directory.exists()) return;
    await for (final e in directory.list(followLinks: false)) {
      if (e is File && (e.path.endsWith(_suffix) || e.path.endsWith('$_suffix.tmp'))) {
        await e.delete();
      }
    }
  }
}
