import CoreGraphics
import CoreImage
import CoreML
import Foundation
@preconcurrency import StableDiffusion

struct TilePlan {
    let width: Int
    let height: Int
    let size = 512
    let overlap = 64
    var origins: [(x: Int, y: Int)] {
        rows(height).flatMap { y in rows(width).map { (x: $0, y: y) } }
    }
    private func rows(_ length: Int) -> [Int] {
        guard length > size else { return [0] }
        var result = Array(stride(from: 0, through: length - size, by: size - overlap))
        if result.last != length - size { result.append(length - size) }
        return result
    }
    func weight(_ position: Int, origin: Int, length: Int) -> Float {
        var weight: Float = 1
        if origin > 0 { weight = min(weight, Float(position + 1) / Float(overlap)) }
        if origin + size < length { weight = min(weight, Float(size - position) / Float(overlap)) }
        return weight
    }
}

/// All visible pixels come from regenerated tiles. Original RGB detail is never pasted back.
struct TileAccumulator {
    let plan: TilePlan
    let original: [UInt8]
    private var colors: [Float]
    private var weights: [Float]

    init(plan: TilePlan, original: [UInt8]) {
        self.plan = plan
        self.original = original
        colors = Array(repeating: 0, count: plan.width * plan.height * 3)
        weights = Array(repeating: 0, count: plan.width * plan.height)
    }
    func input(x: Int, y: Int) -> [UInt8] {
        var tile = [UInt8](repeating: 255, count: plan.size * plan.size * 4)
        for ty in 0..<plan.size {
            for tx in 0..<plan.size {
                let source = (min(y + ty, plan.height - 1) * plan.width + min(x + tx, plan.width - 1)) * 4
                let target = (ty * plan.size + tx) * 4
                let alpha = Int(original[source + 3])
                for c in 0..<3 { tile[target + c] = UInt8((Int(original[source + c]) * alpha + 255 * (255 - alpha)) / 255) }
            }
        }
        return tile
    }
    mutating func append(_ tile: [UInt8], x: Int, y: Int) {
        for ty in 0..<min(plan.size, plan.height - y) {
            for tx in 0..<min(plan.size, plan.width - x) {
                let weight = plan.weight(tx, origin: x, length: plan.width) * plan.weight(ty, origin: y, length: plan.height)
                let target = (y + ty) * plan.width + x + tx
                let source = (ty * plan.size + tx) * 4
                weights[target] += weight
                for c in 0..<3 { colors[target * 3 + c] += Float(tile[source + c]) * weight }
            }
        }
    }
    func finish() throws -> [UInt8] {
        guard weights.allSatisfy({ $0 > 0 && $0.isFinite }) else { throw NeuralError.invalidOutput }
        var output = [UInt8](repeating: 255, count: plan.width * plan.height * 4)
        for i in weights.indices {
            for c in 0..<3 {
                let value = colors[i * 3 + c] / weights[i]
                guard value.isFinite else { throw NeuralError.invalidOutput }
                output[i * 4 + c] = UInt8(max(0, min(255, value.rounded())))
            }
            output[i * 4 + 3] = original[i * 4 + 3]
        }
        return output
    }
}

enum NeuralRaster {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = CIContext(options: [.cacheIntermediates: false, .outputPremultiplied: false])
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes {
            context.render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: image.width * 4,
                           bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                           format: .RGBA8, colorSpace: colorSpace)
        }
        return bytes
    }
    static func image(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard bytes.count == width * height * 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw NeuralError.invalidOutput }
        return image
    }
    static func resized(_ image: CGImage, maximumDimension: Int) throws -> CGImage {
        let ratio = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
        guard ratio < 1 else { return image }
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        let input = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let output = context.createCGImage(input, from: CGRect(x: 0, y: 0, width: width, height: height),
                                                format: .RGBA8, colorSpace: colorSpace)
        else { throw NeuralError.invalidOutput }
        return output
    }
}

