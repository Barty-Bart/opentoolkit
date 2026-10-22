import AppKit
import AVFoundation
import Combine
@preconcurrency import ScreenCaptureKit
import CoreMedia

// System-output meeting audio is independent of the microphone/dictation process.
// Call acknowledge only after the local transcription worker has consumed a chunk.
@MainActor
final class MeetingAudioCapture: NSObject, ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "System audio is off"
    @Published private(set) var isBusy = false
    var onChunk: ((URL) -> Void)?
    var onStatus: ((String) -> Void)?
    private let storage: URL
    private var engine: MeetingAudioEngine?
    private var pending: [URL: MeetingAudioEngine] = [:]
    private var stopRequested = false

    init(storage: URL) { self.storage = storage; super.init() }

    func start() {
        guard !isBusy else { return }
        guard pending.count < 5 else {
            setStatus("Five meeting chunks are still awaiting transcription. Finish or recover them before starting another capture.")
            return
        }
        let chunkHandler = onChunk
        isBusy = true; stopRequested = false
        setStatus("Preparing meeting system audio…")
        Task { [weak self] in
            guard let self else { return }
            do {
                // System audio needs Screen/System Audio Recording permission even
                // though no screen sample output is ever registered here.
                guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                    throw MeetingAudioFailure.message("Allow Screen & System Audio Recording in System Settings → Privacy & Security to transcribe meeting sound from your computer.")
                }
                try FileManager.default.createDirectory(at: self.storage, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    throw MeetingAudioFailure.message("No display is available for system-audio capture.")
                }
                guard !self.stopRequested else { self.finish(message: "Meeting audio cancelled"); return }
                let engine = MeetingAudioEngine(storage: self.storage, maximumPendingChunks: max(1, 5 - self.pending.count))
                engine.onChunk = { [weak self] url, owner in
                    Task { @MainActor in
                        guard let self else { return }
                        self.pending[url] = owner
                        if let chunkHandler { chunkHandler(url) }
                        else {
                            self.setStatus("No local transcription worker is connected; audio remains in the private capture folder")
                            self.stop()
                        }
                    }
                }
                engine.onFailure = { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.setStatus(error.localizedDescription)
                        self.stop(preservingStatus: true)
                    }
                }
                self.engine = engine
                try await engine.start(filter: SCContentFilter(display: display, excludingWindows: []))
                self.running = true
                self.setStatus("Meeting system audio is being transcribed locally")
                if self.stopRequested { self.stop() }
            } catch {
                if let engine = self.engine { _ = await engine.stop(flush: false) }
                self.finish(message: "Meeting audio failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() { stop(preservingStatus: false) }

    private func stop(preservingStatus: Bool) {
        guard isBusy else { return }
        stopRequested = true
        guard running, let engine else { return }
        running = false
        let finalStatus = preservingStatus ? status : "Meeting system audio stopped"
        if !preservingStatus { setStatus("Finishing the final meeting audio chunk…") }
        Task { [weak self] in
            let error = await engine.stop(flush: true)
            self?.finish(message: error?.localizedDescription ?? finalStatus)
        }
    }

    func acknowledge(_ url: URL) {
        guard let owner = pending.removeValue(forKey: url) else { return }
        owner.acknowledge(url) { [weak self] error in
            if let error { Task { @MainActor in self?.setStatus("Could not delete a consumed meeting chunk: \(error.localizedDescription)") } }
        }
    }

    func finishBeforeQuit() async {
        stop()
        while isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    private func finish(message: String) {
        engine = nil; running = false; isBusy = false; stopRequested = false
        setStatus(message)
    }
    private func setStatus(_ text: String) { status = text; onStatus?(text) }
}

private enum MeetingAudioFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

// No SCStreamOutputType.screen output is installed. Only PCM audio enters this queue.
private final class MeetingAudioEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let storage: URL
    private let queue = DispatchQueue(label: "local.pico.meeting-audio", qos: .userInitiated)
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private var pendingFiles: Set<URL> = []
    private var stopping = false
    private var failed = false
    private var failure: Error?
    private let chunkFrames = 16_000 * 8
    private let maximumPendingChunks: Int
    var onChunk: ((URL, MeetingAudioEngine) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(storage: URL, maximumPendingChunks: Int = 5) {
        self.storage = storage
        self.maximumPendingChunks = max(1, min(5, maximumPendingChunks))
        super.init()
        samples.reserveCapacity(16_000 * 9)
    }

    func start(filter: SCContentFilter) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                let config = SCStreamConfiguration()
                config.capturesAudio = true; config.sampleRate = 48_000; config.channelCount = 2
                config.excludesCurrentProcessAudio = true
                config.width = 16; config.height = 16
                config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
                config.queueDepth = 3
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                self.stream = stream
                do {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                    stream.startCapture { error in
                        if let error { done.resume(throwing: error) } else { done.resume() }
                    }
                } catch { done.resume(throwing: error) }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !stopping, !failed, sample.isValid, CMSampleBufferDataIsReady(sample) else { return }
        do {
            try consume(sample)
            while samples.count >= chunkFrames {
                try writeChunk(Array(samples.prefix(chunkFrames)))
                samples.removeFirst(chunkFrames)
            }
        } catch { fail(error) }
    }

    private func consume(_ sample: CMSampleBuffer) throws {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        if inputFormat != format {
            inputFormat = format
            converter = AVAudioConverter(from: format, to: outputFormat)
        }
        guard let converter else { throw MeetingAudioFailure.message("The meeting audio format cannot be converted to local transcription audio.") }
        let frameCount = CMSampleBufferGetNumSamples(sample)
        guard frameCount > 0, frameCount <= 480_000,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        input.frameLength = AVAudioFrameCount(frameCount)
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frameCount), into: input.mutableAudioBufferList)
        guard copied == noErr else { throw MeetingAudioFailure.message("Could not read the meeting audio buffer (\(copied)).") }
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * 16_000 / format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var suppliedInput = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, state in
            if suppliedInput { state.pointee = .noDataNow; return nil }
            suppliedInput = true; state.pointee = .haveData; return input
        }
        if result == .error { throw conversionError ?? MeetingAudioFailure.message("Meeting audio resampling failed.") as NSError }
        if let channel = output.floatChannelData?[0], output.frameLength > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        guard samples.count <= chunkFrames * 3 else { throw MeetingAudioFailure.message("Meeting audio exceeded its buffer limit. Capture stopped to protect memory.") }
    }

    private func writeChunk(_ audio: [Float]) throws {
        guard audio.count >= 3_200 else { return }
        let energy = audio.reduce(0.0) { $0 + Double($1 * $1) } / Double(audio.count)
        // True silence does not need a transcription job; no speech recognition runs here.
        guard energy > 0.00000025 else { return }
        guard pendingFiles.count < maximumPendingChunks else {
            throw MeetingAudioFailure.message("The transcription worker cannot keep up with meeting audio. Capture stopped at its queue limit; existing private chunks are retained.")
        }
        let identifier = "meeting-system-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).wav"
        let url = storage.appendingPathComponent(identifier)
        // Create the inode with restricted permissions before AVAudioFile writes any sound.
        guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw MeetingAudioFailure.message("Could not create a private meeting audio chunk.")
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(audio.count)),
                  let channel = buffer.floatChannelData?[0] else {
                throw MeetingAudioFailure.message("Could not allocate a meeting audio chunk.")
            }
            buffer.frameLength = AVAudioFrameCount(audio.count)
            audio.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
            try file.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        pendingFiles.insert(url)
        onChunk?(url, self)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { if !self.stopping { self.fail(error) } }
    }

    private func fail(_ error: Error) {
        guard !failed else { return }; failed = true
        failure = error
        onFailure?(error)
    }

    func acknowledge(_ url: URL, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.pendingFiles.contains(url) else { completion(nil); return }
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                self.pendingFiles.remove(url); completion(nil)
            } catch { completion(error) }
        }
    }

    func stop(flush: Bool) async -> Error? {
        await withCheckedContinuation { (done: CheckedContinuation<Error?, Never>) in
            queue.async {
                self.stopping = true
                let finalize = {
                    self.queue.async {
                        if flush, !self.failed, !self.samples.isEmpty {
                            do { try self.writeChunk(self.samples) } catch { self.fail(error) }
                        }
                        self.samples.removeAll(keepingCapacity: false)
                        self.converter = nil; self.inputFormat = nil; self.stream = nil
                        done.resume(returning: self.failure)
                    }
                }
                if let stream = self.stream { stream.stopCapture { _ in finalize() } }
                else { finalize() }
            }
        }
    }
}
