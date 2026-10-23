import CoreGraphics
import Foundation
import XCTest
@testable import Veil

@MainActor final class PatternTests: XCTestCase {
    func testConstantAndTinyImagesStayExactIncludingAlpha() throws {
        for (w, h) in [(1, 1), (1, 9), (7, 9), (257, 131)] {
            var pixels = Array(repeating: [77, 128, 201, 255] as [UInt8], count: w * h).flatMap { $0 }
            let original = pixels
            try PatternProcessor.filter(&pixels, width: w, height: h, strength: .strong)
            XCTAssertEqual(pixels, original, "Constant image developed a boundary artifact")
        }
    }

    func testSyntheticBandIsAttenuatedWithoutTileSeams() throws {
        let width = 513, height = 259
        var pixels = sine(width: width, height: height)
        let original = pixels
        try PatternProcessor.filter(&pixels, width: width, height: height, strength: .strong)
        var before: Double = 0, after: Double = 0
        for y in 32..<(height - 32) {
            for x in 32..<(width - 32) {
                let p = (y * width + x) * 4
                before += pow(Double(original[p]) - 128, 2)
                after += pow(Double(pixels[p]) - 128, 2)
                if x > 32 { XCTAssertLessThanOrEqual(abs(Int(pixels[p]) - Int(pixels[p - 4])), 3) }
            }
        }
        XCTAssertLessThan(after, before * 0.3, "Frequency filter must actually attenuate the test band")
    }

    func testProtectedTextRectAndEdgesStayExactAndChangesAreBounded() throws {
        let width = 291, height = 279
        for strength in ProcessingStrength.allCases {
            var pixels = sine(width: width, height: height)
            let rect = CGRect(x: 41, y: 35, width: 96, height: 49)
            for y in 0..<height {
                for x in 200..<width {
                    let p = (y * width + x) * 4
                    for c in 0..<3 { pixels[p + c] = x < 220 ? 0 : 255 }
                }
            }
            let original = pixels
            try PatternProcessor.filter(&pixels, width: width, height: height, strength: strength, protectedRects: [rect])
            for y in 0..<height {
                for x in 0..<width {
                    let p = (y * width + x) * 4
                    XCTAssertEqual(pixels[p + 3], original[p + 3])
                    for c in 0..<3 {
                        XCTAssertLessThanOrEqual(abs(Int(pixels[p + c]) - Int(original[p + c])), Int(strength.pixelLimit))
                        if rect.insetBy(dx: -16, dy: -16).contains(CGPoint(x: x, y: y)) || (190...245).contains(x) {
                            XCTAssertEqual(pixels[p + c], original[p + c])
                        }
                    }
                }
            }
        }
    }

    func testTransparencyAndDeterminism() throws {
        var first = sine(width: 65, height: 37)
        for p in stride(from: 0, to: first.count, by: 8) { first[p + 3] = 128 }
        let original = first
        var second = first
        try PatternProcessor.filter(&first, width: 65, height: 37, strength: .balanced)
        try PatternProcessor.filter(&second, width: 65, height: 37, strength: .balanced)
        XCTAssertEqual(first, second)
        for p in stride(from: 0, to: first.count, by: 8) {
            XCTAssertEqual(Array(first[p..<(p + 4)]), Array(original[p..<(p + 4)]))
        }
    }

    private func sine(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8((128 + 4 * sin(2 * Double.pi * Double(x) / 24)).rounded())
                for c in 0..<3 { pixels[(y * width + x) * 4 + c] = value }
            }
        }
        return pixels
    }
}