enum NeuralQuality {
    /// Detects gross corruption or lost source structure, not watermark presence.
    static func validate(_ output: [UInt8], against source: [UInt8], strength: Float) throws {
        guard output.count == source.count, !output.isEmpty, output.count % 4 == 0 else { throw NeuralError.invalidOutput }
        var sourceSum = [Double](repeating: 0, count: 3)
        var outputSum = [Double](repeating: 0, count: 3)
        var sourceSquares: Double = 0, outputSquares: Double = 0, cross: Double = 0, difference: Double = 0
        let count = Double(source.count / 4)
        for i in stride(from: 0, to: source.count, by: 4) {
            for c in 0..<3 {
                let a = Double(source[i + c]), b = Double(output[i + c])
                sourceSum[c] += a
                outputSum[c] += b
                sourceSquares += a * a
                outputSquares += b * b
                cross += a * b
                difference += abs(a - b)
            }
        }
        for c in 0..<3 {
            sourceSquares -= sourceSum[c] * sourceSum[c] / count
            outputSquares -= outputSum[c] * outputSum[c] / count
            cross -= sourceSum[c] * outputSum[c] / count
        }
        let maximumDifference: Double = strength <= 0.12 ? 25 : (strength <= 0.20 ? 35 : 45)
        guard difference / (count * 3) < maximumDifference else { throw NeuralError.invalidOutput }
        if sourceSquares / (count * 3) > 64 {
            let correlation = cross / sqrt(max(1, sourceSquares * outputSquares))
            guard correlation.isFinite, correlation > (strength <= 0.12 ? 0.7 : 0.5) else { throw NeuralError.invalidOutput }
        }
    }
}

/// Synchronous engine, owned by PhotoProcessor's actor. No model crosses isolation boundaries.
final class NeuralRegenerator {
    func process(_ image: CGImage, modelURL: URL, strength: Float,
                 maximumDimension: Int = 1536, stepCount: Int = 50,
                 progress: @Sendable (Double, String) -> Void) throws -> CGImage {
        try Task.checkCancellation()
        let working = try NeuralRaster.resized(image, maximumDimension: maximumDimension)
        let plan = TilePlan(width: working.width, height: working.height)
        var accumulator = TileAccumulator(plan: plan, original: NeuralRaster.pixels(working))
        let compute = MLModelConfiguration()
        #if targetEnvironment(simulator)
        compute.computeUnits = .cpuOnly
        #else
        compute.computeUnits = .cpuAndNeuralEngine
        #endif
        progress(0, "Подготовка нейросети…")
        let vaeCompute = MLModelConfiguration()
        vaeCompute.computeUnits = .cpuAndGPU
        vaeCompute.allowLowPrecisionAccumulationOnGPU = false
        let urls = StableDiffusionPipeline.ResourceURLs(resourcesAt: modelURL)
        let tokenizer = try BPETokenizer(mergesAt: urls.mergesURL, vocabularyAt: urls.vocabURL)
        let pipeline = StableDiffusionPipeline(
            textEncoder: TextEncoder(tokenizer: tokenizer, modelAt: urls.textEncoderURL, configuration: compute),
            unet: Unet(modelAt: urls.unetURL, configuration: compute),
            decoder: Decoder(modelAt: urls.decoderURL, configuration: vaeCompute),
            encoder: Encoder(modelAt: urls.encoderURL, configuration: vaeCompute), reduceMemory: true)
        defer { pipeline.unloadResources() }
        let origins = plan.origins
        for (index, origin) in origins.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                var config = StableDiffusionPipeline.Configuration(prompt: "")
                config.startingImage = try NeuralRaster.image(accumulator.input(x: origin.x, y: origin.y), width: 512, height: 512)
                config.strength = strength
                config.stepCount = stepCount
                config.guidanceScale = 1
                config.schedulerType = .dpmSolverMultistepScheduler
                config.seed = UInt32(index)
                let images = try pipeline.generateImages(configuration: config) { update in
                    let fraction = (Double(index) + Double(update.step + 1) / Double(max(1, update.stepCount))) / Double(origins.count)
                    progress(fraction, "Участок \(index + 1) из \(origins.count) · \(update.step + 1)/\(update.stepCount)")
                    return !Task.isCancelled
                }
                try Task.checkCancellation()
                guard let first = images.first, let result = first, result.width == 512, result.height == 512 else {
                    throw NeuralError.invalidOutput
                }
                let output = NeuralRaster.pixels(result)
                try NeuralQuality.validate(output, against: accumulator.input(x: origin.x, y: origin.y), strength: strength)
                accumulator.append(output, x: origin.x, y: origin.y)
            }
        }
        return try NeuralRaster.image(accumulator.finish(), width: plan.width, height: plan.height)
    }
}
