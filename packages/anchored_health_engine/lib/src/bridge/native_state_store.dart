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
/// side cannot set the mark.
Future<KeyValueStore> openBackupExcludedStateStore({
  AnchoredHealthNative? native,
  String directoryName = defaultStateDirectoryName,
}) async {
  final path = await (native ?? AnchoredHealthNative()).prepareStateDirectory(directoryName);
  return FileKeyValueStore(Directory(path));
}
