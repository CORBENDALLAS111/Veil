@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct VideoSmoke {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let processor = VideoProcessor()
        let inputURL = try await VideoFixture.make(rotated: true, variableTiming: true)
        defer { VideoFiles.remove(inputURL) }
        let source = try await processor.load(inputURL)
        try FileManager.default.copyItem(at: inputURL, to: output.appendingPathComponent("original.mov"))
        try require(source.width == 128 && source.height == 192 && source.audioTracks == 1, "Invalid portrait fixture")
        let originalVideo = try await packets(inputURL, .video)
        let originalAudio = try await packets(inputURL, .audio)
        let originalImage = try await firstImage(inputURL)
        try saveImage(originalImage, output.appendingPathComponent("original.png"))
        var reports: [[String: Any]] = []
        for mode in ProcessingMode.allCases {
            let result = try await processor.process(source, mode: mode, strength: .strong)
            defer { VideoFiles.remove(result.url) }
            let video = try await packets(result.url, .video)
            let audio = try await packets(result.url, .audio)
            let asset = AVURLAsset(url: result.url)
            let duration = try await asset.load(.duration).seconds
            let raw: [String: Any] = ["mode": mode.rawValue, "processedFrames": result.frames,
                "sourceVideoPTS": originalVideo.times, "outputVideoPTS": video.times,
                "sourceAudioPTS": originalAudio.times, "outputAudioPTS": audio.times,
                "sourceAudioSHA256": originalAudio.digest, "outputAudioSHA256": audio.digest,
                "sourceDuration": source.duration, "outputDuration": duration]
            let diagnostic = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
            try diagnostic.write(to: output.appendingPathComponent("raw-\(mode.rawValue).json"))
            FileHandle.standardError.write(diagnostic)
            try FileManager.default.copyItem(at: result.url, to: output.appendingPathComponent("portrait-vfr-\(mode.rawValue).mov"))
            try require(video.times.count == originalVideo.times.count && result.frames == originalVideo.times.count, "Dropped video frames")
            try require(zip(video.times, originalVideo.times).allSatisfy { abs($0 - $1) < 0.0001 }, "Changed video timestamps")
            try require(audio.digest == originalAudio.digest, "Audio packets changed")
            try require(audio.times.count == originalAudio.times.count, "Audio packets dropped")
            try require(zip(audio.times, originalAudio.times).allSatisfy { abs($0 - $1) < 0.0001 }, "Changed audio timestamps")
            try require(abs(duration - source.duration) < 0.01, "Changed duration")
            let metadata = try await asset.load(.metadata)
            try require(metadata.isEmpty, "Copied source container metadata")
            let image = try await firstImage(result.url)
            try saveImage(image, output.appendingPathComponent("\(mode.rawValue).png"))
            try require(image.width == 128 && image.height == 192, "Incorrect portrait orientation")
            let before = PixelRaster.pixels(originalImage), after = PixelRaster.pixels(image)
            let mae = zip(before, after).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(before.count)
            try require(mae < 6, "Excessive codec/processing color or geometry error: \(mae)")
            if mode == .metadata { try require(video.digest == originalVideo.digest, "Metadata mode re-encoded video") }
            let recognized = try PatternProcessor.recognizeText(image).map(\.text)
            try require(recognized.joined().contains("2026"), "Lettering unreadable after video export")
            reports.append(["mode": mode.rawValue, "frames": result.frames, "videoPTSUnchanged": true,
                            "audioPacketsUnchanged": true, "audioPTSUnchanged": true, "containerMetadataEmpty": true,
                            "width": image.width, "height": image.height, "duration": duration,
                            "meanAbsoluteRGBAChangeAfterCodec": mae, "ocr": recognized,
                            "synthIDRemovalVerified": false, "seconds": result.elapsed])
        }
        let silentURL = try await VideoFixture.make(silent: true)
        defer { VideoFiles.remove(silentURL) }
        let silent = try await processor.load(silentURL)
        let silentResult = try await processor.process(silent, mode: .metadata, strength: .gentle)
        defer { VideoFiles.remove(silentResult.url) }
        try require(silentResult.audioTracks == 0 && silentResult.frames == 12, "Silent video failed")
        let json = try JSONSerialization.data(withJSONObject: ["cases": reports, "silentVideoPassed": true,
            "officialDetectorTested": false], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("video-metrics.json"))
        print(String(decoding: json, as: UTF8.self))
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            FileHandle.standardError.write(Data("VIDEO CHECK FAILED: \(message)\n".utf8))
            throw NSError(domain: "VeilVideoSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func saveImage(_ image: CGImage, _ url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw VideoError.write }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VideoError.write }
    }

    static func packets(_ url: URL, _ type: AVMediaType) async throws -> (digest: String, times: [Double]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: type).first else { return ("", []) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw VideoError.read }
        var hash = SHA256(), times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            // Marker-only buffers carry events, not media packets or frames.
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try require(time.isFinite, "Non-numeric timestamp on a media payload")
            times.append(time)
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard status == noErr else { throw VideoError.read }
            hash.update(data: data)
        }
        guard reader.status == .completed else { throw VideoError.read }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), times)
    }

    static func firstImage(_ url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: .zero).image
    }
}
