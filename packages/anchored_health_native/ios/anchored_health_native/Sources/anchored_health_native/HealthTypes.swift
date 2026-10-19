import Foundation
import HealthKit

/// Platform type keys and their HealthKit counterparts. Pure logic without
/// HKHealthStore, so it is testable.
enum HealthDataType: String, CaseIterable {
  // Read and write
  case bloodPressure
  case heartRate
  case restingHeartRate
  case bodyMass
  case height
  case bodyTemperature
  case oxygenSaturation
  case respiratoryRate
  case bloodGlucose
  // Read only
  case heartRateVariabilitySDNN
  case bodyFatPercentage
  case waistCircumference
  case vo2Max
  /// Sleep analysis (category type). Value = HKCategoryValueSleepAnalysis raw
  /// value: 0 inBed, 1 asleepUnspecified, 2 awake, 3 asleepCore, 4 asleepDeep,
  /// 5 asleepREM. One sample per interval; never written.
  case sleepAnalysis
  // Read only, cumulative daily totals (HKStatisticsCollectionQuery). The
  // single samples are only used as references to find the days a change
  // touches, see `ActivityDayGrid` and `AnchoredHealthNative.dailyTotals`.
  case stepCount
  case distanceWalkingRunning
  case activeEnergyBurned
  case flightsClimbed
  case appleExerciseTime

  /// Cumulative activity types: delivered as daily totals, read only.
  var isCumulativeActivity: Bool {
    switch self {
    case .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .flightsClimbed,
      .appleExerciseTime:
      return true
    default:
      return false
    }
  }

  /// Options of the daily statistics: the cumulative sum over all sources.
  /// HealthKit merges overlapping sources (iPhone and Apple Watch) in this
  /// mode by the user's source order, so the same steps are not counted twice.
  /// `.separateBySource` is deliberately never used: it would hand the
  /// duplicates back.
  var dailyStatisticsOptions: HKStatisticsOptions? {
    isCumulativeActivity ? [.cumulativeSum] : nil
  }

  /// Category type; nil for quantity and correlation types.
  var categoryIdentifier: HKCategoryTypeIdentifier? {
    switch self {
    case .sleepAnalysis: return .sleepAnalysis
    default: return nil
    }
  }

  /// Quantity type; nil for blood pressure (correlation) and category types.
  var quantityIdentifier: HKQuantityTypeIdentifier? {
    switch self {
    case .bloodPressure, .sleepAnalysis: return nil
    case .heartRate: return .heartRate
    case .restingHeartRate: return .restingHeartRate
    case .bodyMass: return .bodyMass
    case .height: return .height
    case .bodyTemperature: return .bodyTemperature
    case .oxygenSaturation: return .oxygenSaturation
    case .respiratoryRate: return .respiratoryRate
    case .bloodGlucose: return .bloodGlucose
    case .heartRateVariabilitySDNN: return .heartRateVariabilitySDNN
    case .bodyFatPercentage: return .bodyFatPercentage
    case .waistCircumference: return .waistCircumference
    case .vo2Max: return .vo2Max
    case .stepCount: return .stepCount
    case .distanceWalkingRunning: return .distanceWalkingRunning
    case .activeEnergyBurned: return .activeEnergyBurned
    case .flightsClimbed: return .flightsClimbed
    case .appleExerciseTime: return .appleExerciseTime
    }
  }

