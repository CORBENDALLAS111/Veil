import Foundation
import XCTest
@testable import Veil

@MainActor final class VideoTests: XCTestCase {
    func testVideoUpscalePreservesAspectRatioAndNeverDownsizes() {
        let portrait = VideoResolution.fullHD.dimensions(width: 720, height: 1280)
        XCTAssertEqual(portrait.width, 1080); XCTAssertEqual(portrait.height, 1920)
        let landscape = VideoResolution.fourK.dimensions(width: 1280, height: 720)
        XCTAssertEqual(landscape.width, 3840); XCTAssertEqual(landscape.height, 2160)
        let large = VideoResolution.fullHD.dimensions(width: 3840, height: 2160)
        XCTAssertEqual(large.width, 3840); XCTAssertEqual(large.height, 2160)
    }

    func testGentleBlockCleanupKeepsStrongContoursAndIsBounded() throws {
        let w = 33, h = 19
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let value: UInt8 = x < 16 ? 40 : 200
            for c in 0..<3 { pixels[(y * w + x) * 4 + c] = value }
        } }
        let before = pixels
        try VideoUpscaler.cleanPixels(&pixels, width: w, height: h)
        XCTAssertEqual(pixels, before, "Contrast boundaries must not receive smoothing halos")
        for p in stride(from: 0, to: pixels.count, by: 4) {
            let v: UInt8 = ((p / 4) % 8) < 4 ? 128 : 132
            for c in 0..<3 { pixels[p + c] = v }
        }
        let noisy = pixels
        try VideoUpscaler.cleanPixels(&pixels, width: w, height: h)
        XCTAssertTrue(zip(pixels, noisy).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    func testTemporalCorrectionResetsAtMotionAndNewTextMasks() {
        var stabilizer = VideoCorrectionStabilizer()
        let source: [UInt8] = [100, 120, 140, 255, 100, 120, 140, 255]
        var first: [UInt8] = [104, 124, 144, 255, 104, 124, 144, 255]
        stabilizer.apply(&first, source: source)
        XCTAssertEqual(first[0], 104)
        var masked = source
        stabilizer.apply(&masked, source: source)
        XCTAssertEqual(masked, source, "History must not change newly protected text")
        let cut: [UInt8] = [40, 60, 80, 255, 40, 60, 80, 255]
        var candidate: [UInt8] = [37, 57, 77, 255, 37, 57, 77, 255]
        let expected = candidate
        stabilizer.apply(&candidate, source: cut)
        XCTAssertEqual(candidate, expected, "Scene cuts must not carry old-frame pixels")
    }

    func testCancellationRemovesPartialVideoFile() async throws {
        let url = try await VideoFixture.make()
        defer { VideoFiles.remove(url) }
        let processor = VideoProcessor()
        let source = try await processor.load(url)
        let initial = Set(try FileManager.default.contentsOfDirectory(at: VideoFiles.directory, includingPropertiesForKeys: nil))
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            return try await processor.process(source, mode: .pattern, strength: .strong) { value, _ in continuation.yield(value) }
        }
        for await value in stream where value > 0 {
            task.cancel()
            break
        }
        continuation.finish()
        do { _ = try await task.value; XCTFail("Cancelled video must not become an export") }
        catch { XCTAssertTrue(error is CancellationError) }
        let final = Set(try FileManager.default.contentsOfDirectory(at: VideoFiles.directory, includingPropertiesForKeys: nil))
        XCTAssertEqual(final, initial, "Cancelled writer left a partial video behind")
    }

    func testVideoImportRejectsInvalidFile() async throws {
        let url = try VideoFiles.destination()
        defer { VideoFiles.remove(url) }
        try Data("invalid movie".utf8).write(to: url)
        do { _ = try await VideoProcessor().load(url); XCTFail("Invalid file should be rejected") }
        catch { XCTAssertFalse(error is CancellationError) }
    }
}
