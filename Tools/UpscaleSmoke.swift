@preconcurrency import AVFoundation
import CoreText
import CoreImage
import Foundation
import Metal

@main struct UpscaleSmoke {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let image = try artwork()
        try VideoSmoke.saveImage(image, output.appendingPathComponent("source-720p.png"))
        let source = PixelRaster.pixels(image)
        let regions = try PatternProcessor.recognizeText(image)
        var filters: [[String: Any]] = []
        for strength in ProcessingStrength.allCases {
            var before = source, after = source
            var started = Date()
            try BaselinePatternProcessor.filter(&before, width: image.width, height: image.height, strength: strength, protectedRects: regions.map(\.rect))
            let oldSeconds = Date().timeIntervalSince(started)
            started = Date()
            try PatternProcessor.filter(&after, width: image.width, height: image.height, strength: strength, protectedRects: regions.map(\.rect))
            let newSeconds = Date().timeIntervalSince(started)
            try VideoSmoke.require(before == after, "Pattern optimization changed 0.7 decoded pixels at \(strength)")
            filters.append(["strength": strength.rawValue, "legacySeconds": oldSeconds, "optimizedSeconds": newSeconds,
                            "speedup": oldSeconds / newSeconds, "identicalPixels": true])
        }
        let initStart = Date()
        let engine = VideoUpscaler()
        let initializationSeconds = Date().timeIntervalSince(initStart)
        if MTLCreateSystemDefaultDevice() != nil {
            try VideoSmoke.require(engine.backend == "Metal", "GPU initialization failed: \(engine.initializationError ?? "unknown")")
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let input = try engine.buffer(width: 1280, height: 720)
        context.render(CIImage(cgImage: image), to: input, bounds: CGRect(x: 0, y: 0, width: 1280, height: 720), colorSpace: PixelRaster.colorSpace)
        let raw = pixels(input)
        var scales: [[String: Any]] = []
        for size in [VideoResolution.fullHD, .fourK] {
            let dims = size.dimensions(width: 1280, height: 720)
            let target = try engine.buffer(width: dims.width, height: dims.height)
            var started = Date()
            let reference = try DetailResampler.resize(raw, width: 1280, height: 720, outputWidth: dims.width, outputHeight: dims.height)
            let cpuSeconds = Date().timeIntervalSince(started)
            // Warm command/pipeline caches separately from measured rendering.
            try engine.render(input, to: target, smoothBlocks: false)
            started = Date()
            for _ in 0..<3 { try engine.render(input, to: target, smoothBlocks: false) }
            let acceleratedSeconds = Date().timeIntervalSince(started) / 3
            let actual = pixels(target)
            let maximum = zip(reference, actual).map { abs(Int($0) - Int($1)) }.max() ?? 0
            try VideoSmoke.require(maximum <= 1, "GPU interpolation differs from bounded CPU reference by \(maximum) levels")
            let cg = try PixelRaster.image(actual, width: dims.width, height: dims.height)
            try VideoSmoke.saveImage(cg, output.appendingPathComponent("upscale-\(size.rawValue).png"))
            let text = try PatternProcessor.recognizeText(cg).map(\.text).joined(separator: " ")
            try VideoSmoke.require(text.contains("FLOW 2026"), "Upscaled label unreadable: \(text)")
            scales.append(["size": size.title, "width": dims.width, "height": dims.height, "cpuSeconds": cpuSeconds,
                           "acceleratedSeconds": acceleratedSeconds, "speedup": cpuSeconds / acceleratedSeconds,
                           "maximumDifferenceFromCPU": maximum, "text": text])
        }
        let cleaned = try engine.buffer(width: 1280, height: 720)
        try engine.render(input, to: cleaned, smoothBlocks: true)
        let cleanedBytes = pixels(cleaned)
        let delta = zip(raw, cleanedBytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        try VideoSmoke.require(delta <= 1, "Block cleanup exceeded its one-level bound")
        try await videoChecks(output)
        let report: [String: Any] = ["backend": engine.backend, "device": MTLCreateSystemDefaultDevice()?.name ?? "none",
            "initializationSeconds": initializationSeconds, "filterParityAndTimings": filters, "scaling": scales,
            "maximumCleanupDelta": delta, "officialSynthIDTested": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("performance.json"))
        print(String(decoding: data, as: UTF8.self))
    }

    static func videoChecks(_ output: URL) async throws {
        let sourceURL = try await VideoFixture.make(width: 1280, height: 720, frameCount: 3)
        defer { VideoFiles.remove(sourceURL) }
        let processor = VideoProcessor()
        let source = try await processor.load(sourceURL)
        let sourceAudio = try await VideoSmoke.packets(sourceURL, .audio)
        let sourceVideo = try await VideoSmoke.packets(sourceURL, .video)
        var cases: [[String: Any]] = []
        for size in [VideoResolution.fullHD, .fourK] {
            let result = try await processor.process(source, mode: .upscale, strength: .balanced, resolution: size, smoothBlocks: true)
            defer { VideoFiles.remove(result.url) }
            let audio = try await VideoSmoke.packets(result.url, .audio), video = try await VideoSmoke.packets(result.url, .video)
            let dimensions = size.dimensions(width: 1280, height: 720)
            try VideoSmoke.require(audio.digest == sourceAudio.digest && audio.times == sourceAudio.times, "Upscale changed audio")
            try VideoSmoke.require(video.times == sourceVideo.times && result.frames == 3, "Upscale changed video timing")
            try VideoSmoke.require(result.width == dimensions.width && result.height == dimensions.height, "Wrong export size")
            let image = try await VideoSmoke.firstImage(result.url)
            let text = try PatternProcessor.recognizeText(image).map(\.text).joined(separator: " ")
            try VideoSmoke.require(text.contains("2026"), "Text lost during upscale video encoding")
            try FileManager.default.copyItem(at: result.url, to: output.appendingPathComponent("video-\(size.rawValue).mov"))
            cases.append(["mode": "upscale", "size": size.title, "seconds": result.elapsed, "frames": result.frames,
                          "width": result.width, "height": result.height, "audioUnchanged": true, "timingsUnchanged": true, "ocr": text])
        }
        // Same 720p clip, full pattern + 4K pipeline before/after optimization.
        let legacy = try await BaselineVideoProcessor().process(source, mode: .pattern, strength: .balanced, resolution: .fourK)
        defer { VideoFiles.remove(legacy.url) }
        let current = try await processor.process(source, mode: .pattern, strength: .balanced, resolution: .fourK)
        defer { VideoFiles.remove(current.url) }
        cases.append(["mode": "pattern-and-4K", "legacySeconds": legacy.elapsed, "optimizedSeconds": current.elapsed,
                      "speedup": legacy.elapsed / current.elapsed, "frames": current.frames])
        let json = try JSONSerialization.data(withJSONObject: cases, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("video-performance.json"))
    }

    static func pixels(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var output = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let src = y * stride + x * 4, dst = (y * w + x) * 4
            output[dst] = pointer[src + 2]; output[dst + 1] = pointer[src + 1]
            output[dst + 2] = pointer[src]; output[dst + 3] = pointer[src + 3]
        } }
        return output
    }

    static func artwork() throws -> CGImage {
        let w = 1280, h = 720
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let v = 128 + Int(6 * sin(Double(x) * .pi / 12) + 4 * cos(Double(y) * .pi / 17))
            let p = (y * w + x) * 4
            for c in 0..<3 { bytes[p + c] = UInt8(clamping: v + c * 10) }
        } }
        let base = try PixelRaster.image(bytes, width: w, height: h)
        guard let drawing = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: PixelRaster.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw VideoError.write }
        drawing.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        drawing.setFillColor(CGColor(gray: 0.08, alpha: 1)); drawing.fill(CGRect(x: 50, y: 530, width: 1180, height: 145))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 38, nil)
        let text = NSAttributedString(string: "FLOW 2026  •  SALE 19.99", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
        drawing.textPosition = CGPoint(x: 80, y: 590); CTLineDraw(CTLineCreateWithAttributedString(text), drawing)
        guard let image = drawing.makeImage() else { throw VideoError.write }
        return image
    }
}
