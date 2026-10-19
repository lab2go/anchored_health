import Foundation
import HealthKit

/// HealthKit access. The `HKHealthStore` is created on the first call (never
/// during plugin registration); no access to UI objects. Public so that an app
/// delegate can use it without a Flutter engine (e.g. for background delivery).
public final class AnchoredHealthNative {
  public static let shared = AnchoredHealthNative()

  private let lock = NSLock()
  private var _store: HKHealthStore?

  init() {}

  var store: HKHealthStore {
    lock.lock()
    defer { lock.unlock() }
    if let s = _store { return s }
    let s = HKHealthStore()
    _store = s
    return s
  }

  /// Tests only: has the store been created yet?
  var hasStore: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _store != nil
  }

  public static var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

  private func ensureAvailable() throws {
    guard HKHealthStore.isHealthDataAvailable() else {
      throw PigeonError(code: "not_available", message: "HealthKit is not available on this device", details: nil)
    }
  }

  private static func wrap(_ error: Error?) -> PigeonError {
    if let p = error as? PigeonError { return p }
    let ns = error as NSError?
    return PigeonError(
      code: "healthkit_error", message: ns?.localizedDescription ?? "Unknown error",
      details: ns.map { "\($0.domain):\($0.code)" })
  }

  /// Always answer Flutter on the main thread.
  private static func onMain<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ r: Result<T, Error>) {
    if Thread.isMainThread { completion(r) } else { DispatchQueue.main.async { completion(r) } }
  }

  // MARK: Authorization

  func requestStatus(
    read: [String], write: [String], characteristics: Bool, includeCorrelation: Bool,
    completion: @escaping (Result<HkRequestStatus, Error>) -> Void
  ) {
    do {
      try ensureAvailable()
      let sets = try HealthDataType.authorizationSets(
        read: read, write: write, characteristics: characteristics,
        includeBloodPressureCorrelation: includeCorrelation)
      store.getRequestStatusForAuthorization(toShare: sets.share, read: sets.read) { status, error in
        if let error = error { return Self.onMain(completion, .failure(Self.wrap(error))) }
        let out: HkRequestStatus
        switch status {
        case .shouldRequest: out = .shouldRequest
        case .unnecessary: out = .unnecessary
        default: out = .unknown
        }
        Self.onMain(completion, .success(out))
      }
    } catch {
      completion(.failure(Self.wrap(error)))
    }
  }

  func requestAuthorization(
    read: [String], write: [String], characteristics: Bool, includeCorrelation: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    do {
      try ensureAvailable()
      let sets = try HealthDataType.authorizationSets(
        read: read, write: write, characteristics: characteristics,
        includeBloodPressureCorrelation: includeCorrelation)
      store.requestAuthorization(toShare: sets.share, read: sets.read) { success, error in
        if let error = error { return Self.onMain(completion, .failure(Self.wrap(error))) }
        Self.onMain(completion, .success(success))
      }
    } catch {
      completion(.failure(Self.wrap(error)))
    }
  }

  func writeStatus(_ rawType: String) throws -> HkWriteStatus {
    try ensureAvailable()
    let type = try HealthDataType.parse(rawType)
    let statuses = type.shareSampleTypes.map { store.authorizationStatus(for: $0) }
    if statuses.contains(.sharingDenied) { return .sharingDenied }
    if statuses.allSatisfy({ $0 == .sharingAuthorized }) { return .sharingAuthorized }
    return .notDetermined
  }

  func characteristics() throws -> HkCharacteristics {
    try ensureAvailable()
    let dob = try? store.dateOfBirthComponents()
    let sex = try? store.biologicalSex().biologicalSex
    return HealthCodec.characteristics(dateOfBirth: dob, sex: sex)
  }

  // MARK: Reading

  func anchoredQuery(
    _ request: HkAnchoredQueryRequest,
    completion: @escaping (Result<HkAnchoredQueryResult, Error>) -> Void
  ) {
    do {
      try ensureAvailable()
      let type = try HealthDataType.parse(request.type)
      let anchor = try HealthCodec.decodeAnchor(request.anchor)
      guard request.limit >= 0 else {
        throw PigeonError(code: "invalid_argument", message: "limit < 0", details: nil)
      }
      let predicate = HealthCodec.windowPredicate(fromMs: request.fromMs, toMs: request.toMs)
      let limit = request.limit == 0 ? HKObjectQueryNoLimit : Int(request.limit)
      let query = HKAnchoredObjectQuery(
        type: type.sampleType, predicate: predicate, anchor: anchor, limit: limit
      ) { _, samples, deleted, newAnchor, error in
        if let error = error { return Self.onMain(completion, .failure(Self.wrap(error))) }
        do {
          let mapped = try (samples ?? []).compactMap { s -> HkSample? in
            do {
              return try HealthCodec.makeSample(s, type: type)
            } catch let e as PigeonError where e.code == "invalid_sample" {
              // Incomplete correlation or similar: skip instead of failing the run.
              return nil
            }
          }
          let next = try newAnchor.map(HealthCodec.encodeAnchor)
          Self.onMain(
            completion,
            .success(
              HkAnchoredQueryResult(
                samples: mapped, deleted: (deleted ?? []).map(HealthCodec.makeDeleted),
                nextAnchor: next)))
        } catch {
          Self.onMain(completion, .failure(Self.wrap(error)))
        }
      }
      store.execute(query)
    } catch {
      completion(.failure(Self.wrap(error)))
    }
  }

  // MARK: Daily totals of cumulative activity types

  private func cumulativeType(_ raw: String) throws -> HealthDataType {
    let type = try HealthDataType.parse(raw)
    guard type.isCumulativeActivity else {
      throw PigeonError(
        code: "invalid_argument", message: "Not a cumulative activity type: \(raw)", details: nil)
    }
    return type
  }

  /// Daily totals with local day boundaries of the device. Days without any
  /// sample are not returned (no data is not 0). Queries the statistics over
  /// all sources, so HealthKit already merges iPhone and Apple Watch.
  func dailyTotals(
    _ request: HkDailyTotalsRequest,
    completion: @escaping (Result<HkDailyTotalsResult, Error>) -> Void
  ) {
    do {
      try ensureAvailable()
      let type = try cumulativeType(request.type)
      guard let identifier = type.quantityIdentifier, let options = type.dailyStatisticsOptions else {
        throw PigeonError(code: "invalid_argument", message: "No statistics for \(request.type)", details: nil)
      }
      let grid = ActivityDayGrid(timeZone: .current)
      let days: [ActivityDay]
      do {
        days = try grid.days(fromDay: request.fromDay, toDay: request.toDay)
      } catch {
        throw PigeonError(
          code: "invalid_argument", message: "Invalid day range: \(error)", details: nil)
      }
      guard let anchor = grid.anchorDate(for: days), let first = days.first, let last = days.last else {
        throw PigeonError(code: "invalid_argument", message: "Empty day range", details: nil)
      }
      let unit = type.unit
      let query = HKStatisticsCollectionQuery(
        quantityType: HKQuantityType(identifier), quantitySamplePredicate: nil, options: options,
        anchorDate: anchor, intervalComponents: DateComponents(day: 1))
      query.initialResultsHandler = { _, collection, error in
        if let error = error { return Self.onMain(completion, .failure(Self.wrap(error))) }
        var out: [HkDailyTotal] = []
        var misaligned: String?
        collection?.enumerateStatistics(from: first.start, to: last.end) { stat, _ in
          guard let sum = stat.sumQuantity() else { return }
          guard let day = grid.alignedDay(start: stat.startDate, end: stat.endDate) else {
            misaligned = grid.label(of: stat.startDate)
            return
          }
          out.append(
            HkDailyTotal(
              day: day.label, value: sum.doubleValue(for: unit),
              startMs: HealthCodec.millis(day.start), endMs: HealthCodec.millis(day.end)))
        }
        if let m = misaligned {
          return Self.onMain(
            completion,
            .failure(
              PigeonError(
                code: "interval_misaligned",
                message: "Statistics interval is not a calendar day: \(m)", details: nil)))
        }
        Self.onMain(
          completion,
          .success(HkDailyTotalsResult(days: out, timeZoneId: grid.timeZoneId)))
      }
      store.execute(query)
    } catch {
      completion(.failure(Self.wrap(error)))
    }
  }

  /// Sample references (UUID, start, end) and deleted UUIDs since an anchor,
  /// without values, sources or metadata.
  func sampleRefs(
    _ request: HkSampleRefsRequest,
    completion: @escaping (Result<HkSampleRefsResult, Error>) -> Void
  ) {
    do {
      try ensureAvailable()
      let type = try cumulativeType(request.type)
      let anchor = try HealthCodec.decodeAnchor(request.anchor)
      guard request.limit >= 0 else {
        throw PigeonError(code: "invalid_argument", message: "limit < 0", details: nil)
      }
      let predicate = HealthCodec.windowPredicate(fromMs: request.fromMs, toMs: request.toMs)
      let limit = request.limit == 0 ? HKObjectQueryNoLimit : Int(request.limit)
      let query = HKAnchoredObjectQuery(
        type: type.sampleType, predicate: predicate, anchor: anchor, limit: limit
      ) { _, samples, deleted, newAnchor, error in
        if let error = error { return Self.onMain(completion, .failure(Self.wrap(error))) }
        do {
          let refs = (samples ?? []).map {
            HkSampleRef(
              uuid: $0.uuid.uuidString, startMs: HealthCodec.millis($0.startDate),
              endMs: HealthCodec.millis($0.endDate))
          }
          let result = HkSampleRefsResult(
            refs: refs, deletedUuids: (deleted ?? []).map { $0.uuid.uuidString },
            nextAnchor: try newAnchor.map(HealthCodec.encodeAnchor))
          Self.onMain(completion, .success(result))
        } catch {
          Self.onMain(completion, .failure(Self.wrap(error)))
        }
      }
      store.execute(query)
    } catch {
      completion(.failure(Self.wrap(error)))
    }
  }

  // MARK: Writing / deleting

  func save(_ requests: [HkSaveRequest], completion: @escaping (Result<[String], Error>) -> Void) {
    do {
      try ensureAvailable()
      guard !requests.isEmpty else { return completion(.success([])) }
      let objects = try requests.map(HealthCodec.makeObject)
      store.save(objects) { success, error in
        if let error = error { return Self.onMain(completion, .failure(Self.wrap(error))) }
        guard success else {
          return Self.onMain(completion, .failure(PigeonError(code: "healthkit_error", message: "save failed", details: nil)))
        }
        Self.onMain(completion, .success(objects.map { $0.uuid.uuidString }))
      }
    } catch {
      completion(.failure(Self.wrap(error)))
    }
  }

  /// Deletes only objects written by this app (HealthKit allows nothing else).
  /// For blood pressure the correlation and both children are deleted.
  func delete(_ rawType: String, uuids: [String], completion: @escaping (Result<Int64, Error>) -> Void) {
    do {
      try ensureAvailable()
      let type = try HealthDataType.parse(rawType)
      let ids = Set(try uuids.map { raw -> UUID in
        guard let u = UUID(uuidString: raw) else {
          throw PigeonError(code: "invalid_argument", message: "Not a UUID: \(raw)", details: nil)
        }
        return u
      })
      guard !ids.isEmpty else { return completion(.success(0)) }
      let query = HKSampleQuery(
        sampleType: type.sampleType, predicate: HKQuery.predicateForObjects(with: ids),
        limit: HKObjectQueryNoLimit, sortDescriptors: nil
      ) { [weak self] _, results, error in
        guard let self = self else { return }
        if let error = error { return Self.onMain(completion, .failure(Self.wrap(error))) }
        var objects: [HKObject] = []
        for s in results ?? [] {
          objects.append(s)
          if let c = s as? HKCorrelation { objects.append(contentsOf: c.objects) }
        }
        if objects.isEmpty { return Self.onMain(completion, .success(0)) }
        let count = Int64(results?.count ?? 0)
        self.store.delete(objects) { success, error in
          if let error = error { return Self.onMain(completion, .failure(Self.wrap(error))) }
          Self.onMain(completion, .success(success ? count : 0))
        }
      }
      store.execute(query)
    } catch {
      completion(.failure(Self.wrap(error)))
    }
  }
}
