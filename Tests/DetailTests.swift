import CoreGraphics
import Foundation
import XCTest
@testable import Veil

@MainActor final class DetailTests: XCTestCase {
    func testFourKDimensionsAndOriginalResolution() {
        for (width, height) in [(611, 1087), (4032, 3024), (1, 1), (3840, 2160)] {
            let size = OutputResolution.fourK.dimensions(width: width, height: height)
            XCTAssertEqual(max(size.width, size.height), 3840)
            XCTAssertEqual(Double(size.width) / Double(size.height), Double(width) / Double(height), accuracy: 0.002)
            let original = OutputResolution.original.dimensions(width: width, height: height)
            XCTAssertEqual(original.width, width); XCTAssertEqual(original.height, height)
        }
    }

    func testMonotoneUpscaleHasNoRingingAndKeepsOrientation() throws {
        let source: [UInt8] = [20, 20, 20, 255, 20, 20, 20, 255, 210, 210, 210, 255, 210, 210, 210, 255]
        let output = try DetailResampler.resize(source, width: 4, height: 1, outputWidth: 137, outputHeight: 3)
        for y in 0..<3 {
            var previous = 20
            for x in 0..<137 {
                let p = (y * 137 + x) * 4
                XCTAssertGreaterThanOrEqual(Int(output[p]), previous)
                XCTAssertTrue((20...210).contains(output[p]))
                XCTAssertEqual(output[p], output[p + 1]); XCTAssertEqual(output[p], output[p + 2])
                XCTAssertEqual(output[p + 3], 255)
                previous = Int(output[p])
            }
        }
    }

    func testDownscaleAveragesAreaAndAlphaDoesNotBleed() throws {
        let checker: [UInt8] = [0, 0, 0, 255, 200, 200, 200, 255, 200, 200, 200, 255, 0, 0, 0, 255]
        XCTAssertEqual(try DetailResampler.resize(checker, width: 2, height: 2, outputWidth: 1, outputHeight: 1), [100, 100, 100, 255])
        let alpha: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 0]
        let scaled = try DetailResampler.resize(alpha, width: 2, height: 1, outputWidth: 31, outputHeight: 1)
        for p in stride(from: 0, to: scaled.count, by: 4) where scaled[p + 3] > 0 {
            XCTAssertEqual(scaled[p], 255); XCTAssertEqual(scaled[p + 1], 0); XCTAssertEqual(scaled[p + 2], 0)
        }
    }

    func testClarityIsBoundedAndProtectsTextTransparencyAndEdges() throws {
        let width = 64, height = 48
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let value: UInt8 = x < 32 ? ((x + y) % 2 == 0 ? 118 : 138) : 255
            for c in 0..<3 { bytes[(y * width + x) * 4 + c] = value }
        } }
        bytes[3] = 128
        let source = bytes, rect = CGRect(x: 8, y: 8, width: 12, height: 12)
        try GentleClarity.apply(&bytes, width: width, height: height, protectedRects: [rect])
        var changed = 0
        for y in 0..<height { for x in 0..<width {
            let p = (y * width + x) * 4
            XCTAssertEqual(bytes[p + 3], source[p + 3])
            for c in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(bytes[p + c]) - Int(source[p + c])), 1)
                if bytes[p + c] != source[p + c] { changed += 1 }
                if rect.contains(CGPoint(x: x, y: y)) || x == 31 || x == 32 || p == 0 { XCTAssertEqual(bytes[p + c], source[p + c]) }
            }
        } }
        XCTAssertGreaterThan(changed, 100)
    }

    func testResamplingHonorsCancellation() async throws {
        let task = Task {
            try DetailResampler.resize([255, 255, 255, 255], width: 1, height: 1, outputWidth: 3840, outputHeight: 3840)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled resampling returned output") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
