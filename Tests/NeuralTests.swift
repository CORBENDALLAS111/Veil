import Foundation
import XCTest
@testable import Veil

@MainActor final class NeuralTests: XCTestCase {
    func testOfflineModelUsesBundleWithoutCreatingDownloadStorage() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("unused-model-download-" + UUID().uuidString)
        let store = NeuralModelStore(parent: storage)
        let url = try await store.installedURL()
        XCTAssertEqual(url, NeuralManifest.resourceBundle.resourceURL?.appendingPathComponent("BundledVAE", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
        let active = await store.hasActiveDownloads()
        XCTAssertFalse(active)
    }
    func testNeuralQualityRejectsLostStructureAndAcceptsSmallChanges() throws {
        var source = [UInt8](repeating: 255, count: 512 * 512 * 4)
        for i in 0..<(512 * 512) {
            for c in 0..<3 { source[i * 4 + c] = UInt8(30 + (i + c * 37) % 180) }
        }
        var close = source
        for i in stride(from: 0, to: source.count, by: 4) {
            for c in 0..<3 { close[i + c] += 2 }
        }
        XCTAssertNoThrow(try NeuralQuality.validate(close, against: source, strength: 0.12))
        XCTAssertThrowsError(try NeuralQuality.validate([UInt8](repeating: 128, count: source.count), against: source, strength: 0.30))
    }

    func testCoreImageBridgeDoesNotFlipOrTransposePixels() throws {
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                              0, 0, 255, 255, 20, 40, 60, 255,
                              70, 90, 110, 255, 130, 150, 170, 255]
        let image = try NeuralRaster.image(bytes, width: 2, height: 3)
        let result = NeuralRaster.pixels(image)
        XCTAssertEqual(result.count, bytes.count)
        XCTAssertTrue(zip(bytes, result).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

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
        XCTAssertTrue(manifest.isFullyBundled)
        XCTAssertEqual(manifest.totalBytes, 0)
        XCTAssertEqual(manifest.files.filter { $0.url != nil }.reduce(0) { $0 + $1.bytes }, manifest.totalBytes)
        for component in ["TextEncoder", "VAEEncoder", "Unet", "VAEDecoder"] {
            XCTAssertTrue(manifest.files.contains { $0.path == "\(component).mlmodelc/weights/weight.bin" })
        }
        XCTAssertTrue(manifest.files.allSatisfy { !($0.url?.absoluteString.contains("/main/") ?? false) })
    }
}
