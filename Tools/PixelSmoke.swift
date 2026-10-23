import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main enum PixelSmoke {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 1801, height = 701
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8((128 + 4 * sin(2 * Double.pi * Double(x) / 24)).rounded())
                for c in 0..<3 { bytes[(y * width + x) * 4 + c] = value }
            }
        }
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress!, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: PixelRaster.colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (text, size, y) in [("DETAILS 0123456789", 64.0, 520.0),
                                    ("Veil TEXT stays intact", 32.0, 400.0),
                                    ("Мелкий текст и детали", 24.0, 310.0)] {
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.04, alpha: 1)]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: 80, y: y)
                CTLineDraw(line, context)
            }
        }
        let input = try PixelRaster.image(bytes, width: width, height: height)
        let before = try PatternProcessor.recognizeText(input)
        precondition(before.contains(where: { $0.text.contains("0123456789") }), "Real OCR did not recognize fixture text")
        precondition(before.contains(where: { $0.text.contains("TEXT") }), "Real OCR missed the smaller text")
        let start = Date()
        let output = try PatternProcessor.process(input, strength: .strong) { _, _ in }
        let elapsed = Date().timeIntervalSince(start)
        precondition(output.width == width && output.height == height && width > 1536)
        let first = PixelRaster.pixels(input), last = PixelRaster.pixels(output)
        var maxDelta = 0, changed = 0, exactProtected = 0
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                let protected = before.contains { $0.rect.insetBy(dx: -3, dy: -3).contains(CGPoint(x: x, y: y)) }
                for c in 0..<3 {
                    let delta = abs(Int(first[p + c]) - Int(last[p + c]))
                    maxDelta = max(maxDelta, delta)
                    if delta > 0 { changed += 1 }
                    if protected { precondition(delta == 0, "Recognized text region changed"); exactProtected += 1 }
                }
                precondition(first[p + 3] == last[p + 3])
            }
        }
        precondition(changed > 10000 && maxDelta <= 10 && exactProtected > 1000)
        // Verify source raster orientation, alpha and channel order separately.
        let asymmetric: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 128, 200, 100, 50, 255]
        let bridge = PixelRaster.pixels(try PixelRaster.image(asymmetric, width: 2, height: 2))
        for i in asymmetric.indices { precondition(abs(Int(bridge[i]) - Int(asymmetric[i])) <= 1, "Raster bridge changed layout") }
        for (name, image) in [("input.png", input), ("output.png", output)] {
            let target = directory.appendingPathComponent(name)
            let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
            let source = CGImageSourceCreateWithURL(target as CFURL, nil)!
            let readback = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            precondition(PixelRaster.pixels(readback) == PixelRaster.pixels(image), "PNG must round trip losslessly")
        }
        let after = try PatternProcessor.recognizeText(output)
        let metrics: [String: Any] = ["width": width, "height": height, "maxRGBDelta": maxDelta,
            "changedChannels": changed, "protectedChannelsExact": exactProtected,
            "seconds": elapsed, "textBefore": before.map(\.text), "textAfter": after.map(\.text),
            "synthIDVerified": false]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("metrics.json"))
        print("PIXEL CHECK PASSED: \(width)×\(height), max RGB delta \(maxDelta), text \(before.map(\.text)), \(elapsed)s")
    }
}
