/// File based [KeyValueStore] (`dart:io`) for state that must stay out of
/// backups. Separate from the core library so that the core stays free of
/// `dart:io`. Also exported by `native_bridge.dart`.
library;

export 'src/state/file_key_value_store.dart';
