import XCTest
@testable import Veil

final class ExportTests: XCTestCase {
    func testGuestDetectionDoesNotDependOnSpoofedBundleIdentifier() {
        XCTAssertTrue(ExportEnvironment.usesSystemExport(environment: ["LC_HOME_PATH": "/host/container"], arguments: []))
        XCTAssertFalse(ExportEnvironment.usesSystemExport(environment: ["HOME": "/app/container"], arguments: []))
        XCTAssertFalse(ExportEnvironment.usesSystemExport(environment: ["LC_HOME_PATH": ""], arguments: []))
    }
}
