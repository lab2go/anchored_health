import '../models.dart';
import '../types.dart';

/// Interface between the engine and a platform.
///
/// iOS: [NativeHealthBridge] via `anchored_health_native` (anchor per type).
/// Android: an implementation on top of the package `health` (changes token).
/// Tests: a fake bridge.
abstract class HealthBridge {
  HealthPlatform get platform;

  /// iOS `true`: an anchored query with a `nil` anchor returns history **and**
  /// an anchor in one run. Android `false`: first [baselineToken], then
  /// [read] as backfill, then [changes].
  bool get firstRunIncludesHistory;

  Future<bool> isAvailable();

  /// One dialog for the union of all types. `true` only means "dialog ran".
  Future<bool> requestAuthorization({
    required Set<String> read,
    required Set<String> write,
    bool characteristics = false,
  });

  Future<AuthorizationRequestStatus> authorizationRequestStatus({
    required Set<String> read,
    required Set<String> write,
    bool characteristics = false,
  });

  Future<WritePermission> writePermission(String platformType);

  /// Delta per type since [token] (iOS anchor / Android changes token).
  /// [from]/[to] only limit the iOS first run (sample start time).
  Future<ChangesPage> changes(
    String platformType, {
    String? token,
    DateTime? from,
    DateTime? to,
    int limit = 1000,
  });

  /// Android: baseline token before the backfill (iOS: null).
  Future<String?> baselineToken(String platformType);

  /// Window read without advancing the anchor (backfill, re-read window,
  /// loading older values). Returns all values in the window [from, to).
  Future<List<HealthSample>> read(
    String platformType, {
    required DateTime from,
    required DateTime to,
  });

  /// Writes all requests; returns platform ids in input order (null where the
  /// platform returns none, e.g. Android blood pressure).
  Future<List<String?>> write(List<HealthWriteRequest> requests);

  /// Deletes own records; returns the count.
  Future<int> delete(String platformType, List<String> ids);

  Future<HealthCharacteristics?> characteristics();
}

/// Operation not supported by a bridge.
class HealthOperationUnsupported implements Exception {
  HealthOperationUnsupported(this.message);
  final String message;
  @override
  String toString() => 'HealthOperationUnsupported: $message';
}
