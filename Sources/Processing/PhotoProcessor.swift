import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProcessingStrength: String, CaseIterable, Identifiable, Sendable {
    case gentle, balanced, strong
    var id: Self { self }
    var title: String {
        switch self { case .gentle: "Бережно"; case .balanced: "Баланс"; case .strong: "Сильнее" }
    }
    var detail: String { "Без перерисовки. Распознанный текст и контрастные границы защищены." }
    var pixelLimit: Float {
        switch self { case .gentle: 3; case .balanced: 6; case .strong: 10 }
    }
    var attenuation: Float {
        switch self { case .gentle: 0.45; case .balanced: 0.65; case .strong: 0.85 }
    }
}

enum ProcessingMode: String, CaseIterable, Identifiable, Sendable {
    case pattern, metadata
    var id: Self { self }
    var title: String { self == .pattern ? "Паттерн" : "Метаданные" }
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
    case invalidImage, oversized, tooManyPixels, animated, encodeFailed, unsupported, textChanged
    var errorDescription: String? {
        switch self {
        case .invalidImage: "Не удалось прочитать фото. Попробуйте выбрать другой файл."
        case .oversized: "Файл больше 50 МБ. Выберите фото меньшего размера."
        case .tooManyPixels: "Фото больше 20 мегапикселей. Уменьшите его перед обработкой."
        case .animated: "Анимированные изображения не поддерживаются. Выберите обычное фото."
        case .encodeFailed: "Не удалось сохранить результат обработки. Попробуйте ещё раз."
        case .textChanged: "Проверка текста не пройдена. Попробуйте более бережный режим или очистку метаданных."
        case .unsupported: "Выберите фото JPEG, PNG, HEIC или WebP."
        }
    }
}

/// Owns all decoded pixels off the main actor. Only Sendable data crosses the boundary.
actor PhotoProcessor {
    private let context = CIContext(options: [.cacheIntermediates: false, .outputPremultiplied: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func stripMetadata(_ photo: ImportedPhoto, format: ExportFormat) throws -> ProcessedPhoto {
        try Task.checkCancellation()
        _ = try checkedSource(photo.data)
        let start = Date()
        let input = try orientedImage(photo.data)
        guard let image = context.createCGImage(input, from: input.extent.integral, format: .RGBA8, colorSpace: colorSpace)
        else { throw ProcessingError.invalidImage }
        let encoded = try exportImage(image, format: format)
        return ProcessedPhoto(data: encoded, preview: try preview(orientedImage(encoded)), width: image.width,
                              height: image.height, format: format, strength: .gentle, elapsed: Date().timeIntervalSince(start))
    }

    private func exportImage(_ image: CGImage, format: ExportFormat) throws -> Data {
        if format == .png { return try encode(image, format: format) }
        var pixels = PixelRaster.pixels(image)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[i + 3])
            for c in 0..<3 { pixels[i + c] = UInt8((Int(pixels[i + c]) * alpha + 255 * (255 - alpha)) / 255) }
            pixels[i + 3] = 255
        }
        return try encode(PixelRaster.image(pixels, width: image.width, height: image.height), format: format)
    }

    func load(_ data: Data) throws -> ImportedPhoto {
        let source = try checkedSource(data)
        let image = try orientedImage(data)
        let rect = image.extent.integral
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let alpha = properties?[kCGImagePropertyHasAlpha as String] as? Bool ?? false
        return ImportedPhoto(data: data, preview: try preview(image),
                             width: Int(rect.width), height: Int(rect.height), hasAlpha: alpha)
    }

    func process(_ photo: ImportedPhoto, strength: ProcessingStrength, format: ExportFormat,
                 progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> ProcessedPhoto {
        try Task.checkCancellation()
        let start = Date()
        _ = try checkedSource(photo.data)
        let input = try orientedImage(photo.data)
        guard let image = context.createCGImage(input, from: input.extent.integral, format: .RGBA8, colorSpace: colorSpace)
        else { throw ProcessingError.invalidImage }
        let result = try PatternProcessor.process(image, strength: strength, progress: progress)
        try Task.checkCancellation()
        progress(0.98, "Сохранение…")
        let encoded = try exportImage(result, format: format)
        try Task.checkCancellation()
        return ProcessedPhoto(data: encoded, preview: try preview(orientedImage(encoded)),
                              width: result.width, height: result.height, format: format,
                              strength: strength, elapsed: Date().timeIntervalSince(start))
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
