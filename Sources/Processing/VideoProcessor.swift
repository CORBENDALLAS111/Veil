@preconcurrency import AVFoundation
import CoreImage
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImportedMovieFile: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            Self(url: try VideoFiles.copy(received.file))
        }
    }
}

enum VideoFiles {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Veil-Videos", isDirectory: true)
    static func destination(_ suffix: String = "mov") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Veil-\(UUID().uuidString).\(suffix)")
    }
    static func copy(_ source: URL) throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 2_000_000_000 else { throw VideoError.fileSize }
        let url = try destination(source.pathExtension.isEmpty ? "mov" : source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: url)
            try Task.checkCancellation()
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    static func remove(_ url: URL?) {
        guard let url, url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

struct ImportedVideo: Sendable {
    let url: URL
    let preview: Data
    let width: Int
    let height: Int
    let duration: Double
    let framesPerSecond: Float
    let audioTracks: Int
    let patternSupported: Bool
}

struct ProcessedVideo: Sendable {
    let url: URL
    let width: Int
    let height: Int
    let duration: Double
    let frames: Int
    let audioTracks: Int
    let elapsed: Double
}

enum VideoError: LocalizedError {
    case fileSize, invalid, unsupported, hdr, dimensions, read, write, empty, stalled
    var errorDescription: String? {
        switch self {
        case .fileSize: "Выберите видео размером до 2 ГБ."
        case .invalid: "Не удалось открыть видео. Выберите MOV или MP4 с одной видеодорожкой."
        case .unsupported: "Формат дорожки не поддерживается. Попробуйте обычное видео H.264 или HEVC со звуком AAC."
        case .hdr: "Паттерн пока поддерживает только SDR-видео. Для HDR доступна очистка метаданных без изменения кадров."
        case .dimensions: "Обработка кадров поддерживает видео до 3840 × 2160, включая вертикальное."
        case .read: "Не удалось прочитать все кадры видео. Результат не сохранён."
        case .write: "Не удалось записать видео. Проверьте свободное место."
        case .empty: "В видео нет доступных кадров."
        case .stalled: "Кодировщик видео перестал отвечать. Попробуйте ещё раз."
        }
    }
}

/// Smooth only the small filter correction, never the source frames. Motion,
/// scene cuts, new text masks and a zero current correction reset the history.
struct VideoCorrectionStabilizer {
    private var previousLuma: [UInt8] = []
    private var previousDelta: [Int8] = []

    mutating func apply(_ result: inout [UInt8], source: [UInt8]) {
        let count = source.count / 4
        let hasHistory = previousLuma.count == count
        var luma = [UInt8](repeating: 0, count: count)
        var delta = [Int8](repeating: 0, count: count)
        for i in 0..<count {
            let p = i * 4
            luma[i] = UInt8((Int(source[p]) * 77 + Int(source[p + 1]) * 150 + Int(source[p + 2]) * 29) >> 8)
            let current = Int(result[p]) - Int(source[p])
            var correction = current
            if hasHistory, current != 0, abs(Int(luma[i]) - Int(previousLuma[i])) <= 3 {
                let mixed = Int((0.65 * Double(previousDelta[i]) + 0.35 * Double(current)).rounded())
                correction = current > 0 ? max(0, min(current, mixed)) : min(0, max(current, mixed))
            }
            // The same bounded offset is applied to RGB by PatternProcessor.
            for c in 0..<3 { result[p + c] = UInt8(Int(source[p + c]) + correction) }
            delta[i] = Int8(correction)
        }
        previousLuma = luma
        previousDelta = delta
    }
}

/// A file-backed, sequential reader/writer. Decoded frames never cross to the
/// main actor; original compressed audio packets are muxed without re-encoding.
actor VideoProcessor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var cachedUpscaler: VideoUpscaler?

    func copyImport(_ url: URL) throws -> URL { try VideoFiles.copy(url) }

    func load(_ url: URL) async throws -> ImportedVideo {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard videos.count == 1, let track = videos.first,
              try await asset.load(.isReadable) else { throw VideoError.invalid }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform).standardized
        guard duration.isFinite, duration > 0, rect.width > 0, rect.height > 0 else { throw VideoError.invalid }
        let descriptions = try await track.load(.formatDescriptions)
        for type in [AVMediaType.subtitle, .closedCaption, .text] {
            guard try await asset.loadTracks(withMediaType: type).isEmpty else { throw VideoError.unsupported }
        }
        let supported = !Self.isHDR(descriptions)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        let thumbnail = try await generator.image(at: .zero).image
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw VideoError.invalid }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw VideoError.invalid }
        try Task.checkCancellation()
        return ImportedVideo(url: url, preview: output as Data, width: Int(rect.width.rounded()), height: Int(rect.height.rounded()),
                             duration: duration, framesPerSecond: try await track.load(.nominalFrameRate),
                             audioTracks: try await asset.loadTracks(withMediaType: .audio).count, patternSupported: supported)
    }

    private static func isHDR(_ descriptions: [CMFormatDescription]) -> Bool {
        descriptions.contains { description in
            let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        }
    }

    func process(_ video: ImportedVideo, mode: VideoOperation, strength: ProcessingStrength,
                 clarity: Bool = false, resolution: VideoResolution = .original, smoothBlocks: Bool = false,
                 progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> ProcessedVideo {
        try Task.checkCancellation()
        let started = Date()
        let asset = AVURLAsset(url: video.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { throw VideoError.invalid }
        let duration = try await asset.load(.duration)
        let transform = try await track.load(.preferredTransform)
        let descriptions = try await track.load(.formatDescriptions)
        if mode != .metadata {
            guard !Self.isHDR(descriptions) else { throw VideoError.hdr }
            guard max(video.width, video.height) <= 3840, video.width * video.height <= 3840 * 2160 else { throw VideoError.dimensions }
        }
        let requested = mode != .metadata ? resolution.dimensions(width: video.width, height: video.height) : (video.width, video.height)
        // H.264 4:2:0 requires even dimensions. At most one padded edge pixel;
        // no aspect-ratio stretch of the filtered image.
        let width = mode != .metadata ? (requested.0 + 1) / 2 * 2 : requested.0
        let height = mode != .metadata ? (requested.1 + 1) / 2 * 2 : requested.1
        let needsUpscale = mode != .metadata && (width != video.width || height != video.height || smoothBlocks)
        if needsUpscale && cachedUpscaler == nil { cachedUpscaler = VideoUpscaler() }
        nonisolated(unsafe) let frameUpscaler = needsUpscale ? cachedUpscaler : nil
        // AV track transforms use top-left video coordinates; Core Image uses
        // bottom-left coordinates. Conjugate by a vertical flip and normalize
        // the translated extent per frame below.
        let imageTransform = CGAffineTransform(a: transform.a, b: -transform.b, c: -transform.c,
                                               d: transform.d, tx: transform.tx, ty: -transform.ty)
        let reader = try AVAssetReader(asset: asset)
        let outputURL = try VideoFiles.destination()
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        var completed = false
        defer {
            if !completed {
                reader.cancelReading()
                writer.cancelWriting()
                VideoFiles.remove(outputURL)
            }
            context.clearCaches()
            cachedUpscaler?.clearBuffers()
        }
        writer.metadata = []
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: mode != .metadata ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] : nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoError.unsupported }
        reader.add(videoOutput)
        let fps = max(1, min(120, Double(video.framesPerSecond > 0 ? video.framesPerSecond : 30)))
        let settings: [String: Any]? = mode != .metadata ? [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(max(8_000_000, min(120_000_000, Double(width * height) * fps * 0.28))),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false
            ],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ] : nil
        if let settings, !writer.canApply(outputSettings: settings, forMediaType: .video) { throw VideoError.unsupported }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: mode == .metadata ? descriptions.first : nil)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = mode == .metadata ? transform : .identity
        videoInput.mediaTimeScale = try await track.load(.naturalTimeScale)
        guard writer.canAdd(videoInput) else { throw VideoError.unsupported }
        writer.add(videoInput)
        let adaptor = mode != .metadata ? AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true
        ]) : nil

        var audio: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, finished: Bool)] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first else { throw VideoError.unsupported }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw VideoError.unsupported }
            reader.add(output); writer.add(input)
            audio.append((output, input, false))
        }
        guard writer.startWriting(), reader.startReading() else { throw VideoError.unsupported }
        writer.startSession(atSourceTime: .zero)
        progress(0, mode == .pattern ? "Защита текста в кадрах…" : (mode == .upscale ? "Апскейл видео…" : "Копирование дорожек…"))
        var frames = 0, videoFinished = false
        var stabilizer = VideoCorrectionStabilizer()
        var lastActivity = Date()
        while !videoFinished || audio.contains(where: { !$0.finished }) {
            try Task.checkCancellation()
            guard writer.status == .writing, reader.status != .failed else { throw VideoError.write }
            var advanced = false
            if !videoFinished, videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    // Reader outputs may contain marker-only buffers carrying
                    // timing/end-of-stream attachments, with invalid PTS and
                    // no image. Forward the state change, not a fake frame.
                    if CMSampleBufferGetImageBuffer(sample) == nil && CMSampleBufferGetDataBuffer(sample) == nil {
                        guard videoInput.append(sample) else { throw VideoError.write }
                        lastActivity = Date()
                        continue
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard pts.isValid, pts.seconds.isFinite else { throw VideoError.read }
                    if let adaptor {
                        guard let buffer = CMSampleBufferGetImageBuffer(sample), let pool = adaptor.pixelBufferPool else { throw VideoError.read }
                        // Foundation's pool closure is synchronous, but its
                        // pre-concurrency declaration lacks actor inheritance.
                        // These borrowed references never leave this actor or
                        // outlive the synchronous frame below.
                        nonisolated(unsafe) let frameBuffer = buffer
                        nonisolated(unsafe) let framePool = pool
                        let sampleDuration = CMSampleBufferGetDuration(sample).seconds
                        let frameNumber = frames + 1
                        let base = max(0, pts.seconds / duration.seconds * 0.96)
                        let span = (sampleDuration.isFinite && sampleDuration > 0 ? sampleDuration : 1 / fps) / duration.seconds * 0.96
                        let encoded = try autoreleasepool {
                            let input = CIImage(cvPixelBuffer: frameBuffer).transformed(by: imageTransform)
                            let upright = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
                            let processed: CIImage
                            if mode == .pattern {
                                guard let image = context.createCGImage(upright, from: upright.extent.integral, format: .RGBA8, colorSpace: colorSpace) else { throw VideoError.read }
                                let source = PixelRaster.pixels(image)
                                var pixels = source
                                try PatternProcessor.processPixels(&pixels, image: image, strength: strength, clarity: clarity) { partial, _ in
                                    let value = min(0.96, base + span * partial * 0.9)
                                    progress(value, "Кадр \(frameNumber)")
                                }
                                stabilizer.apply(&pixels, source: source)
                                processed = CIImage(cgImage: try PixelRaster.image(pixels, width: image.width, height: image.height))
                            } else {
                                // Upscale-only skips OCR, FFT, bitmap arrays
                                // and the watermark correction entirely.
                                processed = upright
                            }
                            var encoded: CVPixelBuffer?
                            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, framePool, &encoded) == kCVReturnSuccess,
                                  let encoded else { throw VideoError.write }
                            // Clamp only the possible one-pixel codec padding.
                            if let frameUpscaler {
                                let source = try frameUpscaler.buffer(width: video.width, height: video.height)
                                context.render(processed, to: source, bounds: CGRect(x: 0, y: 0, width: video.width, height: video.height), colorSpace: colorSpace)
                                try frameUpscaler.render(source, to: encoded, smoothBlocks: smoothBlocks,
                                                         contentWidth: requested.0, contentHeight: requested.1)
                            } else {
                                context.render(processed.clampedToExtent(), to: encoded,
                                               bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
                            }
                            // Describe the rendered RGB pixels explicitly so
                            // AVAssetWriter converts sRGB to the requested
                            // Rec.709 output once, rather than guessing gamma.
                            CVBufferSetAttachment(encoded, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
                            CVBufferSetAttachment(encoded, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                            CVBufferSetAttachment(encoded, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
                            return encoded
                        }
                        try Task.checkCancellation()
                        guard adaptor.append(encoded, withPresentationTime: pts) else { throw VideoError.write }
                    } else if !videoInput.append(sample) { throw VideoError.write }
                    frames += 1
                    let sampleDuration = CMSampleBufferGetDuration(sample).seconds
                    let end = pts.seconds + (sampleDuration.isFinite && sampleDuration > 0 ? sampleDuration : 1 / fps)
                    let fraction = min(0.96, max(0, end / duration.seconds * 0.96))
                    progress(fraction, "Кадр \(frames)")
                    advanced = true
                } else { videoFinished = true; videoInput.markAsFinished(); advanced = true }
            }
            // Interleave audio and video to respect writer backpressure. Never
            // buffer an entire soundtrack or silently discard an audio track.
            for i in audio.indices where !audio[i].finished && audio[i].input.isReadyForMoreMediaData {
                if let sample = audio[i].output.copyNextSampleBuffer() {
                    guard audio[i].input.append(sample) else { throw VideoError.write }
                } else { audio[i].finished = true; audio[i].input.markAsFinished() }
                advanced = true
            }
            if advanced { lastActivity = Date() }
            else {
                guard Date().timeIntervalSince(lastActivity) < 60 else { throw VideoError.stalled }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        guard reader.status == .completed, frames > 0 else { throw VideoError.read }
        try Task.checkCancellation()
        progress(0.98, "Завершение видео…")
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw VideoError.write }
        completed = true
        progress(1, "Готово")
        return ProcessedVideo(url: outputURL, width: width, height: height, duration: duration.seconds,
                              frames: frames, audioTracks: audio.count, elapsed: Date().timeIntervalSince(started))
    }
}
