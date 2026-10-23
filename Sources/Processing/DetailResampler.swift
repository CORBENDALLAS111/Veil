import Foundation

/// Shape-preserving cubic interpolation for enlargement; area averaging for
/// reduction. No learned content, negative-lobed kernels or ringing overshoot.
enum DetailResampler {
    private struct Kernel {
        let indices: [Int]
        let weights: [Float]
        let fraction: Float
        var cubic: Bool { weights.isEmpty }
    }

    static func resize(_ pixels: [UInt8], width: Int, height: Int,
                       outputWidth: Int, outputHeight: Int) throws -> [UInt8] {
        guard width > 0, height > 0, outputWidth > 0, outputHeight > 0,
              outputWidth <= 20_000, outputHeight <= 20_000,
              outputWidth * outputHeight <= 20_000_000,
              pixels.count == width * height * 4 else { throw ProcessingError.invalidImage }
        try Task.checkCancellation()
        if width == outputWidth && height == outputHeight { return pixels }
        let horizontal = kernels(source: width, destination: outputWidth)
        let vertical = kernels(source: height, destination: outputHeight)
        var cache: [Int: [Float]] = [:]
        var output = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)

        func component(_ x: Int, _ y: Int, _ c: Int) -> Float {
            let p = (y * width + x) * 4
            if c == 3 { return Float(pixels[p + 3]) }
            return Float(pixels[p + c]) * Float(pixels[p + 3]) / 255
        }

        func makeRow(_ y: Int) -> [Float] {
            var row = [Float](repeating: 0, count: outputWidth * 4)
            for x in 0..<outputWidth {
                let kernel = horizontal[x]
                for c in 0..<4 {
                    let value: Float
                    if kernel.cubic {
                        value = monotone(component(kernel.indices[0], y, c), component(kernel.indices[1], y, c),
                                         component(kernel.indices[2], y, c), component(kernel.indices[3], y, c), kernel.fraction)
                    } else {
                        var sum: Float = 0
                        for k in kernel.indices.indices { sum += component(kernel.indices[k], y, c) * kernel.weights[k] }
                        value = sum
                    }
                    row[x * 4 + c] = value
                }
            }
            return row
        }

        for y in 0..<outputHeight {
            try Task.checkCancellation()
            let kernel = vertical[y]
            let needed = Set(kernel.indices)
            for key in Array(cache.keys) where !needed.contains(key) { cache.removeValue(forKey: key) }
            for sy in needed where cache[sy] == nil { cache[sy] = makeRow(sy) }
            let rows = kernel.indices.map { cache[$0]! }
            for x in 0..<outputWidth {
                var rgba = SIMD4<Float>(repeating: 0)
                for c in 0..<4 {
                    if kernel.cubic {
                        rgba[c] = monotone(rows[0][x * 4 + c], rows[1][x * 4 + c],
                                           rows[2][x * 4 + c], rows[3][x * 4 + c], kernel.fraction)
                    } else {
                        for k in rows.indices { rgba[c] += rows[k][x * 4 + c] * kernel.weights[k] }
                    }
                }
                let alpha = min(255, max(0, rgba[3]))
                let p = (y * outputWidth + x) * 4
                for c in 0..<3 {
                    output[p + c] = alpha > 0.0001 ? UInt8(clamping: Int((rgba[c] * 255 / alpha).rounded())) : 0
                }
                output[p + 3] = UInt8(clamping: Int(alpha.rounded()))
            }
        }
        return output
    }

    private static func kernels(source: Int, destination: Int) -> [Kernel] {
        (0..<destination).map { index in
            if destination < source {
                let start = Double(index) * Double(source) / Double(destination)
                let end = Double(index + 1) * Double(source) / Double(destination)
                let indices = Array(Int(start)..<min(source, Int(ceil(end))))
                let weights = indices.map { Float(max(0, min(end, Double($0 + 1)) - max(start, Double($0))) / (end - start)) }
                return Kernel(indices: indices, weights: weights, fraction: 0)
            }
            let coordinate = max(0, min(Float(source - 1), (Float(index) + 0.5) * Float(source) / Float(destination) - 0.5))
            let base = Int(coordinate)
            return Kernel(indices: [-1, 0, 1, 2].map { max(0, min(source - 1, base + $0)) },
                          weights: [], fraction: coordinate - Float(base))
        }
    }

    /// Harmonic-mean tangents become zero at extrema. Clamping also guarantees
    /// that no interpolated value overshoots the two enclosing samples.
    private static func monotone(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
        let left = b - a, center = c - b, right = d - c
        let m0 = left * center > 0 ? 2 * left * center / (left + center) : 0
        let m1 = center * right > 0 ? 2 * center * right / (center + right) : 0
        let t2 = t * t, t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * b + (t3 - 2 * t2 + t) * m0
            + (-2 * t3 + 3 * t2) * c + (t3 - t2) * m1
        return max(min(b, c), min(max(b, c), value))
    }
}
