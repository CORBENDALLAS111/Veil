import CoreGraphics
import XCTest
@testable import Veil

@MainActor final class RippleTests: XCTestCase {
    func testPeriodicRippleFallsWithoutMovingTextEdgesOrColor() throws {
        let width = 257, height = 193, text = CGRect(x: 35, y: 30, width: 80, height: 30)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let noise = Int((4 * sin(2 * Double.pi * Double(x) / 16)).rounded())
            let base = x < 200 ? 120 : 210
            let p = (y * width + x) * 4
            bytes[p] = UInt8(base + noise); bytes[p + 1] = UInt8(base + noise + 5); bytes[p + 2] = UInt8(base + noise + 10)
        } }
        bytes[3] = 128
        let source = bytes
        try RippleReducer.apply(&bytes, width: width, height: height, protectedRects: [text])
        var before = 0.0, after = 0.0
        for y in 0..<height { for x in 0..<width {
            let p = (y * width + x) * 4
            XCTAssertEqual(bytes[p + 3], source[p + 3])
            for c in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(bytes[p + c]) - Int(source[p + c])), 3)
                if text.insetBy(dx: -8, dy: -8).contains(CGPoint(x: x, y: y)) || (198...201).contains(x) || p == 0 {
                    XCTAssertEqual(bytes[p + c], source[p + c])
                }
            }
            XCTAssertEqual(Int(bytes[p + 1]) - Int(bytes[p]), 5)
            XCTAssertEqual(Int(bytes[p + 2]) - Int(bytes[p]), 10)
            if y > 85 && y < 160 && x > 20 && x < 170 {
                before += pow(Double(source[p]) - 120, 2)
                after += pow(Double(bytes[p]) - 120, 2)
            }
        } }
        XCTAssertLessThan(after, before * 0.65, "The periodic calibration ripple must actually decrease")
    }

    func testFlatFieldsAndTinyAlphaImagesRemainExact() throws {
        for (w, h) in [(1, 1), (7, 9), (65, 33), (257, 131)] {
            var bytes = Array(repeating: [77, 128, 201, 255] as [UInt8], count: w * h).flatMap { $0 }
            let original = bytes
            try RippleReducer.apply(&bytes, width: w, height: h)
            XCTAssertEqual(bytes, original)
        }
    }

    func testCancellation() async throws {
        let task = Task {
            var bytes = [UInt8](repeating: 255, count: 512 * 512 * 4)
            try RippleReducer.apply(&bytes, width: 512, height: 512)
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled filtering succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
