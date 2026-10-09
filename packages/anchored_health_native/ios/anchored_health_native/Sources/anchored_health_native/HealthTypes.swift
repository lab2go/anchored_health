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

  /// Quantity type; nil for blood pressure (correlation).
  var quantityIdentifier: HKQuantityTypeIdentifier? {
    switch self {
    case .bloodPressure: return nil
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
    case .vo2Max: return HKUnit(from: "ml/kg*min")
    }
  }

  var unitString: String { unit.unitString }

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
    return [HealthDataType.systolicType, HealthDataType.diastolicType]
  }

  /// Write permissions. Correlation types must not be in the share set
  /// (HealthKit raises an Objective-C exception otherwise).
  var shareSampleTypes: Set<HKSampleType> {
    if let id = quantityIdentifier { return [HKQuantityType(id)] }
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
