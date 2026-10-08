import Flutter
import Foundation

/// Plugin registration. Deliberately only sets up the Pigeon channel: no
/// HKHealthStore, no access to windows or the root view controller (UIScene-safe).
public class AnchoredHealthNativePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    AnchoredHealthApiSetup.setUp(
      binaryMessenger: registrar.messenger(), api: AnchoredHealthApiImpl(native: .shared))
  }
}

/// Thin forwarding of the Pigeon interface to `AnchoredHealthNative`.
final class AnchoredHealthApiImpl: AnchoredHealthApi {
  private let native: AnchoredHealthNative

  init(native: AnchoredHealthNative) { self.native = native }

  func isHealthDataAvailable() throws -> Bool { AnchoredHealthNative.isHealthDataAvailable }

  func supportedTypes() throws -> [String] { HealthDataType.allCases.map(\.rawValue) }

  func unitFor(type: String) throws -> String { try HealthDataType.parse(type).unitString }

  func requestStatus(
    read: [String], write: [String], characteristics: Bool, includeBloodPressureCorrelation: Bool,
    completion: @escaping (Result<HkRequestStatus, Error>) -> Void
  ) {
    native.requestStatus(
      read: read, write: write, characteristics: characteristics,
      includeCorrelation: includeBloodPressureCorrelation, completion: completion)
  }

  func requestAuthorization(
    read: [String], write: [String], characteristics: Bool, includeBloodPressureCorrelation: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    native.requestAuthorization(
      read: read, write: write, characteristics: characteristics,
      includeCorrelation: includeBloodPressureCorrelation, completion: completion)
  }

  func writeStatus(type: String) throws -> HkWriteStatus { try native.writeStatus(type) }

  func anchoredQuery(
    request: HkAnchoredQueryRequest, completion: @escaping (Result<HkAnchoredQueryResult, Error>) -> Void
  ) {
    native.anchoredQuery(request, completion: completion)
  }

  func save(samples: [HkSaveRequest], completion: @escaping (Result<[String], Error>) -> Void) {
    native.save(samples, completion: completion)
  }

  func delete(type: String, uuids: [String], completion: @escaping (Result<Int64, Error>) -> Void) {
    native.delete(type, uuids: uuids, completion: completion)
  }

  func characteristics() throws -> HkCharacteristics { try native.characteristics() }
}
