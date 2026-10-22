import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct NeuralSmoke {
    static func main() async throws {
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
        guard output.width == 512, output.height == 512, mse.isFinite, mae > 0.1, mae < 45 else {
            throw NeuralError.invalidOutput
        }
        let out = root.appendingPathComponent("smoke")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
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
    }
}
