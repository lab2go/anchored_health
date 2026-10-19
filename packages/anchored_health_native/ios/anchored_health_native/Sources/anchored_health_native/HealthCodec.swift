import Foundation
import HealthKit

/// Conversions HealthKit <-> Pigeon model. Pure functions (testable without a store).
enum HealthCodec {
  static func millis(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  static func date(_ millis: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
  }

  // MARK: Anchor

  static func encodeAnchor(_ anchor: HKQueryAnchor) throws -> String {
    let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    return data.base64EncodedString()
  }

  static func decodeAnchor(_ base64: String?) throws -> HKQueryAnchor? {
    guard let base64 = base64, !base64.isEmpty else { return nil }
    guard let data = Data(base64Encoded: base64),
      let anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    else {
      throw PigeonError(code: "invalid_anchor", message: "Anchor cannot be decoded", details: nil)
    }
    return anchor
  }

  // MARK: Time window

  /// Window on the start date: from <= startDate < to. nil if there is no window.
  static func windowPredicate(fromMs: Int64?, toMs: Int64?) -> NSPredicate? {
    var parts: [NSPredicate] = []
    if let f = fromMs {
      parts.append(
        NSPredicate(format: "%K >= %@", HKPredicateKeyPathStartDate, date(f) as NSDate))
    }
    if let t = toMs {
      parts.append(NSPredicate(format: "%K < %@", HKPredicateKeyPathStartDate, date(t) as NSDate))
    }
    if parts.isEmpty { return nil }
    return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
  }

  // MARK: Reading metadata

  /// HKTimeZone of foreign sources: a real IANA name is passed on as is. Offset spellings such as
  /// "GMT+02:00" / "UTC-0530" are kept and written as one canonical "GMT±hh:mm" (east positive, the way the
  /// server reads them); dropping them would shift night sleep to the wrong day without any hint.
  /// Impossible offsets (more than 14 h, 60+ minutes), empty or overlong values and unknown names give nil.
  static func sanitizedTimeZone(_ raw: String) -> String? {
    let t = raw.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty, t.count <= 64 else { return nil }
    let offsetPattern = "^(?:GMT|UTC)([+-])([0-9]{1,2})(?::?([0-9]{2}))?$"
    if let re = try? NSRegularExpression(pattern: offsetPattern),
      let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
      let signR = Range(m.range(at: 1), in: t), let hR = Range(m.range(at: 2), in: t),
      let h = Int(t[hR])
    {
      var minutes = 0
      if m.range(at: 3).location != NSNotFound, let mR = Range(m.range(at: 3), in: t),
        let mi = Int(t[mR])
      {
        minutes = mi
      }
      guard h <= 14, minutes < 60 else { return nil }
      return String(format: "GMT%@%02d:%02d", String(t[signR]), h, minutes)
    }
    guard TimeZone(identifier: t) != nil else { return nil }
    if t.range(of: "^(GMT|UTC)[+-]", options: .regularExpression) != nil { return nil }
    return t
  }

  /// HK metadata to Pigeon-compatible values: bool/number/string stay, date -> ms, rest -> text.
  /// HKTimeZone is kept as IANA name or canonical offset, otherwise dropped (see `sanitizedTimeZone`).
  static func metadataToPigeon(_ metadata: [String: Any]?) -> [String?: Any?] {
    var out: [String?: Any?] = [:]
    guard let metadata = metadata else { return out }
    for (key, value) in metadata {
      if key == HKMetadataKeyTimeZone {
        if let s = value as? String, let tz = sanitizedTimeZone(s) { out[key] = tz }
        continue
      }
      switch value {
      case let s as String: out[key] = s
      case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() {
          out[key] = n.boolValue
        } else if CFNumberIsFloatType(n) {
          out[key] = n.doubleValue
        } else {
          out[key] = n.int64Value
        }
      case let d as Date: out[key] = millis(d)
      case let q as HKQuantity: out[key] = q.description
      default: out[key] = String(describing: value)
      }
    }
    return out
  }

  static func syncVersion(from metadata: [String: Any]?) -> Int64? {
    guard let v = metadata?[HKMetadataKeySyncVersion] else { return nil }
    if let n = v as? NSNumber { return n.int64Value }
    return nil
  }

  // MARK: Writing metadata

  /// Metadata for an exported sample. `suffix` distinguishes the children of a
  /// blood pressure correlation (":sys"/":dia").
  static func saveMetadata(_ r: HkSaveRequest, suffix: String = "") throws -> [String: Any] {
    guard !r.syncIdentifier.isEmpty else {
      throw PigeonError(
        code: "invalid_argument", message: "syncIdentifier must not be empty", details: nil)
    }
    var m: [String: Any] = [
      HKMetadataKeySyncIdentifier: r.syncIdentifier + suffix,
      HKMetadataKeySyncVersion: NSNumber(value: r.syncVersion),
      HKMetadataKeyWasUserEntered: NSNumber(value: r.wasUserEntered),
    ]
    if let e = r.externalUuid { m[HKMetadataKeyExternalUUID] = e }
    if let lab = r.wasTakenInLab { m[HKMetadataKeyWasTakenInLab] = NSNumber(value: lab) }
    if let tz = r.timeZone {
      guard TimeZone(identifier: tz) != nil else {
        throw PigeonError(code: "invalid_argument", message: "Unknown time zone: \(tz)", details: nil)
      }
      m[HKMetadataKeyTimeZone] = tz
    }
    if let meal = r.bloodGlucoseMealTime {
      // NS_ENUM init accepts any raw value, so check explicitly.
      guard meal == 1 || meal == 2, let mt = HKBloodGlucoseMealTime(rawValue: Int(meal)) else {
        throw PigeonError(code: "invalid_argument", message: "Invalid meal time: \(meal)", details: nil)
      }
      m[HKMetadataKeyBloodGlucoseMealTime] = NSNumber(value: mt.rawValue)
    }
    return m
  }

  /// `HKDevice` for written objects; nil if the request carries no (non-empty) name.
  static func writeDevice(_ r: HkSaveRequest) -> HKDevice? {
    guard let name = r.deviceName, !name.isEmpty else { return nil }
    return HKDevice(
      name: name, manufacturer: nil, model: nil, hardwareVersion: nil,
      firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
  }

  /// Builds the HealthKit object for a save request (blood pressure = exactly one correlation).
  static func makeObject(_ r: HkSaveRequest) throws -> HKSample {
    let type = try HealthDataType.parse(r.type)
    guard type.isWritable else {
      throw PigeonError(code: "not_writable", message: "Type is not writable: \(r.type)", details: nil)
    }
    let start = date(r.startMs)
    let end = date(r.endMs)
    guard end >= start else {
      throw PigeonError(code: "invalid_argument", message: "End before start", details: nil)
    }
    let device = writeDevice(r)
    if type == .bloodPressure {
      guard let sys = r.systolic, let dia = r.diastolic, sys > 0, dia > 0 else {
        throw PigeonError(code: "invalid_argument", message: "Blood pressure needs systolic and diastolic", details: nil)
      }
      let unit = type.unit
      let sysSample = HKQuantitySample(
        type: HealthDataType.systolicType, quantity: HKQuantity(unit: unit, doubleValue: sys),
        start: start, end: end, device: device, metadata: try saveMetadata(r, suffix: ":sys"))
      let diaSample = HKQuantitySample(
        type: HealthDataType.diastolicType, quantity: HKQuantity(unit: unit, doubleValue: dia),
        start: start, end: end, device: device, metadata: try saveMetadata(r, suffix: ":dia"))
      return HKCorrelation(
        type: HealthDataType.bloodPressureCorrelationType, start: start, end: end,
        objects: [sysSample, diaSample], device: device, metadata: try saveMetadata(r))
    }
    guard let value = r.value, let id = type.quantityIdentifier else {
      throw PigeonError(code: "invalid_argument", message: "Value missing", details: nil)
    }
    return HKQuantitySample(
      type: HKQuantityType(id), quantity: HKQuantity(unit: type.unit, doubleValue: value),
      start: start, end: end, device: device, metadata: try saveMetadata(r))
  }

  // MARK: Reading samples

  static func device(_ d: HKDevice?) -> HkDevice? {
    guard let d = d else { return nil }
    return HkDevice(
      name: d.name, model: d.model, manufacturer: d.manufacturer,
      hardwareVersion: d.hardwareVersion, firmwareVersion: d.firmwareVersion,
      softwareVersion: d.softwareVersion, localIdentifier: d.localIdentifier,
      udiDeviceIdentifier: d.udiDeviceIdentifier)
  }

  static func source(_ rev: HKSourceRevision) -> HkSource {
    let os = rev.operatingSystemVersion
    return HkSource(
      bundleId: rev.source.bundleIdentifier, name: rev.source.name, version: rev.version,
      productType: rev.productType,
      operatingSystemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
  }

  /// HKSample -> Pigeon sample. `source` is injectable because unsaved objects
  /// (tests) carry no reliable source.
  static func makeSample(
    _ s: HKSample, type: HealthDataType, source overrideSource: HkSource? = nil
  ) throws -> HkSample {
    let src = overrideSource ?? source(s.sourceRevision)
    var value: Double? = nil
    var bp: HkBloodPressure? = nil
    if type == .bloodPressure {
      guard let c = s as? HKCorrelation,
        let sys = c.objects(for: HealthDataType.systolicType).first as? HKQuantitySample,
        let dia = c.objects(for: HealthDataType.diastolicType).first as? HKQuantitySample
      else {
        throw PigeonError(code: "invalid_sample", message: "Blood pressure without both values", details: s.uuid.uuidString)
      }
      bp = HkBloodPressure(
        systolic: sys.quantity.doubleValue(for: type.unit),
        diastolic: dia.quantity.doubleValue(for: type.unit),
        systolicUuid: sys.uuid.uuidString, diastolicUuid: dia.uuid.uuidString)
    } else if type.categoryIdentifier != nil {
      guard let c = s as? HKCategorySample, c.categoryType == type.sampleType else {
        throw PigeonError(code: "invalid_sample", message: "Unexpected sample", details: s.uuid.uuidString)
      }
      value = Double(c.value)
    } else {
      guard let q = s as? HKQuantitySample, q.quantity.is(compatibleWith: type.unit) else {
        throw PigeonError(code: "invalid_sample", message: "Unexpected sample", details: s.uuid.uuidString)
      }
      value = q.quantity.doubleValue(for: type.unit)
    }
    return HkSample(
      uuid: s.uuid.uuidString, type: type.rawValue, startMs: millis(s.startDate),
      endMs: millis(s.endDate), value: value, unit: type.unitString, bloodPressure: bp,
      source: src, device: device(s.device), metadata: metadataToPigeon(s.metadata))
  }

  static func makeDeleted(_ d: HKDeletedObject) -> HkDeletedObject {
    HkDeletedObject(
      uuid: d.uuid.uuidString,
      syncIdentifier: d.metadata?[HKMetadataKeySyncIdentifier] as? String,
      syncVersion: syncVersion(from: d.metadata))
  }

  static func characteristics(
    dateOfBirth: DateComponents?, sex: HKBiologicalSex?
  ) -> HkCharacteristics {
    var sexText: String? = nil
    switch sex {
    case .female?: sexText = "female"
    case .male?: sexText = "male"
    case .other?: sexText = "other"
    default: sexText = nil
    }
    return HkCharacteristics(
      birthYear: dateOfBirth?.year.map(Int64.init), birthMonth: dateOfBirth?.month.map(Int64.init),
      birthDay: dateOfBirth?.day.map(Int64.init), biologicalSex: sexText)
  }
}
