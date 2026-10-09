import Flutter
import HealthKit
import UIKit
import XCTest

// If the plugin is marked "type: .dynamic" in Package.swift, it must be added
// as a dependency of RunnerTests in Xcode.

@testable import anchored_health_native

/// Swift tests without HealthKit permission (simulator): type mapping, units,
/// authorization sets, anchors, time windows, metadata, blood pressure correlation.
class RunnerTests: XCTestCase {

  private let t0: Int64 = 1_760_000_000_000  // fixed synthetic point in time

  private func saveRequest(
    type: String, value: Double? = nil, sys: Double? = nil, dia: Double? = nil,
    sync: String = "app:row-1", deviceName: String? = "Example App"
  ) -> HkSaveRequest {
    HkSaveRequest(
      type: type, startMs: t0, endMs: t0, value: value, systolic: sys, diastolic: dia,
      syncIdentifier: sync, syncVersion: 3, externalUuid: "row-1", wasUserEntered: true,
      wasTakenInLab: false, timeZone: "UTC", bloodGlucoseMealTime: nil, deviceName: deviceName)
  }

  // MARK: Types and units

  func testAllTypesParseAndHaveUnits() throws {
    for t in HealthDataType.allCases {
      XCTAssertEqual(try HealthDataType.parse(t.rawValue), t)
      XCTAssertFalse(t.unitString.isEmpty)
      XCTAssertNotNil(t.sampleType)
    }
    XCTAssertThrowsError(try HealthDataType.parse("stepCount"))
  }

  func testUnits() {
    XCTAssertEqual(HealthDataType.bloodPressure.unitString, "mmHg")
    XCTAssertEqual(HealthDataType.bodyMass.unitString, "kg")
    XCTAssertEqual(HealthDataType.height.unitString, "cm")
    XCTAssertEqual(HealthDataType.bodyTemperature.unitString, "degC")
    XCTAssertEqual(HealthDataType.bloodGlucose.unitString, "mg/dL")
    XCTAssertEqual(HealthDataType.heartRate.unitString, "count/min")
    XCTAssertEqual(HealthDataType.oxygenSaturation.unitString, "%")
    XCTAssertEqual(HealthDataType.heartRateVariabilitySDNN.unitString, "ms")
  }

  func testBloodPressureUsesCorrelationType() {
    XCTAssertEqual(
      HealthDataType.bloodPressure.sampleType, HKCorrelationType(.bloodPressure))
    XCTAssertEqual(HealthDataType.bodyMass.sampleType, HKQuantityType(.bodyMass))
  }

  func testWritableTypes() {
    XCTAssertTrue(HealthDataType.bloodPressure.isWritable)
    XCTAssertTrue(HealthDataType.bloodGlucose.isWritable)
    XCTAssertFalse(HealthDataType.restingHeartRate.isWritable)
    XCTAssertFalse(HealthDataType.respiratoryRate.isWritable)
  }

  // MARK: Authorization

