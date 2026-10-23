import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Uses the same processor as the IPA, on public fixtures. Quality statistics
/// are never converted into watermark verdicts or generic AI-origin scores.
@main enum WatermarkBench {
    struct Variant: Sendable {
        let name: String
        let strength: ProcessingStrength
        var clarity = false
        var resolution: OutputResolution = .original
        var format: ExportFormat = .png
    }

    static func main() async throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let variants = [Variant(name: "gentle", strength: .gentle),
                        Variant(name: "balanced", strength: .balanced),
                        Variant(name: "strong", strength: .strong),
                        Variant(name: "strong-clarity", strength: .strong, clarity: true),
                        Variant(name: "strong-4k", strength: .strong, resolution: .fourK),
                        Variant(name: "strong-jpeg", strength: .strong, format: .jpeg)]
        let processor = PhotoProcessor()
        let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var records: [[String: Any]] = []
        for file in files {
            let data = try Data(contentsOf: file)
            let photo = try await processor.load(data)
            let directory = output.appendingPathComponent(file.deletingPathExtension().lastPathComponent, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = directory.appendingPathComponent("original." + file.pathExtension)
            try data.write(to: original)
            let baseline = try await processor.stripMetadata(photo, format: .png)
            try baseline.data.write(to: directory.appendingPathComponent("metadata-only.png"))
            let baseImage = try decode(baseline.data)
            let sourcePixels = PixelRaster.pixels(baseImage)
            let sourceText = try PatternProcessor.recognizeText(baseImage)
            records.append(["source": file.lastPathComponent, "variant": "metadata-only", "status": "produced",
                            "inputSHA256": hash(data), "outputSHA256": hash(baseline.data),
                            "original": directory.lastPathComponent + "/" + original.lastPathComponent,
                            "output": directory.lastPathComponent + "/metadata-only.png",
                            "width": baseline.width, "height": baseline.height,
                            "sourceText": sourceText.map(\.text), "outputText": sourceText.map(\.text),
                            "officialOriginalVerdict": NSNull(), "officialOutputVerdict": NSNull(),
                            "synthIDRemovalVerified": false,
                            "quality": metrics(sourcePixels, sourcePixels, width: baseline.width, height: baseline.height,
                                               protectedRects: sourceText.map(\.rect))])
            for variant in variants {
                print("PROCESSING \(file.lastPathComponent) \(variant.name)")
                let resultFile = directory.appendingPathComponent(variant.name + "." + variant.format.fileExtension)
                var record: [String: Any] = ["source": file.lastPathComponent, "variant": variant.name,
                    "inputSHA256": hash(data), "sourceText": sourceText.map(\.text),
                    "original": directory.lastPathComponent + "/" + original.lastPathComponent,
                    "output": directory.lastPathComponent + "/" + resultFile.lastPathComponent,
                    "officialOriginalVerdict": NSNull(), "officialOutputVerdict": NSNull(),
                    "synthIDRemovalVerified": false]
                do {
                    let result = try await processor.process(photo, strength: variant.strength, format: variant.format,
                                                             clarity: variant.clarity, resolution: variant.resolution)
                    try result.data.write(to: resultFile)
                    let image = try decode(result.data)
                    let after = try PatternProcessor.recognizeText(image)
                    record["status"] = "produced"
                    record["outputSHA256"] = hash(result.data)
                    record["seconds"] = result.elapsed
                    record["width"] = result.width; record["height"] = result.height
                    record["outputText"] = after.map(\.text)
                    if result.width == photo.width && result.height == photo.height {
                        record["quality"] = metrics(sourcePixels, PixelRaster.pixels(image), width: result.width,
                                                    height: result.height, protectedRects: sourceText.map(\.rect))
                    } else { record["quality"] = ["pixelComparison": "not_comparable_after_resize"] }
                    print("PRODUCED \(file.lastPathComponent) \(variant.name) \(result.width)x\(result.height) \(result.elapsed)s")
                } catch {
                    record["status"] = "rejected"
                    record["error"] = error.localizedDescription
                    print("REJECTED \(file.lastPathComponent) \(variant.name): \(error.localizedDescription)")
                }
                records.append(record)
                // Persist partial progress if a later fixture fails.
                try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("results.json"))
            }
        }
        print("BENCHMARK COMPLETE: \(files.count) sources, \(records.count) variants; official verdicts NOT TESTED")
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ProcessingError.invalidImage }
        return image
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func metrics(_ source: [UInt8], _ result: [UInt8], width: Int, height: Int, protectedRects: [CGRect]) -> [String: Any] {
        var squared: Double = 0, absolute: Double = 0, changed = 0, maximum = 0, textChanged = 0
        var a = [Float](repeating: 0, count: width * height), b = a
        let rects = protectedRects.map { $0.insetBy(dx: -3, dy: -3) }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x, p = i * 4
                let text = rects.contains { $0.contains(CGPoint(x: x, y: y)) }
                var pixelChanged = false
                for c in 0..<3 {
                    let delta = abs(Int(source[p + c]) - Int(result[p + c]))
                    squared += Double(delta * delta); absolute += Double(delta)
                    maximum = max(maximum, delta)
                    if delta > 0 { pixelChanged = true }
                }
                if pixelChanged { changed += 1; if text { textChanged += 1 } }
                a[i] = 0.299 * Float(source[p]) + 0.587 * Float(source[p + 1]) + 0.114 * Float(source[p + 2])
                b[i] = 0.299 * Float(result[p]) + 0.587 * Float(result[p + 1]) + 0.114 * Float(result[p + 2])
            }
        }
        var before: Double = 0, after: Double = 0
        if width > 1 && height > 1 {
            for y in 0..<(height - 1) { for x in 0..<(width - 1) {
                let i = y * width + x
                before += Double(pow(a[i + 1] - a[i], 2) + pow(a[i + width] - a[i], 2))
                after += Double(pow(b[i + 1] - b[i], 2) + pow(b[i + width] - b[i], 2))
            } }
        }
        let mse = squared / Double(width * height * 3)
        return ["meanAbsoluteRGBChange": absolute / Double(width * height * 3), "maximumRGBChange": maximum,
                "changedPixelPercent": 100 * Double(changed) / Double(width * height),
                "PSNR_dB": mse > 0 ? 10 * log10(255 * 255 / mse) as Any : "infinity",
                "gradientEnergyRatio": before > 0 ? after / before : 1,
                "protectedTextChangedPixels": textChanged]
    }
}
