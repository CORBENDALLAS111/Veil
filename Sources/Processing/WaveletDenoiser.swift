import Foundation

/// Generic frequency-domain noise suppression. This is not a SynthID decoder,
/// detector, or a validated watermark-removal algorithm.
enum WaveletDenoiser {
    /// In-place, two-level orthonormal Haar shrinkage on straight-alpha RGBA8.
    /// Replicated-edge padding to multiples of four keeps constant color stable
    /// at odd-sized borders across both transform levels.
    static func reduce(
        pixels: inout [UInt8], width originalWidth: Int, height originalHeight: Int, threshold: Float
    ) throws {
        precondition(originalWidth > 0 && originalHeight > 0 && pixels.count == originalWidth * originalHeight * 4)
        let width = (originalWidth + 3) / 4 * 4
        let height = (originalHeight + 3) / 4 * 4
        let factor = Float(1 / sqrt(2.0))
        var plane = [Float](repeating: 0, count: width * height)
        var scratch = [Float](repeating: 0, count: max(width, height))
        var levels: [(Int, Int)] = []
        var w = width
        var h = height
        for _ in 0..<2 where w >= 2 && h >= 2 {
            levels.append((w, h))
            w = (w + 1) / 2
            h = (h + 1) / 2
        }
        for channel in 0..<3 {
            try Task.checkCancellation()
            for y in 0..<height {
                for x in 0..<width {
                    let source = (min(y, originalHeight - 1) * originalWidth + min(x, originalWidth - 1)) * 4 + channel
                    plane[y * width + x] = Float(pixels[source])
                }
            }
            for (levelWidth, levelHeight) in levels {
                for y in 0..<levelHeight {
                    if y % 128 == 0 { try Task.checkCancellation() }
                    let start = y * width
                    let half = (levelWidth + 1) / 2
                    for x in 0..<(levelWidth / 2) {
                        let a = plane[start + 2 * x]
                        let b = plane[start + 2 * x + 1]
                        scratch[x] = (a + b) * factor
                        scratch[half + x] = (a - b) * factor
                    }
                    if levelWidth % 2 == 1 { scratch[half - 1] = plane[start + levelWidth - 1] }
                    for x in 0..<levelWidth { plane[start + x] = scratch[x] }
                }
                for x in 0..<levelWidth {
                    let half = (levelHeight + 1) / 2
                    for y in 0..<(levelHeight / 2) {
                        let a = plane[2 * y * width + x]
                        let b = plane[(2 * y + 1) * width + x]
                        scratch[y] = (a + b) * factor
                        scratch[half + y] = (a - b) * factor
                    }
                    if levelHeight % 2 == 1 { scratch[half - 1] = plane[(levelHeight - 1) * width + x] }
                    for y in 0..<levelHeight { plane[y * width + x] = scratch[y] }
                }
                let lowWidth = (levelWidth + 1) / 2
                let lowHeight = (levelHeight + 1) / 2
                for y in 0..<levelHeight {
                    for x in 0..<levelWidth where x >= lowWidth || y >= lowHeight {
                        let i = y * width + x
                        let value = plane[i]
                        // Firm shrinkage: preserve large coefficients (edges), suppress
                        // small coefficients (noise). No detector feedback is implied.
                        let magnitude = abs(value)
                        if magnitude <= threshold {
                            plane[i] = 0
                        } else if magnitude < threshold * 3 {
                            plane[i] = (value < 0 ? -1 : 1) * (magnitude - threshold) * 1.5
                        }
                    }
                }
            }
            for (levelWidth, levelHeight) in levels.reversed() {
                for x in 0..<levelWidth {
                    let half = (levelHeight + 1) / 2
                    for y in 0..<(levelHeight / 2) {
                        let a = plane[y * width + x]
                        let b = plane[(half + y) * width + x]
                        scratch[2 * y] = (a + b) * factor
                        scratch[2 * y + 1] = (a - b) * factor
                    }
                    if levelHeight % 2 == 1 { scratch[levelHeight - 1] = plane[(half - 1) * width + x] }
                    for y in 0..<levelHeight { plane[y * width + x] = scratch[y] }
                }
                for y in 0..<levelHeight {
                    if y % 128 == 0 { try Task.checkCancellation() }
                    let start = y * width
                    let half = (levelWidth + 1) / 2
                    for x in 0..<(levelWidth / 2) {
                        let a = plane[start + x]
                        let b = plane[start + half + x]
                        scratch[2 * x] = (a + b) * factor
                        scratch[2 * x + 1] = (a - b) * factor
                    }
                    if levelWidth % 2 == 1 { scratch[levelWidth - 1] = plane[start + half - 1] }
                    for x in 0..<levelWidth { plane[start + x] = scratch[x] }
                }
            }
            for y in 0..<originalHeight {
                for x in 0..<originalWidth {
                    pixels[(y * originalWidth + x) * 4 + channel] = UInt8(max(0, min(255, plane[y * width + x].rounded())))
                }
            }
        }
    }
}
