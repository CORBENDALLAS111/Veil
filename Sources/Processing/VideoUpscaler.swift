import CoreImage
import CoreVideo
import Foundation
import Metal

enum VideoOperation: String, CaseIterable, Identifiable, Sendable {
    case pattern, upscale, metadata
    var id: Self { self }
    var title: String { switch self { case .pattern: "Паттерн"; case .upscale: "Апскейл"; case .metadata: "Метаданные" } }
}

enum VideoResolution: String, CaseIterable, Identifiable, Sendable {
    case original, fullHD, fourK
    var id: Self { self }
    var title: String { switch self { case .original: "Исходный"; case .fullHD: "1080p"; case .fourK: "4K" } }
    func dimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        guard self != .original else { return (width, height) }
        let target = self == .fullHD ? 1920.0 : 3840.0
        let factor = max(1, target / Double(max(width, height)))
        return (Int((Double(width) * factor).rounded()), Int((Double(height) * factor).rounded()))
    }
}

/// One export owns this object on the video actor. Separable monotone cubic
/// interpolation on IOSurfaces, with a bounded optional low-contrast cleanup.
/// There is no learned reconstruction, frame blending or optical-flow warp.
final class VideoUpscaler {
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let horizontal: MTLComputePipelineState?
    private let vertical: MTLComputePipelineState?
    private let cleanup: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var intermediate: MTLTexture?
    private var cleaned: MTLTexture?
    private var pools: [String: CVPixelBufferPool] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])
    let backend: String
    let initializationError: String?

    init() {
        let gpu = MTLCreateSystemDefaultDevice()
        device = gpu
        do {
            guard let gpu, let commandQueue = gpu.makeCommandQueue() else { throw VideoError.unsupported }
            let options = MTLCompileOptions()
            options.fastMathEnabled = false
            let library = try gpu.makeLibrary(source: Self.source, options: options)
            guard let h = library.makeFunction(name: "horizontal"), let v = library.makeFunction(name: "vertical"),
                  let c = library.makeFunction(name: "cleanup") else { throw VideoError.unsupported }
            let hState = try gpu.makeComputePipelineState(function: h)
            let vState = try gpu.makeComputePipelineState(function: v)
            let cState = try gpu.makeComputePipelineState(function: c)
            horizontal = hState; vertical = vState; cleanup = cState
            queue = commandQueue
            backend = "Metal"
            initializationError = nil
        } catch {
            horizontal = nil; vertical = nil; cleanup = nil; queue = nil
            backend = "CPU"
            initializationError = error.localizedDescription
        }
    }

    func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let key = "\(width)x\(height)"
        if pools[key] == nil {
            var pool: CVPixelBufferPool?
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw VideoError.write }
            pools[key] = pool
        }
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pools[key]!, &result) == kCVReturnSuccess, let result else { throw VideoError.write }
        return result
    }

    func clearBuffers() {
        intermediate = nil; cleaned = nil; pools.removeAll()
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        context.clearCaches()
    }

    func render(_ input: CVPixelBuffer, to output: CVPixelBuffer, smoothBlocks: Bool,
                contentWidth: Int? = nil, contentHeight: Int? = nil) throws {
        try Task.checkCancellation()
        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        let outWidth = CVPixelBufferGetWidth(output), outHeight = CVPixelBufferGetHeight(output)
        let contentWidth = contentWidth ?? outWidth, contentHeight = contentHeight ?? outHeight
        guard outWidth >= width, outHeight >= height else { throw VideoError.dimensions }
        guard let device, let queue, let horizontal, let vertical, let cleanup else {
            let image = CIImage(cvPixelBuffer: input, options: [.colorSpace: PixelRaster.colorSpace])
            guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: PixelRaster.colorSpace) else { throw VideoError.read }
            var pixels = PixelRaster.pixels(cg)
            if smoothBlocks { try Self.cleanPixels(&pixels, width: width, height: height) }
            pixels = try DetailResampler.resize(pixels, width: width, height: height, outputWidth: contentWidth, outputHeight: contentHeight)
            let resized = try PixelRaster.image(pixels, width: contentWidth, height: contentHeight)
            context.render(CIImage(cgImage: resized).clampedToExtent(), to: output, bounds: CGRect(x: 0, y: 0, width: outWidth, height: outHeight), colorSpace: PixelRaster.colorSpace)
            return
        }
        if textureCache == nil {
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess else { throw VideoError.write }
        }
        guard let cache = textureCache else { throw VideoError.write }
        var sourceRef: CVMetalTexture?, outputRef: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderRead.rawValue | MTLTextureUsage.shaderWrite.rawValue] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, input, attributes, .bgra8Unorm, width, height, 0, &sourceRef) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, output, attributes, .bgra8Unorm, outWidth, outHeight, 0, &outputRef) == kCVReturnSuccess,
              let sourceRef, let outputRef, let sourceTexture = CVMetalTextureGetTexture(sourceRef), let destination = CVMetalTextureGetTexture(outputRef),
              let command = queue.makeCommandBuffer() else { throw VideoError.write }
        if intermediate?.width != outWidth || intermediate?.height != height {
            intermediate = try texture(device, width: outWidth, height: height, format: .rgba32Float)
        }
        guard let intermediate else { throw VideoError.write }
        var source = sourceTexture
        if smoothBlocks {
            if cleaned?.width != width || cleaned?.height != height { cleaned = try texture(device, width: width, height: height, format: .rgba8Unorm) }
            guard let cleaned else { throw VideoError.write }
            try encode(command, pipeline: cleanup, input: sourceTexture, output: cleaned, width: contentWidth, height: contentHeight)
            source = cleaned
        }
        try encode(command, pipeline: horizontal, input: source, output: intermediate, width: contentWidth, height: contentHeight)
        try encode(command, pipeline: vertical, input: intermediate, output: destination, width: contentWidth, height: contentHeight)
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime((sourceRef, outputRef)) {}
        guard command.status == .completed else { throw VideoError.write }
        try Task.checkCancellation()
    }

    private func texture(_ device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat) throws -> MTLTexture {
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        description.usage = [.shaderRead, .shaderWrite]
        description.storageMode = .private
        guard let texture = device.makeTexture(descriptor: description) else { throw VideoError.write }
        return texture
    }

    private func encode(_ command: MTLCommandBuffer, pipeline: MTLComputePipelineState, input: MTLTexture, output: MTLTexture, width: Int, height: Int) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw VideoError.write }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0); encoder.setTexture(output, index: 1)
        var size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)
        let w = pipeline.threadExecutionWidth
        let h = min(8, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
    }

    static func cleanPixels(_ pixels: inout [UInt8], width: Int, height: Int) throws {
        let source = pixels
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let p = (y * width + x) * 4
                guard source[p + 3] == 255 else { continue }
                var low: Float = 255, high: Float = 0, mean: Float = 0
                for dy in -1...1 { for dx in -1...1 {
                    let q = (max(0, min(height - 1, y + dy)) * width + max(0, min(width - 1, x + dx))) * 4
                    let value = 0.299 * Float(source[q]) + 0.587 * Float(source[q + 1]) + 0.114 * Float(source[q + 2])
                    low = min(low, value); high = max(high, value); mean += value / 9
                } }
                guard high - low < 12 else { continue }
                let center = 0.299 * Float(source[p]) + 0.587 * Float(source[p + 1]) + 0.114 * Float(source[p + 2])
                let boundLow = -Int(min(source[p], min(source[p + 1], source[p + 2])))
                let boundHigh = 255 - Int(max(source[p], max(source[p + 1], source[p + 2])))
                let delta = max(boundLow, min(boundHigh, Int(max(-1, min(1, (mean - center) * 0.45)).rounded())))
                for c in 0..<3 { pixels[p + c] = UInt8(Int(source[p + c]) + delta) }
            }
        }
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    float4 monotone(float4 a, float4 b, float4 c, float4 d, float t) {
        float4 l = b-a, m = c-b, r = d-c;
        float4 t0 = select(float4(0), 2*l*m / select(float4(1), l+m, l*m>0), l*m>0);
        float4 t1 = select(float4(0), 2*m*r / select(float4(1), m+r, m*r>0), m*r>0);
        float t2=t*t, t3=t2*t;
        return clamp((2*t3-3*t2+1)*b+(t3-2*t2+t)*t0+(-2*t3+3*t2)*c+(t3-t2)*t1, min(b,c), max(b,c));
    }
    float4 pixel(texture2d<float, access::read> s, int2 p) {
        return s.read(uint2(clamp(p, int2(0), int2(s.get_width()-1,s.get_height()-1))));
    }
    float4 premult(texture2d<float, access::read> s, int2 p) { float4 v=pixel(s,p); return float4(v.rgb*v.a,v.a); }
    kernel void horizontal(texture2d<float, access::read> s [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], constant uint2 &size [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if(p.x>=o.get_width() || p.y>=o.get_height()) return;
        float x=clamp((float(min(p.x,size.x-1))+0.5f)*float(s.get_width())/float(size.x)-0.5f,0.0f,float(s.get_width()-1));
        int b=int(x); float t=x-float(b);
        o.write(monotone(premult(s,int2(b-1,p.y)),premult(s,int2(b,p.y)),premult(s,int2(b+1,p.y)),premult(s,int2(b+2,p.y)),t),p);
    }
    kernel void vertical(texture2d<float, access::read> s [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], constant uint2 &size [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if(p.x>=o.get_width() || p.y>=o.get_height()) return;
        float y=clamp((float(min(p.y,size.y-1))+0.5f)*float(s.get_height())/float(size.y)-0.5f,0.0f,float(s.get_height()-1));
        int b=int(y); float t=y-float(b);
        float4 v=monotone(pixel(s,int2(p.x,b-1)),pixel(s,int2(p.x,b)),pixel(s,int2(p.x,b+1)),pixel(s,int2(p.x,b+2)),t);
        o.write(float4(v.a>0.000001f ? clamp(v.rgb/v.a,0.0f,1.0f) : float3(0),clamp(v.a,0.0f,1.0f)),p);
    }
    kernel void cleanup(texture2d<float, access::read> s [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
        if(p.x>=o.get_width() || p.y>=o.get_height()) return;
        float4 v=pixel(s,int2(p)); float lo=1,hi=0,mean=0;
        for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) { float l=dot(pixel(s,int2(p)+int2(x,y)).rgb,float3(0.299f,0.587f,0.114f)); lo=min(lo,l);hi=max(hi,l);mean+=l/9; }
        if(hi-lo<12.0f/255.0f && v.a>0.999f) {
            float l=dot(v.rgb,float3(0.299f,0.587f,0.114f));
            float delta=round(clamp((mean-l)*0.45f*255.0f,-1.0f,1.0f))/255.0f;
            delta=clamp(delta,-min(v.r,min(v.g,v.b)),1-max(v.r,max(v.g,v.b)));
            v.rgb+=delta;
        }
        o.write(v,p);
    }
    """
}
