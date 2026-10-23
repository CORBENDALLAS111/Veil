import CoreGraphics
import Foundation

/// Optional micro-contrast, capped at one RGB level. No noise reduction or
/// large-radius sharpening; recognized text and high-contrast edges are frozen.
enum GentleClarity {
    static func apply(_ pixels: inout [UInt8], width: Int, height: Int, protectedRects: [CGRect] = []) throws {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { throw ProcessingError.invalidImage }
        var luma = [Float](repeating: 0, count: width * height)
        var protected = [UInt8](repeating: 0, count: width * height)
        for i in luma.indices { luma[i] = 0.299 * Float(pixels[i * 4]) + 0.587 * Float(pixels[i * 4 + 1]) + 0.114 * Float(pixels[i * 4 + 2]) }
        for rect in protectedRects.map({ $0.insetBy(dx: -4, dy: -4).integral }) {
            let x0 = max(0, min(width, Int(rect.minX))), x1 = max(0, min(width, Int(rect.maxX)))
            let y0 = max(0, min(height, Int(rect.minY))), y1 = max(0, min(height, Int(rect.maxY)))
            if x0 < x1 && y0 < y1 { for y in y0..<y1 { for x in x0..<x1 { protected[y * width + x] = 1 } } }
        }
        let weights: [Float] = [1, 2, 1]
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let i = y * width + x, p = i * 4
                guard protected[i] == 0, pixels[p + 3] == 255 else { continue }
                var mean: Float = 0, low = luma[i], high = luma[i]
                for dy in -1...1 {
                    for dx in -1...1 {
                        let value = luma[max(0, min(height - 1, y + dy)) * width + max(0, min(width - 1, x + dx))]
                        mean += value * weights[dy + 1] * weights[dx + 1] / 16
                        low = min(low, value); high = max(high, value)
                    }
                }
                guard high - low >= 6, high - low < 48 else { continue }
                let detail = luma[i] - mean
                let amount = min(1, max(0, abs(detail) - 1.5) * 0.16) * (detail < 0 ? -1 : 1)
                let proposed = max(low - luma[i], min(high - luma[i], amount))
                let rgbLow = Int(min(pixels[p], min(pixels[p + 1], pixels[p + 2])))
                let rgbHigh = Int(max(pixels[p], max(pixels[p + 1], pixels[p + 2])))
                let delta = max(-rgbLow, min(255 - rgbHigh, Int(proposed.rounded())))
                for c in 0..<3 { pixels[p + c] = UInt8(Int(pixels[p + c]) + delta) }
            }
        }
    }
}
