#if DEBUG
@preconcurrency import AVFoundation
import CoreText
import Foundation

/// Generated test media only. Excluded from release builds by DEBUG, with no
/// external clips, personal content or model payloads.
enum VideoFixture {
    static func make(rotated: Bool = false, variableTiming: Bool = false, silent: Bool = false) async throws -> URL {
        let url = try VideoFiles.destination()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var complete = false
        defer { if !complete { writer.cancelWriting(); VideoFiles.remove(url) } }
        let width = 192, height = 128
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoAllowFrameReorderingKey: false]])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
        if !silent { writer.add(audio) }
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "VEIL-PRIVATE-TEST-TITLE" as NSString
        writer.metadata = [title]
        guard writer.startWriting() else { throw VideoError.write }
        writer.startSession(atSourceTime: .zero)
        let timestamps: [Int64] = variableTiming ? [0, 40, 110, 160, 250, 350, 460, 550] : (0..<12).map { Int64($0 * 50) }
        for (index, time) in timestamps.enumerated() {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw VideoError.write }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { throw VideoError.write }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer else { throw VideoError.write }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer), let drawing = CGContext(data: base, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
                drawing.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.65, alpha: 1))
                drawing.fill(CGRect(x: 0, y: 0, width: width, height: height))
                drawing.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.05, alpha: 1))
                drawing.fillEllipse(in: CGRect(x: 12 + index * 4, y: 16, width: 28, height: 28))
                let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
                let text = NSAttributedString(string: "VEIL 2026", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
                drawing.textPosition = CGPoint(x: 12, y: 86)
                CTLineDraw(CTLineCreateWithAttributedString(text), drawing)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: time, timescale: 600)) else { throw VideoError.write }
        }
        input.markAsFinished()
        if !silent {
            while !audio.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw VideoError.write }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard audio.append(try tone()) else { throw VideoError.write }
            audio.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw VideoError.write }
        complete = true
        return url
    }

    private static func tone() throws -> CMSampleBuffer {
        let rate = 48_000, count = 48_000
        let samples = (0..<count).map { Float(0.1 * sin(2 * .pi * 440 * Double($0) / Double(rate))) }
        var description = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw VideoError.write }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count * 4,
            flags: 0, blockBufferOut: &block) == noErr, let block else { throw VideoError.write }
        let status = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard status == noErr else { throw VideoError.write }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else { throw VideoError.write }
        return sample
    }
}
#endif
