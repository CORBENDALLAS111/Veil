import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreML
import StableDiffusion
import Darwin

private struct MeanRandom: RandomSource {
    mutating func nextNormal(mean: Double, stdev: Double) -> Double { mean }
    mutating func normalShapedArray(_ shape: [Int], mean: Double, stdev: Double) -> MLShapedArray<Double> {
        MLShapedArray(scalars: Array(repeating: mean, count: shape.reduce(1, *)), shape: shape)
    }
}

@main struct NeuralSmoke {
    static func predict(_ model: MLModel, _ features: MLFeatureProvider) throws -> MLFeatureProvider {
        try autoreleasepool { try model.prediction(from: features) }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = NeuralModelStore(parent: root)
        let modelURL = try await store.install { value in
            if Int(value * 100) % 10 == 0 { print("Model download \(Int(value * 100))%") }
        }
        // Asymmetric synthetic scene; contains texture and a low-amplitude high-frequency perturbation.
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
        let planar = try input.planarRGBShapedArray(minValue: -1, maxValue: 1)
        var diagnostics: [String: Any] = ["planar_shape": planar.shape,
            "planar_first": Array(planar.scalars.prefix(5)), "planar_min": planar.scalars.min()!, "planar_max": planar.scalars.max()!]
        var planarError: Double = 0
        for i in 0..<(512 * 512) {
            for c in 0..<3 { planarError += abs(Double(planar.scalars[c * 512 * 512 + i]) - (Double(pixels[i * 4 + c]) / 127.5 - 1)) }
        }
        diagnostics["planar_mae"] = planarError / Double(512 * 512 * 3)
        print("PLANAR", planar.shape, planar.scalars.min()!, planar.scalars.max()!, Array(planar.scalars.prefix(5)))
        for (name, units) in [("cpu", MLComputeUnits.cpuOnly), ("ane", MLComputeUnits.cpuAndNeuralEngine)] {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            let encoder = Encoder(modelAt: modelURL.appendingPathComponent("VAEEncoder.mlmodelc"), configuration: configuration)
            var random: any RandomSource = MeanRandom()
            let latent = try encoder.encode(input, scaleFactor: 0.18215, random: &random)
            diagnostics["latent_\(name)"] = ["shape": latent.shape, "nonfinite": latent.scalars.filter { !$0.isFinite }.count,
                "first": Array(latent.scalars.prefix(10)).map { $0.isFinite ? Double($0) : -999999 },
                "min": Double(latent.scalars.filter(\.isFinite).min() ?? -999999),
                "max": Double(latent.scalars.filter(\.isFinite).max() ?? -999999)]
            print("VAE LATENT", name, latent.shape, latent.scalars.filter { !$0.isFinite }.count,
                  latent.scalars.min()!, latent.scalars.max()!, latent.scalars.reduce(0, +) / Float(latent.scalarCount))
            encoder.unloadResources()
            let decoder = Decoder(modelAt: modelURL.appendingPathComponent("VAEDecoder.mlmodelc"), configuration: configuration)
            let image = try decoder.decode([latent], scaleFactor: 0.18215)[0]
            decoder.unloadResources()
            let destination = CGImageDestinationCreateWithURL(out.appendingPathComponent("vae-\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw NeuralError.invalidOutput }
            if name == "cpu" {
                let encoderModel = try MLModel(contentsOf: modelURL.appendingPathComponent("VAEEncoder.mlmodelc"), configuration: configuration)
                let rawEncoder = try predict(encoderModel, MLDictionaryFeatureProvider(dictionary: ["z": MLMultiArray(planar)]))
                let encoderArray = rawEncoder.featureValue(for: "latent")!.multiArrayValue!
                let encoderValues = (0..<encoderArray.count).map { encoderArray[$0].floatValue }
                diagnostics["raw_encoder"] = ["shape": encoderArray.shape.map(\.intValue), "nonfinite": encoderValues.filter { !$0.isFinite }.count,
                    "first": Array(encoderValues.prefix(10)).map { $0.isFinite ? Double($0) : -999999 },
                    "min": Double(encoderValues.filter(\.isFinite).min() ?? -999999),
                    "max": Double(encoderValues.filter(\.isFinite).max() ?? -999999)]
                let model = try MLModel(contentsOf: modelURL.appendingPathComponent("VAEDecoder.mlmodelc"), configuration: configuration)
                let scaled = MLShapedArray<Float>(scalars: latent.scalars.map { $0 / 0.18215 }, shape: latent.shape)
                let prediction = try predict(model, MLDictionaryFeatureProvider(dictionary: ["z": MLMultiArray(scaled)]))
                let raw = prediction.featureValue(for: "image")!.multiArrayValue!
                let all = (0..<raw.count).map { raw[$0].floatValue }
                diagnostics["raw_decoder"] = ["shape": raw.shape.map(\.intValue), "nonfinite": all.filter { !$0.isFinite }.count,
                    "min": Double(all.filter(\.isFinite).min() ?? -999999), "max": Double(all.filter(\.isFinite).max() ?? -999999),
                    "first": Array(all.prefix(10)).map { $0.isFinite ? Double($0) : -999999 }]
                var manual = [UInt8](repeating: 255, count: 512 * 512 * 4)
                for i in 0..<(512 * 512) {
                    for c in 0..<3 {
                        let value = all[c * 512 * 512 + i]
                        manual[i * 4 + c] = value.isFinite ? UInt8(max(0, min(255, ((value + 1) * 127.5).rounded()))) : 0
                    }
                }
                let manualImage = try NeuralRaster.image(manual, width: 512, height: 512)
                let manualDestination = CGImageDestinationCreateWithURL(out.appendingPathComponent("vae-manual.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(manualDestination, manualImage, nil)
                _ = CGImageDestinationFinalize(manualDestination)
            }
            try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("diagnostics.json"))
            if ProcessInfo.processInfo.environment["VEIL_DIAGNOSTIC_ONLY"] == "1" { return }
        }
        let start = Date()
        let output = try NeuralRegenerator().process(input, modelURL: modelURL, strength: 0.12) { _, text in print(text) }
        let actual = NeuralRaster.pixels(output)
        var mse: Double = 0
        var mae: Double = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            for c in 0..<3 {
                let d = Double(actual[i + c]) - Double(pixels[i + c])
                mse += d * d
                mae += abs(d)
            }
        }
        mse /= Double(512 * 512 * 3)
        mae /= Double(512 * 512 * 3)
        for (name, image) in [("input.png", input), ("output.png", output)] {
            let destination = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw NeuralError.invalidOutput }
        }
        let metrics: [String: Any] = ["engine": "SD2.1 Core ML img2img", "strength": 0.12, "scheduleSteps": 50,
                                     "mae": mae, "psnr_db": 10 * log10(255 * 255 / mse), "seconds": Date().timeIntervalSince(start),
                                     "synthid_checked": false]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("metrics.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: metrics), encoding: .utf8)!)
        fflush(nil)
        guard output.width == 512, output.height == 512, mse.isFinite, mae > 0.1, mae < 12 else {
            throw NeuralError.invalidOutput
        }
    }
}
