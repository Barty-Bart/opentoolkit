
// Synthetic regression harness appended to the module so it can inspect private
// writer state without exposing test-only entry points in the application.
extension RecordingEngine {
    static func synthetic(output: URL, microphone: Bool) async throws -> RecordingEngine {
        let engine = try RecordingEngine(output: output, dimensions: CGSize(width: 320, height: 180), includeMicrophone: microphone)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            engine.queue.async {
                do {
                    guard engine.writer.startWriting() else { throw engine.writer.error! }
                    let start = CMClockGetTime(CMClockGetHostTimeClock())
                    engine.writer.startSession(atSourceTime: start)
                    engine.sessionStart = start
                    var image: CVPixelBuffer?
                    let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
                    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &image) == kCVReturnSuccess)
                    let pixel = image!
                    CVPixelBufferLockBaseAddress(pixel, [])
                    memset(CVPixelBufferGetBaseAddress(pixel), 100, CVPixelBufferGetBytesPerRow(pixel) * 180)
                    CVPixelBufferUnlockBaseAddress(pixel, [])
                    var format: CMVideoFormatDescription?
                    precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr)
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: start, decodeTimeStamp: .invalid)
                    var sample: CMSampleBuffer?
                    precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
                    guard engine.video.append(sample!) else { throw engine.writer.error! }
                    engine.videoFrames = 1; engine.lastVideoTime = start; engine.lastVideoSample = sample
                    let system = try makeSyntheticAudio(channels: 2, frequency: 440, start: start)
                    while !engine.systemAudio.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
                    guard engine.systemAudio.append(system) else { throw engine.writer.error! }
                    engine.systemAudioFrames = 1
                    if let input = engine.microphone {
                        let mic = try makeSyntheticAudio(channels: 1, frequency: 660, start: start)
                        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
                        guard input.append(mic) else { throw engine.writer.error! }
                        engine.micFrames = 1
                    }
                    done.resume()
                } catch { done.resume(throwing: error) }
            }
        }
        return engine
    }

    static func empty(output: URL) async throws -> RecordingEngine {
        let engine = try RecordingEngine(output: output, dimensions: CGSize(width: 320, height: 180), includeMicrophone: false)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            engine.queue.async { precondition(engine.writer.startWriting()); done.resume() }
        }
        return engine
    }
}

private func makeSyntheticAudio(channels: Int, frequency: Double, start: CMTime) throws -> CMSampleBuffer {
    let frames = 8192
    let floats = (0..<(frames * channels)).map { index in Float(sin(Double(index / channels) * frequency * 2 * .pi / 48_000) * 0.1) }
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
    var block: CMBlockBuffer?
    precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: floats.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: floats.count * 4, flags: 0, blockBufferOut: &block) == noErr)
    floats.withUnsafeBytes { bytes in
        precondition(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) == noErr)
    }
    var sample: CMSampleBuffer?
    precondition(CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
        dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format!, sampleCount: frames,
        presentationTimeStamp: start, packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
    return sample!
}

@main
struct RecordingRegressionTests {
    static func main() async throws {
        let frame = CGRect(x: -1440, y: 400, width: 1440, height: 900)
        let region = CGRect(x: -1300, y: 900, width: 500, height: 300)
        precondition(RecordingGeometry.sourceRect(region: region, screenFrame: frame) == CGRect(x: 140, y: 100, width: 500, height: 300))
        let size = RecordingGeometry.encodedSize(CGSize(width: 1441, height: 901), scale: 2)
        precondition(size.width == 2882 && size.height == 1802)
        let capped = RecordingGeometry.encodedSize(CGSize(width: 3024, height: 1964), scale: 2)
        precondition(capped.width <= 3840 && capped.height <= 2160)
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fixed = RecordingGeometry.selection(anchor: .zero, cursor: CGPoint(x: 1400, y: 20), fixedSize: CGSize(width: 640, height: 480), bounds: bounds)
        precondition(fixed == CGRect(x: 800, y: 0, width: 640, height: 480))
        let backwards = RecordingGeometry.selection(anchor: CGPoint(x: 600, y: 600), cursor: CGPoint(x: 100, y: 100), fixedSize: nil, bounds: bounds)
        precondition(backwards == CGRect(x: 100, y: 100, width: 500, height: 500))
        print("PASS: five coordinate, fixed-frame and resolution checks")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mic in [false, true] {
            let url = directory.appendingPathComponent(mic ? "synthetic-mixed.mp4" : "synthetic-system.mp4")
            try? FileManager.default.removeItem(at: url)
            let engine = try await RecordingEngine.synthetic(output: url, microphone: mic)
            try await Task.sleep(nanoseconds: 350_000_000)
            let result = try await engine.finish()
            precondition(result.warning == nil, result.warning ?? "")
            let asset = AVURLAsset(url: result.url)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration).seconds
            precondition(videos.count == 1 && audios.count == 1)
            precondition(duration >= 0.3 && duration < 10, "Unexpected duration: \(duration)")
            print("PASS: \(mic ? "mixed system + mic" : "system audio") MP4, one video/one audio track, duration \(String(format: "%.3f", duration)) seconds")
        }
        let emptyURL = directory.appendingPathComponent("empty.mp4")
        let empty = try await RecordingEngine.empty(output: emptyURL)
        do { _ = try await empty.finish(); preconditionFailure("Empty recording should fail") }
        catch { precondition(!FileManager.default.fileExists(atPath: emptyURL.path)); print("PASS: no-frame recording fails without creating an output") }
        let abortURL = directory.appendingPathComponent("aborted.mp4")
        let aborted = try await RecordingEngine.synthetic(output: abortURL, microphone: false)
        await aborted.abort()
        precondition(!FileManager.default.fileExists(atPath: abortURL.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(!files.contains { $0.hasPrefix(".") && $0.hasSuffix(".recording.mp4") })
        print("PASS: aborted recording removes its partial file")
    }
}
