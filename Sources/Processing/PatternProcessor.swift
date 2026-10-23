import Accelerate
import CoreGraphics
import Foundation
import Vision

/// A bounded, non-generative frequency filter. It is not a SynthID detector.
/// All sampling coordinates are integer source coordinates; no image is resized.
enum PatternProcessor {
    struct TextRegion: Sendable {
        let rect: CGRect
        let text: String
    }

    static func recognizeText(_ image: CGImage) throws -> [TextRegion] {
        try Task.checkCancellation()
        // Vision cannot reliably analyze tiny rasters; filtering still protects
        // their contrast edges. There are no recognized text boxes to claim.
        guard image.width >= 32, image.height >= 32 else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return TextRegion(rect: CGRect(x: box.minX * CGFloat(image.width),
                                           y: (1 - box.maxY) * CGFloat(image.height),
                                           width: box.width * CGFloat(image.width),
                                           height: box.height * CGFloat(image.height)), text: candidate.string)
        }
    }

    static func process(_ image: CGImage, strength: ProcessingStrength,
                        progress: @Sendable (Double, String) -> Void) throws -> CGImage {
        progress(0.02, "Защита текста…")
        // Fail closed if Vision fails: never silently process unprotected text.
        let regions = try recognizeText(image)
        var bytes = PixelRaster.pixels(image)
        try filter(&bytes, width: image.width, height: image.height, strength: strength,
                   protectedRects: regions.map(\.rect), progress: progress)
        try Task.checkCancellation()
        let output = try PixelRaster.image(bytes, width: image.width, height: image.height)
        progress(0.94, "Проверка текста…")
        if !regions.isEmpty {
            let after = try recognizeText(output)
            // OCR can vary even if pixels in its bounding box did not change.
            // Reject uncertainty instead of delivering potentially damaged text.
            for before in regions {
                guard after.contains(where: { candidate in
                    candidate.text == before.text && candidate.rect.intersects(before.rect)
                }) else { throw ProcessingError.textChanged }
            }
        }
        return output
    }

    static func filter(_ pixels: inout [UInt8], width: Int, height: Int,
                       strength: ProcessingStrength, protectedRects: [CGRect] = [],
                       progress: @Sendable (Double, String) -> Void = { _, _ in }) throws {
        guard width > 0, height > 0, pixels.count == width * height * 4 else {
            throw ProcessingError.invalidImage
        }
        try Task.checkCancellation()
        let side = 256, hop = 128, count = 256 * 256
        guard let setup = vDSP_create_fftsetup(8, FFTRadix(kFFTRadix2)) else {
            throw ProcessingError.encodeFailed
        }
        defer { vDSP_destroy_fftsetup(setup) }
        var luma = [Float](repeating: 0, count: width * height)
        for i in luma.indices {
            let p = i * 4
            luma[i] = 0.299 * Float(pixels[p]) + 0.587 * Float(pixels[p + 1]) + 0.114 * Float(pixels[p + 2])
        }
        // Bounding boxes refer to top-left raster coordinates, padded to cover
        // antialiasing and context just outside the recognized glyphs.
        let rects = protectedRects.map { $0.insetBy(dx: -4, dy: -4).integral }
        // Distance from protected content. Freeze a surrounding margin and
        // feather beyond it so the band filter cannot draw halos around text.
        var protectionDistance = [UInt8](repeating: 96, count: width * height)
        for rect in rects {
            let x0 = max(0, min(width, Int(rect.minX))), x1 = max(0, min(width, Int(rect.maxX)))
            let y0 = max(0, min(height, Int(rect.minY))), y1 = max(0, min(height, Int(rect.maxY)))
            if x0 < x1 && y0 < y1 {
                for y in y0..<y1 { for x in x0..<x1 { protectionDistance[y * width + x] = 0 } }
            }
        }
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let i = y * width + x
                var lowest = luma[i], highest = luma[i]
                for yy in max(0, y - 1)...min(height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(width - 1, x + 1) {
                        lowest = min(lowest, luma[yy * width + xx])
                        highest = max(highest, luma[yy * width + xx])
                    }
                }
                if highest - lowest >= 18 || pixels[i * 4 + 3] < 255 { protectionDistance[i] = 0 }
                if x > 0 { protectionDistance[i] = min(protectionDistance[i], protectionDistance[i - 1] + 1) }
                if y > 0 { protectionDistance[i] = min(protectionDistance[i], protectionDistance[i - width] + 1) }
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            try Task.checkCancellation()
            for x in stride(from: width - 1, through: 0, by: -1) {
                let i = y * width + x
                if x + 1 < width { protectionDistance[i] = min(protectionDistance[i], protectionDistance[i + 1] + 1) }
                if y + 1 < height { protectionDistance[i] = min(protectionDistance[i], protectionDistance[i + width] + 1) }
            }
        }
        let window: [Float] = (0..<side).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(side)) }
        var band = [Float](repeating: 0, count: count)
        for y in 0..<side {
            for x in 0..<side {
                let fx = Float(min(x, side - x)) / Float(side)
                let fy = Float(min(y, side - y)) / Float(side)
                let radius = sqrt(fx * fx + fy * fy)
                // Soft annulus: periods 16–32 px, tapering to 12–40 px.
                let low = smooth((radius - 1 / 40.0) / (1 / 32.0 - 1 / 40.0))
                let high = 1 - smooth((radius - 1 / 16.0) / (1 / 12.0 - 1 / 16.0))
                band[y * side + x] = -strength.attenuation * low * high
            }
        }
        var real = [Float](repeating: 0, count: count)
        var imaginary = real
        // Ring buffers bound working memory independently of photo height.
        var delta = [Float](repeating: 0, count: width * side)
        var weights = delta
        let tileRows = Array(stride(from: -hop, to: height, by: hop))
        var flushed = 0
        for (rowIndex, ty) in tileRows.enumerated() {
            try Task.checkCancellation()
            for tx in stride(from: -hop, to: width, by: hop) {
                try Task.checkCancellation()
                var mean: Float = 0
                for y in 0..<side {
                    let sy = reflected(ty + y, length: height)
                    for x in 0..<side { mean += luma[sy * width + reflected(tx + x, length: width)] }
                }
                mean /= Float(count)
                for y in 0..<side {
                    let sy = reflected(ty + y, length: height)
                    for x in 0..<side {
                        let i = y * side + x
                        real[i] = (luma[sy * width + reflected(tx + x, length: width)] - mean) * window[x] * window[y]
                        imaginary[i] = 0
                    }
                }
                real.withUnsafeMutableBufferPointer { re in
                    imaginary.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_fft2d_zip(setup, &split, 1, side, 8, 8, FFTDirection(FFT_FORWARD))
                        for i in 0..<count { re[i] *= band[i]; im[i] *= band[i] }
                        vDSP_fft2d_zip(setup, &split, 1, side, 8, 8, FFTDirection(FFT_INVERSE))
                    }
                }
                for y in max(0, -ty)..<min(side, height - ty) {
                    let ringRow = ((ty + y) % side) * width
                    for x in max(0, -tx)..<min(side, width - tx) {
                        let w = window[x] * window[y]
                        let index = ringRow + tx + x
                        delta[index] += real[y * side + x] * w / Float(count)
                        weights[index] += w * w
                    }
                }
            }
            let end = min(height, ty + hop)
            if flushed < end {
                for y in flushed..<end {
                    for x in 0..<width {
                        let i = y * width + x, p = i * 4, ring = (y % side) * width + x
                        defer { delta[ring] = 0; weights[ring] = 0 }
                        guard protectionDistance[i] > 32, pixels[p + 3] == 255, weights[ring] > 0.0001 else { continue }
                        var lowest = luma[i], highest = luma[i]
                        for yy in max(0, y - 1)...min(height - 1, y + 1) {
                            for xx in max(0, x - 1)...min(width - 1, x + 1) {
                                lowest = min(lowest, luma[yy * width + xx])
                                highest = max(highest, luma[yy * width + xx])
                            }
                        }
                        let edgeGain = (1 - smooth((highest - lowest - 5) / 13)) * smooth((Float(protectionDistance[i]) - 32) / 64)
                        let amount = max(-strength.pixelLimit, min(strength.pixelLimit, delta[ring] / weights[ring])) * edgeGain
                        let rounded = Int(amount.rounded())
                        for c in 0..<3 { pixels[p + c] = UInt8(clamping: Int(pixels[p + c]) + rounded) }
                    }
                }
                flushed = end
            }
            progress(0.08 + 0.82 * Double(rowIndex + 1) / Double(tileRows.count), "Обработка паттерна…")
        }
        // The final tile starts in the last hop and flushes the bottom edge.
        assert(flushed == height)
    }

    private static func smooth(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    private static func reflected(_ value: Int, length: Int) -> Int {
        guard length > 1 else { return 0 }
        let period = 2 * (length - 1)
        let positive = (value % period + period) % period
        return positive < length ? positive : period - positive
    }
}
