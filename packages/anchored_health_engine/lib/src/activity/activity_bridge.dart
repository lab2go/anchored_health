import '../bridge/health_bridge.dart';
import '../types.dart';
import 'local_day.dart';

/// The sum of one cumulative type on one local day. Days without data do not
/// exist: no data is not 0.
class DailyTotal {
  const DailyTotal({required this.day, required this.value});
  final LocalDay day;

  /// Sum in the canonical unit of the type (count, m, kcal, min).
  final double value;

  @override
  String toString() => 'DailyTotal($day $value)';
}

class DailyTotalsPage {
  const DailyTotalsPage({required this.days, this.timeZoneId});
  final List<DailyTotal> days;

  /// IANA identifier of the zone the days were cut in (device zone).
  final String? timeZoneId;
}

/// Reference to a sample: enough to find the days it touches.
class ActivitySampleRef {
  const ActivitySampleRef({required this.uuid, required this.start, required this.end});
  final String uuid;
  final DateTime start;
  final DateTime end;
}

class ActivityRefsPage {
  const ActivityRefsPage({
    this.refs = const [],
    this.deletedUuids = const [],
    this.nextAnchor,
    this.hasMore = false,
  });
  final List<ActivitySampleRef> refs;
  final List<String> deletedUuids;
  final String? nextAnchor;
  final bool hasMore;
}

/// Platform side of the daily totals. iOS: `NativeHealthBridge`. Android:
/// [UnsupportedActivityDailyBridge] until the Health Connect package (P9).
abstract class ActivityDailyBridge {
  HealthPlatform get platform;

  /// Sum per local day for [from] to [to], both inclusive. Overlapping sources
  /// (phone and watch) are already merged by the platform; the engine must not
  /// add per-source values up.
  Future<DailyTotalsPage> dailyTotals(String platformType, {required LocalDay from, required LocalDay to});

  /// Sample references and deleted UUIDs since [anchor] (null = from the
  /// start). [from] limits added samples by start time (deletions are never
  /// limited).
  Future<ActivityRefsPage> sampleRefs(
    String platformType, {
    String? anchor,
    DateTime? from,
    int limit = 5000,
  });
}

/// Placeholder for platforms without an implementation (Health Connect, P9).
class UnsupportedActivityDailyBridge implements ActivityDailyBridge {
  const UnsupportedActivityDailyBridge(this.platform);

  @override
  final HealthPlatform platform;

  @override
  Future<DailyTotalsPage> dailyTotals(String platformType, {required LocalDay from, required LocalDay to}) =>
      throw HealthOperationUnsupported('daily totals are not implemented for ${platform.id} (planned: Health Connect, P9)');

  @override
  Future<ActivityRefsPage> sampleRefs(String platformType, {String? anchor, DateTime? from, int limit = 5000}) =>
      throw HealthOperationUnsupported('daily totals are not implemented for ${platform.id} (planned: Health Connect, P9)');
}
