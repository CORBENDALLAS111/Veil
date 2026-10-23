import CoreImage
import Foundation

enum PixelRaster {
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
        else { throw ProcessingError.encodeFailed }
        return image
    }
}
