import XCTest

#if canImport(anchored_health_native)
  @testable import anchored_health_native
#endif

/// Directory for the local state of the daily totals: created in Application Support (here: a temp
/// base), marked `NSURLIsExcludedFromBackupKey`, plain names only. Pure Foundation, no HealthKit.
final class StateDirectoryTests: XCTestCase {

  private var base: URL!

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ah-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: base)
  }

  private func excluded(_ url: URL) throws -> Bool? {
    var u = url
    u.removeAllCachedResourceValues()
    return try u.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
  }

  func testCreatesTheDirectoryAndExcludesItFromBackups() throws {
    let dir = try StateDirectory.prepare(name: "anchored_health_state", base: base)
    var isDir: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
    XCTAssertTrue(isDir.boolValue)
    XCTAssertEqual(dir.lastPathComponent, "anchored_health_state")
    XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL.path, base.standardizedFileURL.path)
    XCTAssertEqual(try excluded(dir), true)
  }

  func testFilesCreatedLaterLiveInsideTheExcludedDirectory() throws {
    let dir = try StateDirectory.prepare(name: "s", base: base)
    let file = dir.appendingPathComponent("a.v")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    // The mark sits on the directory; a backup skips a marked directory with everything in it.
    XCTAssertEqual(try excluded(dir), true)
  }

  func testIsIdempotentAndKeepsTheContent() throws {
    let dir = try StateDirectory.prepare(name: "s", base: base)
    try "keep".write(to: dir.appendingPathComponent("k.v"), atomically: true, encoding: .utf8)
    let again = try StateDirectory.prepare(name: "s", base: base)
    XCTAssertEqual(again.path, dir.path)
    XCTAssertEqual(try String(contentsOf: again.appendingPathComponent("k.v"), encoding: .utf8), "keep")
    XCTAssertEqual(try excluded(again), true)
  }

  func testSetsTheMarkAgainWhenItWasLost() throws {
    var dir = try StateDirectory.prepare(name: "s", base: base)
    var values = URLResourceValues()
    values.isExcludedFromBackup = false
    try dir.setResourceValues(values)
    XCTAssertEqual(try excluded(dir), false)
    dir = try StateDirectory.prepare(name: "s", base: base)
    XCTAssertEqual(try excluded(dir), true)
  }

  func testCreatesMissingParents() throws {
    let deep = base.appendingPathComponent("Library/Application Support", isDirectory: true)
    let dir = try StateDirectory.prepare(name: "s", base: deep)
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    XCTAssertEqual(try excluded(dir), true)
  }

  func testOnlyPlainNamesAreAccepted() {
    for bad in ["", ".", "..", "a/b", "../x", "/abs", "a\\b", "a:b", "tab\there", "nl\nx", String(repeating: "x", count: 101)] {
      XCTAssertFalse(StateDirectory.isValidName(bad), bad)
      XCTAssertThrowsError(try StateDirectory.prepare(name: bad, base: base), bad) { error in
        XCTAssertEqual(error as? StateDirectory.Failure, .invalidName)
      }
    }
    for good in ["anchored_health_state", "state-1", "State.v2", "ü"] {
      XCTAssertTrue(StateDirectory.isValidName(good), good)
    }
    // nothing was created for a rejected name
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
  }

  func testDefaultBaseIsApplicationSupport() throws {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let name = "ah-test-\(UUID().uuidString)"
    let dir = try StateDirectory.prepare(name: name)
    defer { try? FileManager.default.removeItem(at: dir) }
    XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL.path, support.standardizedFileURL.path)
    XCTAssertEqual(try excluded(dir), true)
  }
}
