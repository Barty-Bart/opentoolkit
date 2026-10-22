
// Concatenate with MeetingAudio.swift; never opens a screen/microphone stream.
extension MeetingAudioEngine {
    func feedSynthetic(seconds: Double, silent: Bool = false) async throws -> [URL] {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<[URL], Error>) in
            queue.async {
                do {
                    let count = Int(seconds * 48_000)
                    var position = 0
                    while position < count {
                        let frames = min(1024, count - position)
                        let sample = makeMeetingTestSample(frames: frames, offset: position, silent: silent)
                        try self.consume(sample)
                        while self.samples.count >= self.chunkFrames {
                            try self.writeChunk(Array(self.samples.prefix(self.chunkFrames)))
                            self.samples.removeFirst(self.chunkFrames)
                        }
                        position += frames
                    }
                    done.resume(returning: Array(self.pendingFiles))
                } catch { done.resume(throwing: error) }
            }
        }
    }
    func testBackpressure() async -> Int {
        await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            queue.async {
                let samples = [Float](repeating: 0.01, count: self.chunkFrames)
                do {
                    for _ in 0..<6 { try self.writeChunk(samples) }
                    preconditionFailure("Backpressure limit should reject the sixth chunk")
                } catch { done.resume(returning: self.pendingFiles.count) }
            }
        }
    }
    func pendingForTest() async -> [URL] {
        await withCheckedContinuation { (done: CheckedContinuation<[URL], Never>) in
            queue.async { done.resume(returning: Array(self.pendingFiles)) }
        }
    }
}

private func makeMeetingTestSample(frames: Int, offset: Int, silent: Bool) -> CMSampleBuffer {
    let channels = 2
    let floats = (0..<(frames * channels)).map { index in silent ? Float(0) : Float(sin(Double(offset + index / channels) * 440 * 2 * .pi / 48_000) * 0.1) }
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
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
        presentationTimeStamp: CMTime(value: Int64(offset), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
    return sample!
}

@main
struct MeetingAudioRegressionTests {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let engine = MeetingAudioEngine(storage: directory)
        let fullChunks = try await engine.feedSynthetic(seconds: 8.5)
        precondition(fullChunks.count == 1)
        _ = await engine.stop(flush: true)
        let chunks = await engine.pendingForTest()
        precondition(chunks.count == 2)
        var duration = 0.0
        for url in chunks {
            let file = try AVAudioFile(forReading: url)
            precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
            duration += Double(file.length) / 16_000
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
            precondition(permissions.intValue == 0o600)
        }
        precondition(duration > 8.45 && duration <= 8.5, "Unexpected resampling duration \(duration)")
        print("PASS: stereo 48 kHz → mono 16 kHz WAV, 8-second chunk + stop flush, total \(duration) seconds, 0600 permissions")
        for url in chunks {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                engine.acknowledge(url) { error in precondition(error == nil); done.resume() }
            }
            precondition(!FileManager.default.fileExists(atPath: url.path))
        }
        print("PASS: acknowledgements delete consumed chunks after stop")
        let silent = MeetingAudioEngine(storage: directory)
        let silentChunks = try await silent.feedSynthetic(seconds: 8.5, silent: true)
        precondition(silentChunks.isEmpty)
        _ = await silent.stop(flush: true)
        let silentFinal = await silent.pendingForTest()
        precondition(silentFinal.isEmpty)
        print("PASS: silence produces no transcription jobs")
        let slow = MeetingAudioEngine(storage: directory)
        let pendingCount = await slow.testBackpressure()
        precondition(pendingCount == 5)
        for url in await slow.pendingForTest() {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                slow.acknowledge(url) { error in precondition(error == nil); done.resume() }
            }
        }
        print("PASS: backlog is bounded to five private chunks")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(remaining.isEmpty)
    }
}
