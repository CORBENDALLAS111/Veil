@preconcurrency import AVFoundation
import CryptoKit
import Foundation

@main struct VideoSmoke {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let processor = VideoProcessor()
        let inputURL = try await VideoFixture.make(rotated: true, variableTiming: true)
        defer { VideoFiles.remove(inputURL) }
        let source = try await processor.load(inputURL)
        precondition(source.width == 128 && source.height == 192 && source.audioTracks == 1)
        let originalVideo = try await packets(inputURL, .video)
        let originalAudio = try await packets(inputURL, .audio)
        let originalImage = try await firstImage(inputURL)
        var reports: [[String: Any]] = []
        for mode in ProcessingMode.allCases {
            let result = try await processor.process(source, mode: mode, strength: .strong)
            defer { VideoFiles.remove(result.url) }
            let video = try await packets(result.url, .video)
            let audio = try await packets(result.url, .audio)
            let asset = AVURLAsset(url: result.url)
            let duration = try await asset.load(.duration).seconds
            precondition(video.times.count == originalVideo.times.count && result.frames == originalVideo.times.count, "Dropped video frames")
            precondition(zip(video.times, originalVideo.times).allSatisfy { abs($0 - $1) < 0.0001 }, "Changed video timestamps")
            precondition(audio.digest == originalAudio.digest, "Audio packets changed")
            precondition(audio.times.count == originalAudio.times.count, "Audio packets dropped")
            precondition(zip(audio.times, originalAudio.times).allSatisfy { abs($0 - $1) < 0.0001 }, "Changed audio timestamps")
            precondition(abs(duration - source.duration) < 0.01, "Changed duration")
            let metadata = try await asset.load(.metadata)
            precondition(metadata.isEmpty, "Copied source container metadata")
            let image = try await firstImage(result.url)
            precondition(image.width == 128 && image.height == 192, "Incorrect portrait orientation")
            let before = PixelRaster.pixels(originalImage), after = PixelRaster.pixels(image)
            let mae = zip(before, after).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(before.count)
            precondition(mae < 6, "Excessive codec/processing color or geometry error: \(mae)")
            if mode == .metadata { precondition(video.digest == originalVideo.digest, "Metadata mode re-encoded video") }
            let recognized = try PatternProcessor.recognizeText(image).map(\.text)
            precondition(recognized.joined().contains("2026"), "Lettering unreadable after video export")
            try FileManager.default.copyItem(at: result.url, to: output.appendingPathComponent("portrait-vfr-\(mode.rawValue).mov"))
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
        precondition(silentResult.audioTracks == 0 && silentResult.frames == 12, "Silent video failed")
        let json = try JSONSerialization.data(withJSONObject: ["cases": reports, "silentVideoPassed": true,
            "officialDetectorTested": false], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("video-metrics.json"))
        print(String(decoding: json, as: UTF8.self))
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
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var data = Data(count: CMBlockBufferGetDataLength(block))
                let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                guard status == noErr else { throw VideoError.read }
                hash.update(data: data)
            }
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
