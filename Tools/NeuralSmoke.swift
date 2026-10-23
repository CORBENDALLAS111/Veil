import Foundation
import CoreGraphics
import CoreML
import ImageIO
import UniformTypeIdentifiers
import StableDiffusion
import Metal
import Darwin

private struct MeanRandom: RandomSource {
    mutating func nextNormal(mean: Double, stdev: Double) -> Double { mean }
    mutating func normalShapedArray(_ shape: [Int], mean: Double, stdev: Double) -> MLShapedArray<Double> {
        MLShapedArray(scalars: Array(repeating: mean, count: shape.reduce(1, *)), shape: shape)
    }
}

@main struct NeuralSmoke {
    static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NeuralError.invalidOutput
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NeuralError.invalidOutput }
    }

    static func metrics(_ image: CGImage, reference: [UInt8], seconds: Double) throws -> [String: Double] {
        let actual = NeuralRaster.pixels(image)
        guard actual.count == reference.count else { throw NeuralError.invalidOutput }
        var mse: Double = 0, mae: Double = 0
        for i in stride(from: 0, to: actual.count, by: 4) {
            for c in 0..<3 {
                let d = Double(actual[i + c]) - Double(reference[i + c])
                mse += d * d
                mae += abs(d)
            }
        }
        let count = Double(actual.count / 4 * 3)
        mse /= count
        mae /= count
        guard mse.isFinite, mse > 0 else { throw NeuralError.invalidOutput }
        return ["mae": mae, "psnr_db": 10 * log10(255 * 255 / mse), "seconds": seconds]
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = NeuralModelStore(parent: root)
        let modelURL = try await store.install { value in
            if Int(value * 100) % 10 == 0 { print("Model download \(Int(value * 100))%") }
        }
        var pixels = [UInt8](repeating: 255, count: 512 * 512 * 4)
        for y in 0..<512 {
            for x in 0..<512 {
                let i = (y * 512 + x) * 4
                pixels[i] = UInt8(40 + x / 4)
                pixels[i + 1] = UInt8(40 + y / 4)
                pixels[i + 2] = UInt8(80 + ((x + y) % 2 == 0 ? 2 : 0))
            }
        }
        let input = try NeuralRaster.image(pixels, width: 512, height: 512)
        let out = root.appendingPathComponent("smoke")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try save(input, to: out.appendingPathComponent("input.png"))
        var report: [String: Any] = ["engine": "SD2.1 Core ML img2img with matching FP32 VAE",
                                   "schedule_steps": 50, "synthid_checked": false,
                                   "metal_device": MTLCreateSystemDefaultDevice()?.name ?? "none"]
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        configuration.allowLowPrecisionAccumulationOnGPU = false
        let startCodec = Date()
        let encoder = Encoder(modelAt: modelURL.appendingPathComponent("VAEEncoder.mlmodelc"), configuration: configuration)
        var random: any RandomSource = MeanRandom()
        let latent = try encoder.encode(input, scaleFactor: 0.18215, random: &random)
        guard latent.scalars.allSatisfy(\.isFinite) else { throw NeuralError.invalidOutput }
        encoder.unloadResources()
        let decoder = Decoder(modelAt: modelURL.appendingPathComponent("VAEDecoder.mlmodelc"), configuration: configuration)
        let reconstructed = try decoder.decode([latent], scaleFactor: 0.18215)[0]
        decoder.unloadResources()
        try save(reconstructed, to: out.appendingPathComponent("vae-roundtrip.png"))
        let codec = try metrics(reconstructed, reference: pixels, seconds: Date().timeIntervalSince(startCodec))
        report["codec"] = codec
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("metrics.json"))
        guard codec["mae"]! < 12 else { throw NeuralError.invalidOutput }
        if ProcessInfo.processInfo.environment["VEIL_DIAGNOSTIC_ONLY"] != "1" {
            for (name, strength) in [("gentle", Float(0.12)), ("balanced", Float(0.20))] {
                let start = Date()
                let result = try NeuralRegenerator().process(input, modelURL: modelURL, strength: strength) { _, text in print(text) }
                try save(result, to: out.appendingPathComponent("output-\(name).png"))
                let measurement = try metrics(result, reference: pixels, seconds: Date().timeIntervalSince(start))
                report[name] = measurement
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("metrics.json"))
                guard measurement["mae"]! > 0.1, measurement["mae"]! < (name == "gentle" ? 12 : 20) else {
                    throw NeuralError.invalidOutput
                }
            }
        }
        print(String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!)
    }
}
