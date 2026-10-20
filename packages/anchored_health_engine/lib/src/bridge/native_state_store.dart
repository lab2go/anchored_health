import 'dart:io';

import 'package:anchored_health_native/anchored_health_native.dart';

import '../state/file_key_value_store.dart';
import '../state/sync_state_store.dart';

export '../state/file_key_value_store.dart';

/// Default directory name (inside Application Support).
const defaultStateDirectoryName = 'anchored_health_state';

/// Opens the store for the local state of the daily totals: a directory in
/// Application Support that iOS leaves out of device and iCloud backups
/// (`NSURLIsExcludedFromBackupKey`). Pass it as `SyncStateStore.activityKv`.
/// Throws (never returns a store that could end up in a backup) if the native
/// side cannot set the mark. If the directory is gone later, the store creates it
/// again only through the same native call (with the mark), never on its own.
Future<KeyValueStore> openBackupExcludedStateStore({
  AnchoredHealthNative? native,
  String directoryName = defaultStateDirectoryName,
}) async {
  final api = native ?? AnchoredHealthNative();
  final path = await api.prepareStateDirectory(directoryName);
  return FileKeyValueStore(Directory(path), recreateDirectory: () async {
    // The directory vanished: it only comes back through the native call that marks it.
    final again = await api.prepareStateDirectory(directoryName);
    if (again != path) throw StateError('state directory moved: $path -> $again');
  });
}
