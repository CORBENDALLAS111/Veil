import Accelerate
import CoreGraphics
import Foundation

/// Optional narrow spectral-peak suppression for visible periodic texture.
/// It cannot identify the origin of a pattern or verify SynthID removal.
enum RippleReducer {
    static func apply(_ pixels: inout [UInt8], width: Int, height: Int, protectedRects: [CGRect] = []) throws {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { throw ProcessingError.invalidImage }
        guard width >= 32, height >= 32 else { return }
        let side = 128, hop = 64, count = side * side
        guard let setup = vDSP_create_fftsetup(7, FFTRadix(kFFTRadix2)) else { throw ProcessingError.encodeFailed }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = (0..<side).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(side))) }
        var luma = [Float](repeating: 0, count: width * height)
        var frozen = [Bool](repeating: false, count: width * height)
        for i in luma.indices {
            luma[i] = Float(pixels[i * 4]) * 0.299 + Float(pixels[i * 4 + 1]) * 0.587 + Float(pixels[i * 4 + 2]) * 0.114
        }
        for rect in protectedRects.map({ $0.insetBy(dx: -8, dy: -8).integral }) {
            let x0 = max(0, min(width, Int(rect.minX))), x1 = max(0, min(width, Int(rect.maxX)))
            let y0 = max(0, min(height, Int(rect.minY))), y1 = max(0, min(height, Int(rect.maxY)))
            if x0 < x1 && y0 < y1 { for y in y0..<y1 { for x in x0..<x1 { frozen[y * width + x] = true } } }
        }
        var real = [Float](repeating: 0, count: count), imaginary = [Float](repeating: 0, count: count)
        var delta = [Float](repeating: 0, count: width * side), weights = delta
        let reflected: (Int, Int) -> Int = { value, length in
            guard length > 1 else { return 0 }
            let period = 2 * (length - 1), p = (value % period + period) % period
            return p < length ? p : period - p
        }
        var flushed = 0
        for ty in stride(from: -hop, to: height, by: hop) {
            try Task.checkCancellation()
            for tx in stride(from: -hop, to: width, by: hop) {
                try Task.checkCancellation()
                var mean: Float = 0
                for y in 0..<side { for x in 0..<side { mean += luma[reflected(ty + y, height) * width + reflected(tx + x, width)] } }
                mean /= Float(count)
                for y in 0..<side { for x in 0..<side {
                    let i = y * side + x
                    real[i] = (luma[reflected(ty + y, height) * width + reflected(tx + x, width)] - mean) * window[x] * window[y]
                    imaginary[i] = 0
                } }
                real.withUnsafeMutableBufferPointer { re in
                    imaginary.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_fft2d_zip(setup, &split, 1, side, 7, 7, FFTDirection(FFT_FORWARD))
                        var power = [Float](repeating: 0, count: count)
                        for i in 0..<count { power[i] = re[i] * re[i] + im[i] * im[i] }
                        var peaks: [(Int, Float)] = []
                        for y in 0..<side { for x in 0..<side {
                            let i = y * side + x, partner = ((side - y) % side) * side + (side - x) % side
                            let fx = Float(min(x, side - x)) / Float(side), fy = Float(min(y, side - y)) / Float(side)
                            let radius = sqrt(fx * fx + fy * fy)
                            guard i < partner, radius > 1 / 48.0, radius < 0.45, power[i] > 4096 else { continue }
                            var localMaximum: Float = 0, background: Float = 0, samples: Float = 0
                            for dy in -4...4 { for dx in -4...4 where dx != 0 || dy != 0 {
                                let n = ((y + dy + side) % side) * side + (x + dx + side) % side
                                if abs(dx) <= 1 && abs(dy) <= 1 { localMaximum = max(localMaximum, power[n]) }
                                else if abs(dx) >= 3 || abs(dy) >= 3 { background += power[n]; samples += 1 }
                            } }
                            guard power[i] >= localMaximum, power[i] > 24 * max(1, background / samples) else { continue }
                            peaks.append((i, power[i]))
                        } }
                        peaks.sort { $0.1 > $1.1 }
                        var notch = [Float](repeating: 0, count: count)
                        for (i, _) in peaks.prefix(12) {
                            let x = i % side, y = i / side
                            for dy in -1...1 { for dx in -1...1 {
                                let xx = (x + dx + side) % side, yy = (y + dy + side) % side
                                let n = yy * side + xx, partner = ((side - yy) % side) * side + (side - xx) % side
                                notch[n] = 0.65; notch[partner] = 0.65
                            } }
                        }
                        for i in 0..<count { re[i] *= -notch[i]; im[i] *= -notch[i] }
                        vDSP_fft2d_zip(setup, &split, 1, side, 7, 7, FFTDirection(FFT_INVERSE))
                    }
                }
                for y in max(0, -ty)..<min(side, height - ty) {
                    let row = ((ty + y) % side) * width
                    for x in max(0, -tx)..<min(side, width - tx) {
                        let w = window[y] * window[x], i = row + tx + x
                        delta[i] += real[y * side + x] * w / Float(count)
                        weights[i] += w * w
                    }
                }
            }
            let end = min(height, ty + hop)
            if flushed < end {
                for y in flushed..<end { for x in 0..<width {
                    let i = y * width + x, p = i * 4, ring = (y % side) * width + x
                    defer { delta[ring] = 0; weights[ring] = 0 }
                    guard !frozen[i], pixels[p + 3] == 255, weights[ring] > 0.0001 else { continue }
                    var low = luma[i], high = luma[i], opaque = true
                    for yy in max(0, y - 2)...min(height - 1, y + 2) {
                        for xx in max(0, x - 2)...min(width - 1, x + 2) {
                            let n = yy * width + xx
                            low = min(low, luma[n]); high = max(high, luma[n])
                            if pixels[n * 4 + 3] != 255 { opaque = false }
                        }
                    }
                    guard opaque, high - low < 24 else { continue }
                    let fade = min(1, max(0, (24 - (high - low)) / 8))
                    let proposal = Int((min(3, max(-3, delta[ring] / weights[ring])) * fade).rounded())
                    let rgbLow = Int(min(pixels[p], min(pixels[p + 1], pixels[p + 2])))
                    let rgbHigh = Int(max(pixels[p], max(pixels[p + 1], pixels[p + 2])))
                    let correction = min(255 - rgbHigh, max(-rgbLow, proposal))
                    for c in 0..<3 { pixels[p + c] = UInt8(Int(pixels[p + c]) + correction) }
                } }
                flushed = end
            }
        }
    }
}
