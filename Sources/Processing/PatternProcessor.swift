import Accelerate
import CoreGraphics
import CryptoKit
import Foundation
import Vision

/// A bounded, non-generative frequency filter. It is not a SynthID detector.
/// Pattern processing retains source coordinates. Optional output scaling is a
/// separate non-generative step after protection and local quality checks.
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

    static func process(_ image: CGImage, strength: ProcessingStrength, clarity: Bool = false,
                        resolution: OutputResolution = .original,
                        progress: @Sendable (Double, String) -> Void) throws -> CGImage {
        progress(0.02, "Защита текста…")
        // Fail closed if Vision fails: never silently process unprotected text.
        let regions = try recognizeText(image)
        var bytes = PixelRaster.pixels(image)
        let textBefore = textDigests(bytes, width: image.width, height: image.height, regions: regions)
        try filter(&bytes, width: image.width, height: image.height, strength: strength,
                   protectedRects: regions.map(\.rect)) { value, label in progress(value * 0.7, label) }
        try Task.checkCancellation()
        if clarity {
            progress(0.68, "Мягкая чёткость…")
            try GentleClarity.apply(&bytes, width: image.width, height: image.height, protectedRects: regions.map(\.rect))
        }
        // Check the actual protected source pixels, not OCR transcription.
        // Recognition can change on identical lettering after scaling or when
        // its surrounding context changes. This does not imply glyph damage.
        guard textDigests(bytes, width: image.width, height: image.height, regions: regions) == textBefore
        else { throw ProcessingError.textChanged }
        let size = resolution.dimensions(width: image.width, height: image.height)
        if size.width != image.width || size.height != image.height {
            progress(0.72, "Масштабирование 4K…")
            bytes = try DetailResampler.resize(bytes, width: image.width, height: image.height,
                                               outputWidth: size.width, outputHeight: size.height)
        }
        let output = try PixelRaster.image(bytes, width: size.width, height: size.height)
        progress(0.94, "Проверка текста…")
        return output
    }

    private static func textDigests(_ pixels: [UInt8], width: Int, height: Int, regions: [TextRegion]) -> [SHA256.Digest] {
        regions.map { region in
            let rect = region.rect.insetBy(dx: -4, dy: -4).integral
            let x0 = max(0, min(width, Int(rect.minX))), x1 = max(0, min(width, Int(rect.maxX)))
            let y0 = max(0, min(height, Int(rect.minY))), y1 = max(0, min(height, Int(rect.maxY)))
            var digest = SHA256()
            if x0 < x1 && y0 < y1 {
                for y in y0..<y1 { digest.update(data: Data(pixels[((y * width + x0) * 4)..<((y * width + x1) * 4)])) }
            }
            return digest.finalize()
        }
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
        // Text and contrast edges need different margins. A single 96 px edge
        // halo froze entire detailed photographs in the 0.6 benchmark.
        var textDistance = [UInt8](repeating: 32, count: width * height)
        var edgeDistance = [UInt8](repeating: 12, count: width * height)
        for rect in rects {
            let x0 = max(0, min(width, Int(rect.minX))), x1 = max(0, min(width, Int(rect.maxX)))
            let y0 = max(0, min(height, Int(rect.minY))), y1 = max(0, min(height, Int(rect.maxY)))
            if x0 < x1 && y0 < y1 {
                for y in y0..<y1 { for x in x0..<x1 { textDistance[y * width + x] = 0 } }
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
                if highest - lowest >= 18 || pixels[i * 4 + 3] < 255 { edgeDistance[i] = 0 }
                if x > 0 {
                    edgeDistance[i] = min(edgeDistance[i], edgeDistance[i - 1] + 1)
                    textDistance[i] = min(textDistance[i], textDistance[i - 1] + 1)
                }
                if y > 0 {
                    edgeDistance[i] = min(edgeDistance[i], edgeDistance[i - width] + 1)
                    textDistance[i] = min(textDistance[i], textDistance[i - width] + 1)
                }
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            try Task.checkCancellation()
            for x in stride(from: width - 1, through: 0, by: -1) {
                let i = y * width + x
                if x + 1 < width {
                    edgeDistance[i] = min(edgeDistance[i], edgeDistance[i + 1] + 1)
                    textDistance[i] = min(textDistance[i], textDistance[i + 1] + 1)
                }
                if y + 1 < height {
                    edgeDistance[i] = min(edgeDistance[i], edgeDistance[i + width] + 1)
                    textDistance[i] = min(textDistance[i], textDistance[i + width] + 1)
                }
            }
        }
        let window: [Float] = (0..<side).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(side)) }
        var band = [Float](repeating: 0, count: count)
        for y in 0..<side {
            for x in 0..<side {
                let fx = Float(min(x, side - x)) / Float(side)
                let fy = Float(min(y, side - y)) / Float(side)
                let radius = sqrt(fx * fx + fy * fy)
                // Phase perturbation preserves each tile's spectral magnitudes.
                // Cover periods 8–32 px, taper to 6–48; never blur by damping.
                let low = smooth((radius - 1 / 48.0) / (1 / 32.0 - 1 / 48.0))
                let high = 1 - smooth((radius - 1 / 8.0) / (1 / 6.0 - 1 / 8.0))
                band[y * side + x] = strength.phaseLimit * low * high
            }
        }
        var real = [Float](repeating: 0, count: count)
        var imaginary = real
        // Ring buffers bound working memory independently of photo height.
        var delta = [Float](repeating: 0, count: width * side)
        var weights = delta
        var applied = [Int8](repeating: 0, count: width * height)
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
                        for y in 0..<side {
                            for x in 0..<side {
                                let i = y * side + x
                                let partner = ((side - y) % side) * side + (side - x) % side
                                if i == partner { re[i] = 0; im[i] = 0; continue }
                                guard i < partner else { continue }
                                // Smooth phase across adjacent bins prevents
                                // cancellation when overlapping windows blend.
                                // Independent random bin phases caused softening
                                // even though individual FFT magnitudes survived.
                                let sx = Float(x <= side / 2 ? x : x - side)
                                let sy = Float(y <= side / 2 ? y : y - side)
                                let direction = (0.8 * sx + 0.6 * sy) / max(1, sqrt(sx * sx + sy * sy))
                                let angle = band[i] * direction
                                let cosine = cos(angle) - 1, sine = sin(angle)
                                let dr = re[i] * cosine - im[i] * sine
                                let di = re[i] * sine + im[i] * cosine
                                re[i] = dr; im[i] = di
                                re[partner] = dr; im[partner] = -di
                            }
                        }
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
                        guard textDistance[i] > 8, edgeDistance[i] > 2, pixels[p + 3] == 255, weights[ring] > 0.0001 else { continue }
                        var lowest = luma[i], highest = luma[i]
                        for yy in max(0, y - 1)...min(height - 1, y + 1) {
                            for xx in max(0, x - 1)...min(width - 1, x + 1) {
                                lowest = min(lowest, luma[yy * width + xx])
                                highest = max(highest, luma[yy * width + xx])
                            }
                        }
                        let edgeGain = (1 - smooth((highest - lowest - 5) / 13))
                            * smooth((Float(edgeDistance[i]) - 2) / 10) * smooth((Float(textDistance[i]) - 8) / 24)
                        // Flat areas cannot receive ringing from distant edges.
                        // Weak real texture still has a small nonzero budget.
                        let budget = min(strength.pixelLimit, (highest - lowest) * 0.75)
                        let amount = max(-budget, min(budget, delta[ring] / weights[ring])) * edgeGain
                        // Keep a common offset without channel clipping. This
                        // also permits exact rollback during the detail check.
                        let low = Int(min(pixels[p], min(pixels[p + 1], pixels[p + 2])))
                        let high = Int(max(pixels[p], max(pixels[p + 1], pixels[p + 2])))
                        let rounded = max(-low, min(255 - high, Int(amount.rounded())))
                        applied[i] = Int8(rounded)
                        for c in 0..<3 { pixels[p + c] = UInt8(Int(pixels[p + c]) + rounded) }
                    }
                }
                flushed = end
            }
            progress(0.08 + 0.82 * Double(rowIndex + 1) / Double(tileRows.count), "Обработка паттерна…")
        }
        // The final tile starts in the last hop and flushes the bottom edge.
        assert(flushed == height)
        progress(0.91, "Сохранение деталей…")
        try preserveDetail(&pixels, luma: luma, applied: applied, width: width, height: height)
    }

    /// Reject locally softened patches, then feather their surrounding cells.
    /// Original pixels can be recovered exactly from the integer offset map.
    private static func preserveDetail(_ pixels: inout [UInt8], luma: [Float], applied: [Int8], width: Int, height: Int) throws {
        let step = 64, columns = (width + 63) / 64, rows = (height + 63) / 64
        var accepted = [Float](repeating: 1, count: columns * rows)
        for gy in 0..<rows {
            try Task.checkCancellation()
            for gx in 0..<columns {
                var before: Float = 0, after: Float = 0
                var samples = 0
                for y in (gy * step)..<min(height - 1, (gy + 1) * step) {
                    for x in (gx * step)..<min(width - 1, (gx + 1) * step) {
                        let i = y * width + x
                        let dx = luma[i + 1] - luma[i], dy = luma[i + width] - luma[i]
                        let ax = dx + Float(applied[i + 1]) - Float(applied[i])
                        let ay = dy + Float(applied[i + width]) - Float(applied[i])
                        before += dx * dx + dy * dy
                        after += ax * ax + ay * ay
                        samples += 1
                    }
                }
                if before > Float(samples) * 0.05 && after < before * 0.97 { accepted[gy * columns + gx] = 0 }
            }
        }
        // A rejected cell also protects its immediate neighbors, avoiding a
        // sharp transition between rollback and processed pixels.
        var safe = accepted
        for y in 0..<rows {
            for x in 0..<columns {
                var value: Float = 1
                for yy in max(0, y - 1)...min(rows - 1, y + 1) {
                    for xx in max(0, x - 1)...min(columns - 1, x + 1) { value = min(value, accepted[yy * columns + xx]) }
                }
                safe[y * columns + x] = value
            }
        }
        for y in 0..<height {
            try Task.checkCancellation()
            let fy = max(0, Float(y) / Float(step) - 0.5), y0 = min(rows - 1, Int(fy)), y1 = min(rows - 1, y0 + 1)
            let wy = smooth(fy - Float(y0))
            for x in 0..<width {
                let i = y * width + x
                guard applied[i] != 0 else { continue }
                let fx = max(0, Float(x) / Float(step) - 0.5), x0 = min(columns - 1, Int(fx)), x1 = min(columns - 1, x0 + 1)
                let wx = smooth(fx - Float(x0))
                let top = safe[y0 * columns + x0] * (1 - wx) + safe[y0 * columns + x1] * wx
                let bottom = safe[y1 * columns + x0] * (1 - wx) + safe[y1 * columns + x1] * wx
                let retained = Int((Float(applied[i]) * (top * (1 - wy) + bottom * wy)).rounded())
                for c in 0..<3 { pixels[i * 4 + c] = UInt8(Int(pixels[i * 4 + c]) - Int(applied[i]) + retained) }
            }
        }
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