  func testAuthorizationSetsNeverContainCorrelationAndUnionCharacteristics() throws {
    let sets = try HealthDataType.authorizationSets(
      read: ["bloodPressure", "bodyMass", "bloodGlucose"], write: ["bloodPressure"],
      characteristics: true, includeBloodPressureCorrelation: true)
    // HealthKit disallows correlation types in the read set (ObjC exception, app termination).
    XCTAssertFalse(sets.read.contains(HKCorrelationType(.bloodPressure)))
    XCTAssertTrue(sets.read.contains(HKQuantityType(.bloodPressureSystolic)))
    XCTAssertTrue(sets.read.contains(HKQuantityType(.bloodPressureDiastolic)))
    XCTAssertTrue(sets.read.contains(HKCharacteristicType(.dateOfBirth)))
    XCTAssertTrue(sets.read.contains(HKCharacteristicType(.biologicalSex)))
    XCTAssertEqual(sets.read.count, 6)
    // Never a correlation in the share set (HealthKit raises an ObjC exception otherwise).
    XCTAssertEqual(
      sets.share, [HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic)])
    XCTAssertFalse(sets.share.contains(HKCorrelationType(.bloodPressure)))
  }

  func testAuthorizationWithoutCorrelationFlag() throws {
    let sets = try HealthDataType.authorizationSets(
      read: ["bloodPressure"], write: [], characteristics: false,
      includeBloodPressureCorrelation: false)
    XCTAssertFalse(sets.read.contains(HKCorrelationType(.bloodPressure)))
    XCTAssertEqual(sets.read.count, 2)
  }

  func testAuthorizationRejectsInvalidInput() {
    XCTAssertThrowsError(
      try HealthDataType.authorizationSets(
        read: [], write: [], characteristics: false, includeBloodPressureCorrelation: true))
    XCTAssertThrowsError(
      try HealthDataType.authorizationSets(
        read: [], write: ["restingHeartRate"], characteristics: false,
        includeBloodPressureCorrelation: true))
    XCTAssertThrowsError(
      try HealthDataType.authorizationSets(
        read: ["unknown"], write: [], characteristics: false, includeBloodPressureCorrelation: true))
  }

  // MARK: Anchor and window

  func testAnchorRoundTrip() throws {
    let anchor = HKQueryAnchor(fromValue: 42)
    let encoded = try HealthCodec.encodeAnchor(anchor)
    let decoded = try HealthCodec.decodeAnchor(encoded)
    XCTAssertEqual(decoded, anchor)
    XCTAssertNil(try HealthCodec.decodeAnchor(nil))
    XCTAssertNil(try HealthCodec.decodeAnchor(""))
    XCTAssertThrowsError(try HealthCodec.decodeAnchor("not-base64"))
  }

  func testWindowPredicateOnStartDate() {
    let type = HKQuantityType(.bodyMass)
    func sample(_ ms: Int64) -> HKQuantitySample {
      HKQuantitySample(
        type: type, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 70),
        start: HealthCodec.date(ms), end: HealthCodec.date(ms))
    }
    XCTAssertNil(HealthCodec.windowPredicate(fromMs: nil, toMs: nil))
    let p = HealthCodec.windowPredicate(fromMs: t0, toMs: t0 + 1000)!
    XCTAssertTrue(p.evaluate(with: sample(t0)))
    XCTAssertTrue(p.evaluate(with: sample(t0 + 999)))
    XCTAssertFalse(p.evaluate(with: sample(t0 + 1000)))
    XCTAssertFalse(p.evaluate(with: sample(t0 - 1)))
  }

  func testMillisRoundTrip() {
    XCTAssertEqual(HealthCodec.millis(HealthCodec.date(t0)), t0)
  }

  // MARK: Writing

  func testSaveMetadata() throws {
    var r = saveRequest(type: "bloodGlucose", value: 95)
    r.wasTakenInLab = true
    r.wasUserEntered = false
    r.bloodGlucoseMealTime = 1
    let m = try HealthCodec.saveMetadata(r)
    XCTAssertEqual(m[HKMetadataKeySyncIdentifier] as? String, "app:row-1")
    XCTAssertEqual((m[HKMetadataKeySyncVersion] as? NSNumber)?.int64Value, 3)
    XCTAssertEqual(m[HKMetadataKeyExternalUUID] as? String, "row-1")
    XCTAssertEqual((m[HKMetadataKeyWasUserEntered] as? NSNumber)?.boolValue, false)
    XCTAssertEqual((m[HKMetadataKeyWasTakenInLab] as? NSNumber)?.boolValue, true)
    XCTAssertEqual(m[HKMetadataKeyTimeZone] as? String, "UTC")
    XCTAssertEqual(
      (m[HKMetadataKeyBloodGlucoseMealTime] as? NSNumber)?.intValue,
      HKBloodGlucoseMealTime.preprandial.rawValue)
  }

  func testSaveMetadataAcceptsAnyPrefix() throws {
    let m = try HealthCodec.saveMetadata(saveRequest(type: "bodyMass", value: 70, sync: "custom:7"))
    XCTAssertEqual(m[HKMetadataKeySyncIdentifier] as? String, "custom:7")
  }

  func testSaveMetadataRejectsEmptyIdentifierAndBadValues() {
    XCTAssertThrowsError(try HealthCodec.saveMetadata(saveRequest(type: "bodyMass", value: 70, sync: "")))
    var r = saveRequest(type: "bodyMass", value: 70)
    r.timeZone = "Mars/Olympus"
    XCTAssertThrowsError(try HealthCodec.saveMetadata(r))
    r = saveRequest(type: "bloodGlucose", value: 90)
    r.bloodGlucoseMealTime = 9
    XCTAssertThrowsError(try HealthCodec.saveMetadata(r))
  }

  func testMakeObjectQuantity() throws {
    let obj = try HealthCodec.makeObject(saveRequest(type: "bodyMass", value: 72.4))
    let q = try XCTUnwrap(obj as? HKQuantitySample)
    XCTAssertEqual(q.quantityType, HKQuantityType(.bodyMass))
    XCTAssertEqual(q.quantity.doubleValue(for: .gramUnit(with: .kilo)), 72.4, accuracy: 1e-9)
    XCTAssertEqual(q.device?.name, "Example App")
    XCTAssertEqual(q.metadata?[HKMetadataKeySyncIdentifier] as? String, "app:row-1")
  }

  func testMakeObjectWithoutDeviceName() throws {
    let obj = try HealthCodec.makeObject(saveRequest(type: "bodyMass", value: 72.4, deviceName: nil))
    XCTAssertNil(obj.device)
    let empty = try HealthCodec.makeObject(saveRequest(type: "bodyMass", value: 72.4, deviceName: ""))
    XCTAssertNil(empty.device)
  }

  func testMakeObjectBloodPressureIsOneCorrelation() throws {
    let obj = try HealthCodec.makeObject(saveRequest(type: "bloodPressure", sys: 128, dia: 82))
    let c = try XCTUnwrap(obj as? HKCorrelation)
    XCTAssertEqual(c.correlationType, HKCorrelationType(.bloodPressure))
    XCTAssertEqual(c.objects.count, 2)
    XCTAssertEqual(c.metadata?[HKMetadataKeySyncIdentifier] as? String, "app:row-1")
    let sys = try XCTUnwrap(
      c.objects(for: HKQuantityType(.bloodPressureSystolic)).first as? HKQuantitySample)
    XCTAssertEqual(sys.quantity.doubleValue(for: .millimeterOfMercury()), 128)
    XCTAssertEqual(sys.metadata?[HKMetadataKeySyncIdentifier] as? String, "app:row-1:sys")
    let dia = try XCTUnwrap(
      c.objects(for: HKQuantityType(.bloodPressureDiastolic)).first as? HKQuantitySample)
    XCTAssertEqual(dia.metadata?[HKMetadataKeySyncIdentifier] as? String, "app:row-1:dia")
  }

  func testMakeObjectRejects() {
    XCTAssertThrowsError(try HealthCodec.makeObject(saveRequest(type: "restingHeartRate", value: 60)))
    XCTAssertThrowsError(try HealthCodec.makeObject(saveRequest(type: "bloodPressure", sys: 120)))
    XCTAssertThrowsError(try HealthCodec.makeObject(saveRequest(type: "bodyMass")))
    var r = saveRequest(type: "bodyMass", value: 70)
    r.endMs = r.startMs - 1
    XCTAssertThrowsError(try HealthCodec.makeObject(r))
  }

  // MARK: Reading

  private let fakeSource = HkSource(
    bundleId: "com.example.meter", name: "Test meter", version: "1.0", productType: nil,
    operatingSystemVersion: nil)

  func testMakeSampleBloodPressureFromCorrelation() throws {
    let obj = try HealthCodec.makeObject(saveRequest(type: "bloodPressure", sys: 131, dia: 79))
    let s = try HealthCodec.makeSample(obj, type: .bloodPressure, source: fakeSource)
    XCTAssertEqual(s.uuid, obj.uuid.uuidString)
    XCTAssertNil(s.value)
    XCTAssertEqual(s.bloodPressure?.systolic, 131)
    XCTAssertEqual(s.bloodPressure?.diastolic, 79)
    XCTAssertEqual(s.unit, "mmHg")
    XCTAssertEqual(s.startMs, t0)
    XCTAssertEqual(s.device?.name, "Example App")
    XCTAssertEqual(s.metadata[HKMetadataKeySyncIdentifier] as? String, "app:row-1")
    XCTAssertEqual(s.metadata[HKMetadataKeySyncVersion] as? Int64, 3)
    XCTAssertEqual(s.metadata[HKMetadataKeyWasUserEntered] as? Bool, true)
  }

  func testMakeSampleQuantityWithForeignDevice() throws {
    let device = HKDevice(
      name: "Scale", manufacturer: "Example Inc.", model: "W-1", hardwareVersion: nil,
      firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
    let q = HKQuantitySample(
      type: HKQuantityType(.oxygenSaturation), quantity: HKQuantity(unit: .percent(), doubleValue: 0.97),
      start: HealthCodec.date(t0), end: HealthCodec.date(t0), device: device,
      metadata: ["date": HealthCodec.date(t0), "n": 1.5])
    let s = try HealthCodec.makeSample(q, type: .oxygenSaturation, source: fakeSource)
    XCTAssertEqual(s.value!, 0.97, accuracy: 1e-9)
    XCTAssertEqual(s.device?.model, "W-1")
    XCTAssertEqual(s.device?.manufacturer, "Example Inc.")
    XCTAssertEqual(s.metadata["date"] as? Int64, t0)
    XCTAssertEqual(s.metadata["n"] as? Double, 1.5)
    XCTAssertEqual(s.source.bundleId, "com.example.meter")
  }

  func testMakeSampleRejectsWrongClass() throws {
    let q = HKQuantitySample(
      type: HKQuantityType(.bodyMass), quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 70),
      start: Date(), end: Date())
    XCTAssertThrowsError(try HealthCodec.makeSample(q, type: .bloodPressure, source: fakeSource))
    XCTAssertThrowsError(try HealthCodec.makeSample(q, type: .bloodGlucose, source: fakeSource))
  }

  func testCharacteristicsMapping() {
    let c = HealthCodec.characteristics(
      dateOfBirth: DateComponents(year: 1980, month: 5, day: 2), sex: .female)
    XCTAssertEqual(c.birthYear, 1980)
    XCTAssertEqual(c.biologicalSex, "female")
    let none = HealthCodec.characteristics(dateOfBirth: nil, sex: .notSet)
    XCTAssertNil(none.birthYear)
    XCTAssertNil(none.biologicalSex)
  }

  /// The Dart side reads metadata through these raw keys (anchored_health_engine
  /// `HealthKitMetadataKeys`). If Apple changes a value, this test fails.
  func testMetadataKeyRawValues() {
    XCTAssertEqual(HKMetadataKeySyncIdentifier, "HKMetadataKeySyncIdentifier")
    XCTAssertEqual(HKMetadataKeySyncVersion, "HKMetadataKeySyncVersion")
    XCTAssertEqual(HKMetadataKeyExternalUUID, "HKExternalUUID")
    XCTAssertEqual(HKMetadataKeyWasUserEntered, "HKWasUserEntered")
    XCTAssertEqual(HKMetadataKeyTimeZone, "HKTimeZone")
    XCTAssertEqual(HKMetadataKeyWasTakenInLab, "HKWasTakenInLab")
    XCTAssertEqual(HKMetadataKeyBloodGlucoseMealTime, "HKBloodGlucoseMealTime")
  }

  // MARK: Registration

  func testNativeCreatesStoreLazily() {
    let native = AnchoredHealthNative()
    XCTAssertFalse(native.hasStore)
    _ = try? AnchoredHealthApiImpl(native: native).supportedTypes()
    XCTAssertFalse(native.hasStore, "supportedTypes must not create an HKHealthStore")
  }

  func testApiImplUnitFor() throws {
    let api = AnchoredHealthApiImpl(native: AnchoredHealthNative())
    XCTAssertEqual(try api.unitFor(type: "bloodGlucose"), "mg/dL")
    XCTAssertEqual(try api.supportedTypes().count, HealthDataType.allCases.count)
  }
}
