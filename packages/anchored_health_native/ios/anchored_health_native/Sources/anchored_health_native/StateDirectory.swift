import Foundation

/// Directory for the engine's local state of the daily totals (per-day values,
/// UUID -> day index). That is health data, so it lives **outside the device and
/// iCloud backup**: a directory in Application Support with
/// `NSURLIsExcludedFromBackupKey`, whose contents are excluded with it
/// (SharedPreferences cannot be excluded). Pure Foundation, testable without
/// HealthKit.
enum StateDirectory {
  enum Failure: Error, Equatable {
    case invalidName
    case notExcluded
  }

  /// A plain directory name: no separators, no dot names, no control characters.
  static func isValidName(_ name: String) -> Bool {
    if name.isEmpty || name.utf8.count > 100 { return false }
    if name == "." || name == ".." { return false }
    if name.contains("/") || name.contains("\\") || name.contains(":") { return false }
    return !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  /// `<base>/<name>` (base: Application Support), created if missing and marked as excluded
  /// from backups. Idempotent: the mark is set again on every call. Throws
  /// `Failure.notExcluded` if the mark cannot be read back as set.
  @discardableResult
  static func prepare(name: String, base: URL? = nil, fileManager: FileManager = .default) throws -> URL {
    guard isValidName(name) else { throw Failure.invalidName }
    let root =
      try base
      ?? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var dir = root.appendingPathComponent(name, isDirectory: true)
    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try dir.setResourceValues(values)
    dir.removeAllCachedResourceValues()
    guard try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    else { throw Failure.notExcluded }
    return dir
  }
}
