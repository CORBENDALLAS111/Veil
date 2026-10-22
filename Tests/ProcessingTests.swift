import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Veil

@MainActor
final class ProcessingTests: XCTestCase {
    func testWaveletRoundTripForOddAndTinyDimensions() throws {
        for (width, height) in [(1, 1), (1, 9), (2, 3), (7, 9), (32, 24)] {
            var pixels = (0..<(width * height * 4)).map { UInt8(($0 * 71 + 13) % 256) }
            let original = pixels
            try WaveletDenoiser.reduce(pixels: &pixels, width: width, height: height, threshold: 0)
            XCTAssertEqual(pixels, original, "Lossless transform round trip failed for \(width)×\(height)")
        }
    }

    func testSuppressesSmallHighFrequencySignalWhilePreservingAlphaAndDC() throws {
        let width = 32
        var pixels = [UInt8](repeating: 0, count: width * width * 4)
        for y in 0..<width {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let value: UInt8 = (x + y) % 2 == 0 ? 127 : 129
                for c in 0..<3 { pixels[i + c] = value }
                pixels[i + 3] = UInt8((x * 7 + y * 11) % 256)
            }
        }
        let original = pixels
        try WaveletDenoiser.reduce(pixels: &pixels, width: width, height: width, threshold: 3)
        for i in 0..<(width * width) {
            XCTAssertEqual(pixels[i * 4], 128)
            XCTAssertEqual(pixels[i * 4 + 3], original[i * 4 + 3])
        }
    }

    func testStrongEdgesArePreserved() throws {
        var pixels = [UInt8](repeating: 255, count: 16 * 16 * 4)
        for y in 0..<16 {
            for x in 0..<8 {
                for c in 0..<3 { pixels[(y * 16 + x) * 4 + c] = 0 }
            }
        }
        let original = pixels
        try WaveletDenoiser.reduce(pixels: &pixels, width: 16, height: 16, threshold: 5)
        XCTAssertEqual(pixels, original)
    }

    func testOddSizedConstantImageDoesNotDevelopBorderArtifacts() throws {
        var pixels: [UInt8] = Array(repeating: [77, 128, 201, 123] as [UInt8], count: 7 * 9).flatMap { $0 }
        let original = pixels
        try WaveletDenoiser.reduce(pixels: &pixels, width: 7, height: 9, threshold: 5)
        XCTAssertEqual(pixels, original)
    }

    func testRejectsCorruptInput() async {
        let processor = PhotoProcessor()
        do {
            _ = try await processor.load(Data("not a photo".utf8))
            XCTFail("Corrupt data must fail before rendering")
        } catch { XCTAssertTrue(error is ProcessingError) }
    }

    func testMetadataOnlyExportDropsProvenanceWithoutRunningTheNoiseFilter() async throws {
        let processor = PhotoProcessor()
        let input = makePhoto(metadata: true)
        let photo = try await processor.load(input)
        let result = try await processor.stripMetadata(photo, format: .png)
        XCTAssertEqual(result.width, photo.width)
        XCTAssertEqual(result.height, photo.height)
        XCTAssertFalse(String(decoding: result.data, as: UTF8.self).contains("PRIVATE-CAMERA"))
        let container = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary as String])
    }

    func testOrientsImageAndDropsSourceMetadata() async throws {
        let processor = PhotoProcessor()
        let photo = try await processor.load(makePhoto(orientation: 6, metadata: true))
        XCTAssertEqual(photo.width, 48)
        XCTAssertEqual(photo.height, 64)
        let result = try await processor.process(photo, strength: .balanced, format: .png)
        XCTAssertEqual(result.width, photo.width)
        XCTAssertEqual(result.height, photo.height)
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        // ImageIO synthesizes ColorSpace/PixelXDimension/PixelYDimension in a
        // new container. Those describe the output; source comments must not survive.
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifUserComment as String])
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary as String])
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int ?? 1, 1)
        XCTAssertFalse(String(decoding: result.data, as: UTF8.self).contains("PRIVATE-CAMERA"))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
        let pixels = try rgba(image)
        // Top-left of EXIF-right image is bottom-left (green) of the source.
        let pixel = (5 * image.width + 5) * 4
        XCTAssertLessThan(pixels[pixel], 25)
        XCTAssertGreaterThan(pixels[pixel + 1], 220)
        XCTAssertLessThan(pixels[pixel + 2], 25)
    }

    func testJPEGOutputIsValidAndMaintainsDimensions() async throws {
        let processor = PhotoProcessor()
        let photo = try await processor.load(makePhoto())
        let result = try await processor.process(photo, strength: .strong, format: .jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        XCTAssertFalse(result.preview.isEmpty)
    }

    func testCancellationDoesNotReturnAnExport() async throws {
        let processor = PhotoProcessor()
        let photo = try await processor.load(makePhoto())
        let task = Task { try await processor.process(photo, strength: .balanced, format: .png) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task must not yield an export") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPNGPreservesTransparencyAndJPEGCompositesOnWhite() async throws {
        let pixels: [UInt8] = Array(repeating: [0, 255, 0, 128] as [UInt8], count: 16 * 16).flatMap { $0 }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let input = NSMutableData()
        let destination = CGImageDestinationCreateWithData(input, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let processor = PhotoProcessor()
        let photo = try await processor.load(input as Data)
        XCTAssertTrue(photo.hasAlpha)
        let png = try await processor.process(photo, strength: .balanced, format: .png)
        let pngSource = try XCTUnwrap(CGImageSourceCreateWithData(png.data as CFData, nil))
        let pngPixels = try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(pngSource, 0, nil)))
        XCTAssertEqual(Double(pngPixels[3]), 128, accuracy: 1)
        XCTAssertEqual(Double(pngPixels[1]), 128, accuracy: 2) // premultiplied readback
        let jpeg = try await processor.process(photo, strength: .balanced, format: .jpeg)
        let jpegSource = try XCTUnwrap(CGImageSourceCreateWithData(jpeg.data as CFData, nil))
        let jpegPixels = try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(jpegSource, 0, nil)))
        XCTAssertEqual(Double(jpegPixels[0]), 127, accuracy: 4)
        XCTAssertEqual(Double(jpegPixels[1]), 255, accuracy: 4)
        XCTAssertEqual(Double(jpegPixels[2]), 127, accuracy: 4)
        XCTAssertEqual(jpegPixels[3], 255)
    }

    private func makePhoto(orientation: Int = 1, metadata: Bool = false) -> Data {
        var pixels = [UInt8](repeating: 255, count: 64 * 48 * 4)
        for y in 0..<48 {
            for x in 0..<64 {
                let rgb: [UInt8] = y < 24 ? (x < 32 ? [255, 0, 0] : [0, 0, 255]) : (x < 32 ? [0, 255, 0] : [255, 255, 0])
                for c in 0..<3 { pixels[(y * 64 + x) * 4 + c] = rgb[c] }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 64, height: 48, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64 * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1]
        if metadata {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 53.3, kCGImagePropertyGPSLatitudeRef: "N"]
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: "PRIVATE-CAMERA"]
            properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCObjectName: "PRIVATE-CAMERA"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try output.withUnsafeMutableBytes { storage in
            let ctx = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return output
    }
}
