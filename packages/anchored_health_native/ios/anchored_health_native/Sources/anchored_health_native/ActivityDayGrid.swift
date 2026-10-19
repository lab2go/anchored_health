import Foundation

/// One local calendar day: label `YYYY-MM-DD` plus its real boundaries.
struct ActivityDay: Equatable {
  /// Gregorian calendar day in the time zone of the grid.
  let label: String
  let start: Date
  /// Start of the next day (23 or 25 hours after `start` on DST changes).
  let end: Date

  var hours: Double { end.timeIntervalSince(start) / 3600 }
}

enum ActivityDayGridError: Error, Equatable {
  case invalidDay(String)
  case emptyRange
  case rangeTooLong(Int)
}

/// Local day boundaries in one time zone. Foundation only (no HealthKit), so
/// the logic can be tested without a store: day labels, 23/25-hour days,
/// midnights that do not exist (DST gap at 00:00), range enumeration and the
/// check that an interval returned by HealthKit is exactly one calendar day.
struct ActivityDayGrid {
  /// 5 years (1825 days) plus the leap days in between.
  static let maxDays = 1830

  let calendar: Calendar

  init(timeZone: TimeZone) {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = timeZone
    c.locale = Locale(identifier: "en_US_POSIX")
    calendar = c
  }

  var timeZoneId: String { calendar.timeZone.identifier }

  /// Strict `YYYY-MM-DD`; nil for anything else (also impossible dates).
  static func parseLabel(_ s: String) -> DateComponents? {
    let u = Array(s.utf8)
    guard u.count == 10, u[4] == 0x2D, u[7] == 0x2D else { return nil }
    func num(_ r: Range<Int>) -> Int? {
      var v = 0
      for i in r {
        guard u[i] >= 0x30, u[i] <= 0x39 else { return nil }
        v = v * 10 + Int(u[i] - 0x30)
      }
      return v
    }
    guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10) else { return nil }
    return DateComponents(year: y, month: m, day: d)
  }

  /// Local calendar day of an instant.
  func label(of date: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  /// First instant of the labelled day; nil for an invalid label.
  func startOfDay(_ label: String) -> Date? {
    guard var comps = Self.parseLabel(label) else { return nil }
    // Noon exists on every day (DST changes happen at night in practice and
    // `startOfDay(for:)` handles a missing midnight itself).
    comps.hour = 12
    guard let noon = calendar.date(from: comps) else { return nil }
    let back = calendar.dateComponents([.year, .month, .day], from: noon)
    guard back.year == comps.year, back.month == comps.month, back.day == comps.day else {
      return nil  // e.g. 2026-02-30 rolled over
    }
    return calendar.startOfDay(for: noon)
  }

  func day(_ label: String) -> ActivityDay? {
    guard let start = startOfDay(label), let next = calendar.date(byAdding: .day, value: 1, to: start)
    else { return nil }
    return ActivityDay(label: self.label(of: start), start: start, end: calendar.startOfDay(for: next))
  }

  /// All days from `fromDay` to `toDay`, both inclusive.
  func days(fromDay: String, toDay: String) throws -> [ActivityDay] {
    guard let first = day(fromDay) else { throw ActivityDayGridError.invalidDay(fromDay) }
    guard day(toDay) != nil else { throw ActivityDayGridError.invalidDay(toDay) }
    var out: [ActivityDay] = []
    var current = first
    while true {
      out.append(current)
      if current.label == toDay { break }
      if current.label > toDay { throw ActivityDayGridError.emptyRange }
      if out.count > Self.maxDays { throw ActivityDayGridError.rangeTooLong(Self.maxDays) }
      guard let next = day(label(of: current.end)) else { throw ActivityDayGridError.invalidDay(label(of: current.end)) }
      current = next
    }
    return out
  }

  private func isMidnight(_ date: Date) -> Bool {
    let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
    return c.hour == 0 && c.minute == 0 && c.second == 0 && (c.nanosecond ?? 0) == 0
  }

  /// Anchor for `HKStatisticsCollectionQuery` with a one-day interval. It must
  /// be a real 00:00 so that all intervals are calendar days. If the first
  /// day has no 00:00 (DST gap at midnight, e.g. Cairo, Havanna, Beirut) the
  /// previous day is used.
  func anchorDate(for days: [ActivityDay]) -> Date? {
    guard let first = days.first else { return nil }
    if isMidnight(first.start) { return first.start }
    guard let prev = calendar.date(byAdding: .day, value: -1, to: first.start) else { return nil }
    return calendar.startOfDay(for: prev)
  }

  /// The calendar day for an interval returned by HealthKit, or nil if the
  /// interval is not exactly one calendar day of this grid (the totals of such
  /// an interval would be wrong; the caller reports an error instead).
  func alignedDay(start: Date, end: Date) -> ActivityDay? {
    guard let d = day(label(of: start)) else { return nil }
    let tolerance: TimeInterval = 1
    return abs(d.start.timeIntervalSince(start)) < tolerance && abs(d.end.timeIntervalSince(end)) < tolerance
      ? d : nil
  }
}
