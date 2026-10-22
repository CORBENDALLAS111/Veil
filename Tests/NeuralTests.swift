import Foundation
import XCTest
@testable import Veil

final class NeuralTests: XCTestCase {
    func testOverlappingTilesReconstructAnAsymmetricOpaqueRasterWithoutSeams() throws {
        for (width, height) in [(1, 1), (511, 513), (720, 1280)] {
            let plan = TilePlan(width: width, height: height)
            var original = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    original[i] = UInt8(x % 251)
                    original[i + 1] = UInt8(y % 241)
                    original[i + 2] = UInt8((x + 3 * y) % 239)
                }
            }
            var accumulator = TileAccumulator(plan: plan, original: original)
            for origin in plan.origins {
                accumulator.append(accumulator.input(x: origin.x, y: origin.y), x: origin.x, y: origin.y)
            }
            XCTAssertEqual(try accumulator.finish(), original, "Uncovered or distorted pixels at \(width)×\(height)")
        }
    }

    func testRegeneratedRGBNeverIncludesOriginalDetailAndRetainsAlpha() throws {
        let plan = TilePlan(width: 521, height: 703)
        var source = [UInt8](repeating: 211, count: plan.width * plan.height * 4)
        for i in stride(from: 0, to: source.count, by: 4) { source[i + 3] = UInt8((i / 4) % 256) }
        var accumulator = TileAccumulator(plan: plan, original: source)
        let black = [UInt8](repeating: 0, count: 512 * 512 * 4)
        for origin in plan.origins { accumulator.append(black, x: origin.x, y: origin.y) }
        let output = try accumulator.finish()
        var expected = [UInt8](repeating: 0, count: source.count)
        for i in stride(from: 0, to: output.count, by: 4) {
            expected[i + 3] = source[i + 3]
        }
        XCTAssertEqual(output, expected)
    }

    func testIncompleteTileCoverageFailsInsteadOfReturningAnOriginalRegion() {
        let plan = TilePlan(width: 720, height: 960)
        let accumulator = TileAccumulator(plan: plan, original: [UInt8](repeating: 255, count: 720 * 960 * 4))
        XCTAssertThrowsError(try accumulator.finish())
    }

    func testModelManifestIsCompleteAndPinned() throws {
        let manifest = try NeuralManifest.bundled()
        XCTAssertEqual(manifest.files.count, 22)
        XCTAssertEqual(manifest.files.reduce(0) { $0 + $1.bytes }, manifest.totalBytes)
        for component in ["TextEncoder", "VAEEncoder", "Unet", "VAEDecoder"] {
            XCTAssertTrue(manifest.files.contains { $0.path == "\(component).mlmodelc/weights/weight.bin" })
        }
        XCTAssertTrue(manifest.files.allSatisfy { !$0.url.absoluteString.contains("/main/") })
    }
}