  /// Fixed unit in which the plugin delivers and expects values.
  /// Percentage types follow the HealthKit convention (0...1).
  var unit: HKUnit {
    switch self {
    case .bloodPressure: return .millimeterOfMercury()
    case .heartRate, .restingHeartRate, .respiratoryRate:
      return HKUnit.count().unitDivided(by: .minute())
    case .bodyMass: return .gramUnit(with: .kilo)
    case .height, .waistCircumference: return .meterUnit(with: .centi)
    case .bodyTemperature: return .degreeCelsius()
    case .oxygenSaturation, .bodyFatPercentage: return .percent()
    case .bloodGlucose: return HKUnit(from: "mg/dL")
    case .heartRateVariabilitySDNN: return .secondUnit(with: .milli)
    case .vo2Max:
      return HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo))
        .unitDivided(by: HKUnit.minute())
    case .sleepAnalysis: return .count()
    case .stepCount, .flightsClimbed: return .count()
    case .distanceWalkingRunning: return .meter()
    case .activeEnergyBurned: return .kilocalorie()
    case .appleExerciseTime: return .minute()
    }
  }

  /// Unit label sent with every sample. Fixed text where HealthKit's
  /// `unitString` is not a stable, readable label (VO2 max; sleep has no unit).
  var unitString: String {
    switch self {
    case .vo2Max: return "ml/kg/min"
    case .sleepAnalysis: return "stage"
    // Canonical units of the daily totals (count, m, kcal, min).
    case .stepCount, .flightsClimbed: return "count"
    case .distanceWalkingRunning: return "m"
    case .activeEnergyBurned: return "kcal"
    case .appleExerciseTime: return "min"
    default: return unit.unitString
    }
  }

  /// Only these types may be written. Other types are rejected before any
  /// HealthKit call.
  var isWritable: Bool {
    switch self {
    case .bloodPressure, .heartRate, .bodyMass, .height, .bodyTemperature,
      .oxygenSaturation, .bloodGlucose:
      return true
    default:
      return false
    }
  }

  static var systolicType: HKQuantityType { HKQuantityType(.bloodPressureSystolic) }
  static var diastolicType: HKQuantityType { HKQuantityType(.bloodPressureDiastolic) }
  static var bloodPressureCorrelationType: HKCorrelationType {
    HKCorrelationType(.bloodPressure)
  }

  /// Type used for anchored queries, sample queries and deletion.
  var sampleType: HKSampleType {
    if let id = quantityIdentifier { return HKQuantityType(id) }
    if let id = categoryIdentifier { return HKCategoryType(id) }
    return HealthDataType.bloodPressureCorrelationType
  }

  /// Read permissions. Blood pressure: both quantity types only. HealthKit
  /// rejects correlation types in the read set as well as in the share set
  /// (NSInvalidArgumentException "Authorization to read the following types is
  /// disallowed"), which cannot be caught from Swift and terminates the app.
  /// Reading the correlation samples needs authorization of the two quantity
  /// types only. `includeBloodPressureCorrelation` is kept for API
  /// compatibility and is ignored.
  func readObjectTypes(includeBloodPressureCorrelation: Bool) -> Set<HKObjectType> {
    if let id = quantityIdentifier { return [HKQuantityType(id)] }
    if let id = categoryIdentifier { return [HKCategoryType(id)] }
    return [HealthDataType.systolicType, HealthDataType.diastolicType]
  }

  /// Write permissions. Correlation types must not be in the share set
  /// (HealthKit raises an Objective-C exception otherwise).
  var shareSampleTypes: Set<HKSampleType> {
    if let id = quantityIdentifier { return [HKQuantityType(id)] }
    if let id = categoryIdentifier { return [HKCategoryType(id)] }
    return [HealthDataType.systolicType, HealthDataType.diastolicType]
  }

  static func parse(_ raw: String) throws -> HealthDataType {
    guard let t = HealthDataType(rawValue: raw) else {
      throw PigeonError(code: "unsupported_type", message: "Unknown type: \(raw)", details: nil)
    }
    return t
  }

  static var characteristicTypes: Set<HKObjectType> {
    [HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex)]
  }

  /// Union of all read/write types for exactly one dialog.
  static func authorizationSets(
    read: [String], write: [String], characteristics: Bool,
    includeBloodPressureCorrelation: Bool
  ) throws -> (share: Set<HKSampleType>, read: Set<HKObjectType>) {
    var share = Set<HKSampleType>()
    var readSet = Set<HKObjectType>()
    for raw in write {
      let t = try parse(raw)
      guard t.isWritable else {
        throw PigeonError(code: "not_writable", message: "Type is not writable: \(raw)", details: nil)
      }
      share.formUnion(t.shareSampleTypes)
    }
    for raw in read {
      readSet.formUnion(
        try parse(raw).readObjectTypes(
          includeBloodPressureCorrelation: includeBloodPressureCorrelation))
    }
    if characteristics { readSet.formUnion(characteristicTypes) }
    if share.isEmpty && readSet.isEmpty {
      throw PigeonError(code: "invalid_argument", message: "No types requested", details: nil)
    }
    return (share, readSet)
  }
}
