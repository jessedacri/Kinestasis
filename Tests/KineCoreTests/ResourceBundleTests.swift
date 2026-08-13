import XCTest
@testable import KineCore

final class ResourceBundleTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResourceBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tmp)
    }

    // The 0.1.0 launch crash: the bundle lives only in Contents/Resources
    // of the packaged .app, which the generated Bundle.module accessor
    // (app root + dev .build path only) never checks.
    func testFindsBundleInPackagedResourcesLayout() throws {
        let appRoot = tmp.appendingPathComponent("Fake.app", isDirectory: true)
        let resources = appRoot.appendingPathComponent("Contents/Resources", isDirectory: true)
        let bundleDir = resources.appendingPathComponent("Kinestasis_KineApp.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let found = ResourceBundle.locate(
            named: "Kinestasis_KineApp.bundle",
            searching: [resources, appRoot])
        XCTAssertEqual(found?.bundleURL.standardizedFileURL, bundleDir.standardizedFileURL)
    }

    func testFindsBundleNextToExecutableForDevBuilds() throws {
        let binDir = tmp.appendingPathComponent("release", isDirectory: true)
        let bundleDir = binDir.appendingPathComponent("Kinestasis_KineApp.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let found = ResourceBundle.locate(
            named: "Kinestasis_KineApp.bundle",
            searching: [binDir, binDir])
        XCTAssertEqual(found?.bundleURL.standardizedFileURL, bundleDir.standardizedFileURL)
    }

    func testMissingBundleReturnsNilInsteadOfTrapping() {
        let found = ResourceBundle.locate(
            named: "Kinestasis_KineApp.bundle",
            searching: [tmp, nil, tmp.appendingPathComponent("nope")])
        XCTAssertNil(found)
    }
}
