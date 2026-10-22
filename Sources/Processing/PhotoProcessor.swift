import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProcessingStrength: String, CaseIterable, Identifiable, Sendable {
    case gentle, balanced, strong
    var id: Self { self }
    var title: String {
        switch self { case .gentle: "Бережно"; case .balanced: "Баланс"; case .strong: "Сильнее" }
    }
    var detail: String {
        switch self {
        case .gentle: "Мягкое подавление шума. Больше мелких деталей."
        case .balanced: "Шумоподавление и обработка частотных паттернов."
        case .strong: "Более заметная обработка. Текстуры могут стать мягче."
        }
    }
    var threshold: Float {
        switch self { case .gentle: 1.2; case .balanced: 2.8; case .strong: 5.0 }
    }
    var noiseLevel: Float {
        switch self { case .gentle: 0.008; case .balanced: 0.018; case .strong: 0.035 }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg
    var id: Self { self }
    var title: String { rawValue.uppercased() }
    var type: UTType { self == .png ? .png : .jpeg }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

struct ImportedPhoto: Sendable {
    let data: Data
    let preview: Data
    let width: Int
    let height: Int
    let hasAlpha: Bool
}

struct ProcessedPhoto: Sendable {
    let data: Data
    let preview: Data
    let width: Int
    let height: Int
    let format: ExportFormat
    let strength: ProcessingStrength
    let elapsed: TimeInterval
}

enum ProcessingError: LocalizedError {
    case invalidImage, oversized, tooManyPixels, animated, encodeFailed, unsupported
    var errorDescription: String? {
        switch self {
        case .invalidImage: "Не удалось прочитать фото. Попробуйте выбрать другой файл."
        case .oversized: "Файл больше 50 МБ. Выберите фото меньшего размера."
        case .tooManyPixels: "Фото больше 20 мегапикселей. Уменьшите его перед обработкой."
        case .animated: "Анимированные изображения не поддерживаются. Выберите обычное фото."
        case .encodeFailed: "Не удалось сохранить результат обработки. Попробуйте ещё раз."
        case .unsupported: "Выберите фото JPEG, PNG, HEIC или WebP."
        }
    }
}

/// Owns all decoded pixels off the main actor. Only Sendable data crosses the boundary.
actor PhotoProcessor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func load(_ data: Data) throws -> ImportedPhoto {
        let source = try checkedSource(data)
        let image = try orientedImage(data)
        let rect = image.extent.integral
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let alpha = properties?[kCGImagePropertyHasAlpha as String] as? Bool ?? false
        return ImportedPhoto(data: data, preview: try preview(image),
                             width: Int(rect.width), height: Int(rect.height), hasAlpha: alpha)
    }

    func process(_ photo: ImportedPhoto, strength: ProcessingStrength, format: ExportFormat) throws -> ProcessedPhoto {
        try Task.checkCancellation()
        let start = Date()
        _ = try checkedSource(photo.data)
        let original = try orientedImage(photo.data)
        let rect = original.extent.integral
        let width = Int(rect.width)
        let height = Int(rect.height)
        let filter = CIFilter.noiseReduction()
        filter.inputImage = original.clampedToExtent()
        filter.noiseLevel = strength.noiseLevel
        filter.sharpness = 0.35
        guard let filtered = filter.outputImage?.cropped(to: rect) else { throw ProcessingError.invalidImage }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { storage in
            context.render(filtered, toBitmap: storage.baseAddress!, rowBytes: width * 4,
                           bounds: rect, format: .RGBA8, colorSpace: colorSpace)
        }
        // CI bitmap output is premultiplied; process straight color, keeping alpha.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            if alpha > 0 && alpha < 255 {
                for c in 0..<3 { pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / alpha)) }
            }
        }
        try WaveletDenoiser.reduce(pixels: &pixels, width: width, height: height, threshold: strength.threshold)
        try Task.checkCancellation()
        if format == .jpeg {
            // JPEG has no alpha: composite on white explicitly, rather than on black.
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[i + 3])
                for c in 0..<3 { pixels[i + c] = UInt8((Int(pixels[i + c]) * alpha + 255 * (255 - alpha)) / 255) }
                pixels[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ProcessingError.encodeFailed }
        let encoded = try encode(cgImage, format: format)
        try Task.checkCancellation()
        // Preview the actual encoded output (including JPEG losses).
        let outputImage = try orientedImage(encoded)
        return ProcessedPhoto(data: encoded, preview: try preview(outputImage), width: width, height: height,
                              format: format, strength: strength, elapsed: Date().timeIntervalSince(start))
    }

    private func checkedSource(_ data: Data) throws -> CGImageSource {
        guard data.count <= 50 * 1_024 * 1_024 else { throw ProcessingError.oversized }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else { throw ProcessingError.invalidImage }
        let supported = [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, "public.heif", UTType.webP.identifier]
        guard supported.contains(type) else { throw ProcessingError.unsupported }
        guard CGImageSourceGetCount(source) == 1 else { throw ProcessingError.animated }
        guard let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = info[kCGImagePropertyPixelWidth as String] as? Int,
              let h = info[kCGImagePropertyPixelHeight as String] as? Int,
              w > 0, h > 0 else { throw ProcessingError.invalidImage }
        guard w <= 20_000, h <= 20_000, w * h <= 20_000_000 else { throw ProcessingError.tooManyPixels }
        return source
    }

    private func orientedImage(_ data: Data) throws -> CIImage {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
              !image.extent.isEmpty, !image.extent.isInfinite else { throw ProcessingError.invalidImage }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private func preview(_ image: CIImage) throws -> Data {
        let scale = min(1, 1_400 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let rendered = context.createCGImage(small, from: small.extent.integral,
                                                   format: .RGBA8, colorSpace: colorSpace) else { throw ProcessingError.invalidImage }
        return try encode(rendered, format: .png)
    }

    private func encode(_ image: CGImage, format: ExportFormat) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.type.identifier as CFString, 1, nil)
        else { throw ProcessingError.encodeFailed }
        // Intentionally construct a fresh container; never copy source EXIF, GPS,
        // XMP, IPTC or C2PA properties. ICC/sRGB is output color information.
        let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.97] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProcessingError.encodeFailed }
        return output as Data
    }
}
