/// Local calendar days (pure Dart, no time zone database).
library;

/// A calendar day as the device shows it (no time of day, no zone). The label
/// `YYYY-MM-DD` is exactly what the server expects as `day`.
class LocalDay implements Comparable<LocalDay> {
  const LocalDay(this.year, this.month, this.day);

  /// Day of the fields of [t] (the caller decides which zone [t] is in).
  factory LocalDay.fromDateTime(DateTime t) => LocalDay(t.year, t.month, t.day);

  /// Strict `YYYY-MM-DD`; `null` for anything else (also impossible dates).
  static LocalDay? tryParse(String s) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    if (m == null) return null;
    final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
    final probe = DateTime.utc(y, mo, d);
    if (probe.year != y || probe.month != mo || probe.day != d) return null;
    return LocalDay(y, mo, d);
  }

  factory LocalDay.parse(String s) =>
      tryParse(s) ?? (throw FormatException('Not a day (YYYY-MM-DD): $s'));

  final int year;
  final int month;
  final int day;

  DateTime get _utc => DateTime.utc(year, month, day);

  /// `YYYY-MM-DD`.
  String get iso => '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  /// `YYYY-MM` (shard key).
  String get monthKey => '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';

  LocalDay addDays(int n) => LocalDay.fromDateTime(DateTime.utc(year, month, day + n));

  /// Number of calendar days from this day to [other] (negative if earlier).
  int daysUntil(LocalDay other) => other._utc.difference(_utc).inDays;

  bool isBefore(LocalDay other) => compareTo(other) < 0;
  bool isAfter(LocalDay other) => compareTo(other) > 0;

  @override
  int compareTo(LocalDay other) => year != other.year
      ? year.compareTo(other.year)
      : (month != other.month ? month.compareTo(other.month) : day.compareTo(other.day));

  @override
  bool operator ==(Object other) =>
      other is LocalDay && other.year == year && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => iso;
}

/// Local days in a range, both ends inclusive.
Iterable<LocalDay> daysInRange(LocalDay from, LocalDay to) sync* {
  for (var d = from; !d.isAfter(to); d = d.addDays(1)) {
    yield d;
  }
}

/// Maps instants to local days and back. The default uses the device zone
/// (Dart's local time), which is also the zone in which HealthKit cuts days.
/// Tests inject a fixed rule.
abstract class DayCalendar {
  const DayCalendar();

  /// Local day that contains [instant].
  LocalDay dayOf(DateTime instant);

  /// First instant of [day] (local midnight; if midnight does not exist, the
  /// first valid instant of the day).
  DateTime startOf(LocalDay day);
}

/// Device zone.
class DeviceDayCalendar extends DayCalendar {
  const DeviceDayCalendar();

  @override
  LocalDay dayOf(DateTime instant) => LocalDay.fromDateTime(instant.toLocal());

  @override
  DateTime startOf(LocalDay day) => DateTime(day.year, day.month, day.day);
}
