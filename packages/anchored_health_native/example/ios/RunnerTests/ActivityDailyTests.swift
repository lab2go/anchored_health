import HealthKit
import XCTest

#if canImport(anchored_health_native)
  @testable import anchored_health_native
#endif

/// Daily totals of the cumulative activity types: types and units, statistics
/// options (overlapping sources), and the local day grid (23/25-hour days,
/// missing midnight, late samples). No HealthKit permission and no store
/// needed; all values are synthetic.
final class ActivityDailyTests: XCTestCase {

  private func grid(_ id: String) -> ActivityDayGrid {
    ActivityDayGrid(timeZone: TimeZone(identifier: id)!)
  }

  private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
  }

  // MARK: Types, units, options

  func testActivityTypesAreReadOnlyCumulativeWithCanonicalUnits() throws {
    let expected: [(String, String)] = [
      ("stepCount", "count"), ("distanceWalkingRunning", "m"), ("activeEnergyBurned", "kcal"),
      ("flightsClimbed", "count"), ("appleExerciseTime", "min"),
    ]
    for (raw, unit) in expected {
      let t = try HealthDataType.parse(raw)
      XCTAssertTrue(t.isCumulativeActivity, raw)
      XCTAssertFalse(t.isWritable, raw)
      XCTAssertEqual(t.unitString, unit, raw)
      // The label sent to the server equals the HealthKit unit string of the fixed unit.
      XCTAssertEqual(t.unit.unitString, unit, raw)
      XCTAssertTrue(t.sampleType is HKQuantityType, raw)
    }
    XCTAssertEqual(HealthDataType.stepCount.quantityIdentifier, .stepCount)
    XCTAssertEqual(HealthDataType.distanceWalkingRunning.quantityIdentifier, .distanceWalkingRunning)
    XCTAssertEqual(HealthDataType.activeEnergyBurned.quantityIdentifier, .activeEnergyBurned)
    XCTAssertEqual(HealthDataType.flightsClimbed.quantityIdentifier, .flightsClimbed)
    XCTAssertEqual(HealthDataType.appleExerciseTime.quantityIdentifier, .appleExerciseTime)
    // Other types are not daily totals.
    for t in HealthDataType.allCases where !expected.map({ $0.0 }).contains(t.rawValue) {
      XCTAssertFalse(t.isCumulativeActivity, t.rawValue)
      XCTAssertNil(t.dailyStatisticsOptions, t.rawValue)
    }
  }

  /// iPhone and Apple Watch both record steps. HealthKit removes the overlap
  /// inside the cumulative sum when the statistics are NOT split by source.
  /// Pinned here: only `.cumulativeSum`, never `.separateBySource`.
  func testStatisticsAreMergedOverSourcesNotSeparated() {
    for t in HealthDataType.allCases where t.isCumulativeActivity {
      let o = t.dailyStatisticsOptions
      XCTAssertEqual(o, [.cumulativeSum], t.rawValue)
      XCTAssertFalse(o?.contains(.separateBySource) ?? true, t.rawValue)
    }
  }

  func testAuthorizationReadOnlyForActivityTypes() throws {
    let sets = try HealthDataType.authorizationSets(
      read: ["stepCount", "distanceWalkingRunning", "activeEnergyBurned", "flightsClimbed", "appleExerciseTime"],
      write: [], characteristics: false, includeBloodPressureCorrelation: false)
    XCTAssertTrue(sets.share.isEmpty)
    XCTAssertEqual(sets.read.count, 5)
    XCTAssertThrowsError(
      try HealthDataType.authorizationSets(
        read: [], write: ["stepCount"], characteristics: false, includeBloodPressureCorrelation: false))
  }

  // MARK: Day labels

  func testParseLabelIsStrict() {
    XCTAssertEqual(ActivityDayGrid.parseLabel("2026-10-19")?.day, 19)
    for bad in ["2026-1-19", "26-10-19", "2026/10/19", "2026-10-19T00:00", " 2026-10-19", "2026-10-1a", ""] {
      XCTAssertNil(ActivityDayGrid.parseLabel(bad), bad)
    }
    let g = grid("Europe/Berlin")
    XCTAssertNil(g.startOfDay("2026-02-30"))
    XCTAssertNil(g.startOfDay("2026-13-01"))
    XCTAssertNotNil(g.startOfDay("2028-02-29"))
    XCTAssertNil(g.startOfDay("2027-02-29"))
  }

  func testLabelFollowsTheLocalZoneNotUtc() {
    // 2026-10-19 22:30 UTC is already the 20th in Berlin (UTC+2).
    XCTAssertEqual(grid("Europe/Berlin").label(of: utc(2026, 10, 19, 22, 30)), "2026-10-20")
    XCTAssertEqual(grid("UTC").label(of: utc(2026, 10, 19, 22, 30)), "2026-10-19")
    XCTAssertEqual(grid("Asia/Tokyo").label(of: utc(2026, 10, 19, 15, 0)), "2026-10-20")
    XCTAssertEqual(grid("America/New_York").label(of: utc(2026, 10, 19, 3, 59)), "2026-10-18")
    // Midnight is the first instant of the new day, one second before is the old day.
    let b = grid("Europe/Berlin")
    XCTAssertEqual(b.label(of: utc(2026, 10, 19, 21, 59, 59)), "2026-10-19")
    XCTAssertEqual(b.label(of: utc(2026, 10, 19, 22, 0, 0)), "2026-10-20")
  }

  // MARK: 23 / 25 hour days

  func testBerlinDstDaysHave23And25Hours() throws {
    let g = grid("Europe/Berlin")
    XCTAssertEqual(g.day("2026-03-28")?.hours, 24)
    XCTAssertEqual(g.day("2026-03-29")?.hours, 23)
    XCTAssertEqual(g.day("2026-03-30")?.hours, 24)
    XCTAssertEqual(g.day("2025-10-26")?.hours, 25)
    XCTAssertEqual(g.day("2026-10-25")?.hours, 25)
    // The 23-hour day starts at 2026-03-28T23:00Z and ends 2026-03-29T22:00Z.
    let d = try XCTUnwrap(g.day("2026-03-29"))
    XCTAssertEqual(d.start, utc(2026, 3, 28, 23))
    XCTAssertEqual(d.end, utc(2026, 3, 29, 22))
  }

  func testRangeAcrossDstChangeIsGaplessAndLabelled() throws {
    let g = grid("Europe/Berlin")
    let days = try g.days(fromDay: "2026-03-27", toDay: "2026-03-31")
    XCTAssertEqual(
      days.map { $0.label }, ["2026-03-27", "2026-03-28", "2026-03-29", "2026-03-30", "2026-03-31"])
    XCTAssertEqual(days.map { $0.hours }, [24, 24, 23, 24, 24])
    for (a, b) in zip(days, days.dropFirst()) { XCTAssertEqual(a.end, b.start) }
    let autumn = try g.days(fromDay: "2026-10-24", toDay: "2026-10-26")
    XCTAssertEqual(autumn.map { $0.hours }, [24, 25, 24])
  }

  func testSouthernHemisphereAndHalfHourZones() throws {
    // Chile moves the clock back at midnight: 2026-04-04 has 25 hours.
    XCTAssertEqual(grid("America/Santiago").day("2026-04-04")?.hours, 25)
    // Lord Howe: DST shift of 30 minutes.
    let lh = grid("Australia/Lord_Howe")
    XCTAssertEqual(lh.day("2026-10-04")?.hours, 23.5)
    // Fixed offset zones never change.
    XCTAssertEqual(grid("Asia/Kolkata").day("2026-03-29")?.hours, 24)
  }

  func testMissingMidnightDayStartsAtOneAndAnchorUsesPreviousDay() throws {
    // Egypt starts DST on the last Friday of April at 00:00 -> 01:00.
    let g = grid("Africa/Cairo")
    let gap = try XCTUnwrap(g.day("2026-04-24"))
    XCTAssertEqual(gap.hours, 23)
    XCTAssertEqual(g.calendar.component(.hour, from: gap.start), 1)
    XCTAssertEqual(g.label(of: gap.start), "2026-04-24")
    let days = try g.days(fromDay: "2026-04-24", toDay: "2026-04-25")
    let anchor = try XCTUnwrap(g.anchorDate(for: days))
    XCTAssertEqual(anchor, g.day("2026-04-23")?.start)
    XCTAssertEqual(g.calendar.component(.hour, from: anchor), 0)
    // A normal first day is its own anchor.
    let normal = try g.days(fromDay: "2026-04-20", toDay: "2026-04-22")
    XCTAssertEqual(g.anchorDate(for: normal), normal.first?.start)
  }

  func testRangeErrors() {
    let g = grid("Europe/Berlin")
    XCTAssertThrowsError(try g.days(fromDay: "2026-10-19", toDay: "2026-10-18"))
    XCTAssertThrowsError(try g.days(fromDay: "nope", toDay: "2026-10-18"))
    XCTAssertThrowsError(try g.days(fromDay: "2026-10-19", toDay: "2026-13-01"))
    XCTAssertThrowsError(try g.days(fromDay: "2000-01-01", toDay: "2026-10-18"))
    XCTAssertEqual(try g.days(fromDay: "2026-10-19", toDay: "2026-10-19").count, 1)
    // 1825 days are fine (5 year look-back).
    XCTAssertEqual(try g.days(fromDay: "2021-10-20", toDay: "2026-10-18").count, 1825)
  }

  // MARK: HealthKit interval must be exactly one day

  func testAlignedDayAcceptsCalendarDaysOnly() throws {
    let g = grid("Europe/Berlin")
    let d = try XCTUnwrap(g.day("2026-03-29"))
    XCTAssertEqual(g.alignedDay(start: d.start, end: d.end), d)
    // A 24-hour interval on the 23-hour day (fixed 24 h stride) is rejected.
    XCTAssertNil(g.alignedDay(start: d.start, end: d.start.addingTimeInterval(24 * 3600)))
    // An interval shifted by one hour (anchor on a DST gap) is rejected.
    XCTAssertNil(g.alignedDay(start: d.start.addingTimeInterval(3600), end: d.end.addingTimeInterval(3600)))
  }

  // MARK: Late samples

  /// A late sample (old start, new insertion) belongs to the day of its start:
  /// the day label of an old start is an old day, which is what the engine
  /// recomputes. Samples that span midnight touch both days.
  func testLateAndMidnightSpanningSamplesMapToTheirDays() {
    let g = grid("Europe/Berlin")
    let lateStart = utc(2026, 10, 12, 20, 30)  // a week old
    XCTAssertEqual(g.label(of: lateStart), "2026-10-12")
    let start = utc(2026, 10, 19, 21, 50)  // 23:50 local
    let end = utc(2026, 10, 19, 22, 10)  // 00:10 local next day
    XCTAssertEqual(g.label(of: start), "2026-10-19")
    XCTAssertEqual(g.label(of: end), "2026-10-20")
    // The end is exclusive: a sample ending exactly at local midnight (22:00 UTC)
    // touches only the old day, its last instant is one millisecond earlier.
    XCTAssertEqual(g.label(of: utc(2026, 10, 19, 22).addingTimeInterval(-0.001)), "2026-10-19")
  }
}
