import Foundation
import XCTest
@testable import Veil

@MainActor final class VideoTests: XCTestCase {
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
