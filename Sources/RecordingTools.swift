import AppKit
import AVFoundation
import Combine
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

// All coordinates crossing the public boundary use AppKit's global, bottom-left space.
// Audio/video files belong in the caller's local application-support folder, never source control.
@MainActor
final class RecordingCoordinator: NSObject, ObservableObject {
    @Published private(set) var status = "Ready to record a region"
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var lastRecording: URL?
    var onStatus: ((String) -> Void)?
    var onSaved: ((URL) -> Void)?

    private let storage: URL
    private var engine: RecordingEngine?
    private var preparation: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt: Date?
    private var stopRequested = false
    private var terminalError: String?
    private var control: RecordingControlPanel?
    private var selection: RecordingRegionSelection?
    private var lastDiskCheck = Date.distantPast

    init(storage: URL) {
        self.storage = storage
        super.init()
    }

    func selectRegion(fixedSize: CGSize? = nil, completion: @escaping (CGRect?) -> Void) {
        guard !isBusy else { setStatus("Finish the current recording first"); completion(nil); return }
        selection?.cancel()
        let selector = RecordingRegionSelection(fixedSize: fixedSize)
        selection = selector
        selector.present { [weak self, weak selector] region in
            if self?.selection === selector { self?.selection = nil }
            completion(region)
        }
    }

    func cancelSelection() {
        selection?.cancel()
        selection = nil
    }

    func start(region: CGRect? = nil, includeMicrophone: Bool = false) {
        guard !isBusy else { setStatus("A recording is already in progress"); return }
        if region == nil {
            selectRegion { [weak self] selected in
                guard let selected else { self?.setStatus("Recording selection cancelled"); return }
                self?.start(region: selected, includeMicrophone: includeMicrophone)
            }
            return
        }
        guard let region, region.width >= 16, region.height >= 16 else {
            setStatus("Choose a region at least 16 × 16 points"); return
        }
        isBusy = true
        stopRequested = false
        terminalError = nil
        setStatus("Preparing screen recording…")
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                // Called only after the user explicitly starts a recording.
                guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                    throw RecordingFailure.message("Allow Screen Recording for this app in System Settings → Privacy & Security, then try again.")
                }
                if includeMicrophone {
                    guard #available(macOS 15.0, *) else {
                        throw RecordingFailure.message("Microphone capture requires macOS 15 or newer. You can still record the screen and system audio.")
                    }
                    let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
                    if authorization == .notDetermined {
                        guard await AVCaptureDevice.requestAccess(for: .audio) else {
                            throw RecordingFailure.message("Microphone access was declined. Allow it in System Settings or turn off microphone recording.")
                        }
                    } else if authorization != .authorized {
                        throw RecordingFailure.message("Microphone access is disabled. Allow it in System Settings or turn off microphone recording.")
                    }
                }
                guard !self.stopRequested else { self.resetAfterStop(message: "Recording cancelled"); return }
                try FileManager.default.createDirectory(at: self.storage, withIntermediateDirectories: true)
                try self.checkAvailableDisk(minimumBytes: 200_000_000)

                let screen = try RecordingGeometry.screen(containing: region, screens: NSScreen.screens)
                guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                    throw RecordingFailure.message("Could not identify the selected display.")
                }
                self.showControl(on: screen)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw RecordingFailure.message("The selected display disconnected. Select a region again.")
                }
                guard !self.stopRequested else { self.resetAfterStop(message: "Recording cancelled"); return }
                let excluded = content.windows.filter { Int($0.windowID) == self.control?.windowNumber }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let source = RecordingGeometry.sourceRect(region: region, screenFrame: screen.frame)
                let size = RecordingGeometry.encodedSize(region.size, scale: screen.backingScaleFactor)
                let name = Self.makeFilename()
                let output = self.storage.appendingPathComponent(name)
                let recorder = try RecordingEngine(output: output, dimensions: size,
                                                   includeMicrophone: includeMicrophone)
                recorder.onFailure = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.isBusy else { return }
                        self.terminalError = error.localizedDescription
                        self.stop()
                    }
                }
                self.engine = recorder
                try await recorder.start(filter: filter, sourceRect: source)
                self.isRecording = true
                self.startedAt = Date()
                self.setStatus(includeMicrophone ? "Recording screen, system audio and microphone" : "Recording screen and system audio")
                self.control?.setTime("00:00", detail: includeMicrophone ? "Screen + audio + mic" : "Screen + system audio")
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateTimer() }
                }
                self.preparation = nil
                if self.stopRequested { self.stop() }
            } catch {
                if let engine = self.engine { await engine.abort() }
                self.resetAfterStop(message: "Recording failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        selection?.cancel()
        guard isBusy else { return }
        stopRequested = true
        guard isRecording, let engine else {
            if preparation != nil { setStatus("Cancelling recording startup…") }
            return
        }
        isRecording = false
        timer?.invalidate(); timer = nil
        setStatus("Saving recording…")
        control?.setTime("Saving…", detail: "Finishing local MP4")
        control?.setStopEnabled(false)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.finish()
                self.lastRecording = result.url
                self.onSaved?(result.url)
                var message = "Saved \(result.url.lastPathComponent)"
                if let warning = result.warning { message += " — \(warning)" }
                if let terminalError = self.terminalError { message += " (recording stopped: \(terminalError))" }
                self.resetAfterStop(message: message)
            } catch {
                self.resetAfterStop(message: "Could not save recording: \(error.localizedDescription)")
            }
        }
    }

    // The application delegate can await this before exiting so the MP4 is finalized.
    func finishBeforeQuit() async {
        stop()
        while isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    private func showControl(on screen: NSScreen) {
        let panel = RecordingControlPanel()
        panel.onStop = { [weak self] in self?.stop() }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.minY + 24))
        panel.orderFrontRegardless()
        control = panel
    }

    private func updateTimer() {
        guard let startedAt, isRecording else { return }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        let time = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                                  : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        control?.setTime(time, detail: nil)
        if Date().timeIntervalSince(lastDiskCheck) > 30 {
            lastDiskCheck = Date()
            do { try checkAvailableDisk(minimumBytes: 100_000_000) }
            catch { terminalError = error.localizedDescription; stop() }
        }
    }

    private func checkAvailableDisk(minimumBytes: Int64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: storage.path)
        if let available = attributes[.systemFreeSize] as? NSNumber, available.int64Value < minimumBytes {
            throw RecordingFailure.message("The disk is nearly full. Free some space before recording.")
        }
    }

    private func resetAfterStop(message: String) {
        timer?.invalidate(); timer = nil
        control?.close(); control = nil
        engine = nil; preparation = nil; startedAt = nil
        isRecording = false; isBusy = false; stopRequested = false
        setStatus(message)
    }

    private func setStatus(_ message: String) { status = message; onStatus?(message) }

    private static func makeFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Recording \(formatter.string(from: Date())) \(UUID().uuidString.prefix(6)).mp4"
    }
}

enum RecordingFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

enum RecordingGeometry {
    @MainActor static func screen(containing region: CGRect, screens: [NSScreen]) throws -> NSScreen {
        guard let screen = screens.first(where: { $0.frame.insetBy(dx: -0.5, dy: -0.5).contains(region) }) else {
            throw RecordingFailure.message("Select a region entirely within one display.")
        }
        return screen
    }

    static func sourceRect(region: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: region.minX - screenFrame.minX, y: screenFrame.maxY - region.maxY,
               width: region.width, height: region.height)
    }

    static func encodedSize(_ size: CGSize, scale: CGFloat) -> CGSize {
        // H.264 uses even dimensions; cap at 4K to keep memory and encoding load bounded.
        let multiplier = min(max(1, scale), 3840 / max(size.width, 1), 2160 / max(size.height, 1))
        return CGSize(width: max(16, floor(size.width * multiplier / 2) * 2),
                      height: max(16, floor(size.height * multiplier / 2) * 2))
    }

    static func selection(anchor: CGPoint, cursor: CGPoint, fixedSize: CGSize?, bounds: CGRect) -> CGRect {
        if let fixedSize {
            let width = min(max(16, fixedSize.width), bounds.width)
            let height = min(max(16, fixedSize.height), bounds.height)
            // In fixed-size mode dragging moves an unchanged-size frame.
            return CGRect(x: min(max(bounds.minX, cursor.x), bounds.maxX - width),
                          y: min(max(bounds.minY, cursor.y - height), bounds.maxY - height),
                          width: width, height: height)
        }
        let raw = CGRect(x: min(anchor.x, cursor.x), y: min(anchor.y, cursor.y),
                         width: abs(cursor.x - anchor.x), height: abs(cursor.y - anchor.y))
        return raw.intersection(bounds)
    }
}

private struct RecordingResult {
    let url: URL
    let warning: String?
}

// Only the dedicated serial queue touches the asset writer and sample state.
private final class RecordingEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let output: URL
    private let temporary: URL
    private let dimensions: CGSize
    private let includeMicrophone: Bool
    private let queue = DispatchQueue(label: "local.pico.recording.writer", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput
    private let microphone: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private var lastVideoTime: CMTime?
    private var lastVideoSample: CMSampleBuffer?
    private var finishing = false
    private var reportedFailure = false
    private var videoFrames = 0
    private var systemAudioFrames = 0
    private var micFrames = 0
    var onFailure: ((Error) -> Void)?

    init(output: URL, dimensions: CGSize, includeMicrophone: Bool) throws {
        self.output = output
        self.temporary = output.deletingLastPathComponent().appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).recording.mp4")
        self.dimensions = dimensions
        self.includeMicrophone = includeMicrophone
        writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width), AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(24_000_000, max(2_000_000, Int(dimensions.width * dimensions.height * 4))),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        systemAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
        ])
        microphone = includeMicrophone ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
        ]) : nil
        super.init()
        for input in [video, systemAudio, microphone].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingFailure.message("The MP4 encoder cannot accept the \(input.mediaType.rawValue) format.") }
            writer.add(input)
        }
    }

    func start(filter: SCContentFilter, sourceRect: CGRect) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.writer.startWriting() else {
                    continuation.resume(throwing: self.writer.error ?? RecordingFailure.message("Could not start the MP4 encoder.")); return
                }
                let config = SCStreamConfiguration()
                config.sourceRect = sourceRect
                config.width = Int(self.dimensions.width); config.height = Int(self.dimensions.height)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 4
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = true
                config.capturesAudio = true
                config.sampleRate = 48_000; config.channelCount = 2
                config.excludesCurrentProcessAudio = true
                if #available(macOS 15.0, *) { config.captureMicrophone = self.includeMicrophone }
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                self.stream = stream
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                    if #available(macOS 15.0, *), self.includeMicrophone {
                        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: self.queue)
                    }
                    stream.startCapture { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finishing, sample.isValid, CMSampleBufferDataIsReady(sample) else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  CMSampleBufferGetImageBuffer(sample) != nil else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard time.isValid, time.isNumeric else { return }
            if sessionStart == nil { writer.startSession(atSourceTime: time); sessionStart = time }
            if let lastVideoTime, time <= lastVideoTime { return }
            if video.isReadyForMoreMediaData {
                if video.append(sample) { videoFrames += 1; lastVideoTime = time; lastVideoSample = sample }
                else { reportFailure(writer.error ?? RecordingFailure.message("The video encoder stopped accepting frames.")) }
            }
        } else {
            guard let sessionStart, CMSampleBufferGetPresentationTimeStamp(sample) >= sessionStart else { return }
            let input: AVAssetWriterInput?
            if type == .audio { input = systemAudio }
            else if #available(macOS 15.0, *), type == .microphone { input = microphone }
            else { input = nil }
            if let input, input.isReadyForMoreMediaData {
                if input.append(sample) {
                    if type == .audio { systemAudioFrames += 1 } else { micFrames += 1 }
                } else { reportFailure(writer.error ?? RecordingFailure.message("The audio encoder stopped accepting samples.")) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { if !self.finishing { self.reportFailure(error) } }
    }

    private func reportFailure(_ error: Error) {
        guard !reportedFailure else { return }
        reportedFailure = true
        onFailure?(error)
    }

    private func stopStream() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finishing = true
                guard let stream = self.stream else { continuation.resume(); return }
                stream.stopCapture { _ in continuation.resume() }
            }
        }
    }

    func abort() async {
        await stopStream()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.writer.status == .writing || self.writer.status == .unknown { self.writer.cancelWriting() }
                try? FileManager.default.removeItem(at: self.temporary)
                self.stream = nil
                continuation.resume()
            }
        }
    }

    func finish() async throws -> RecordingResult {
        await stopStream()
        let counts = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int, Int), Error>) in
            queue.async {
                self.stream = nil
                guard self.videoFrames > 0, self.sessionStart != nil else {
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.temporary)
                    continuation.resume(throwing: RecordingFailure.message("No screen frames were captured. Check Screen Recording permission and try a longer recording.")); return
                }
                guard self.writer.status == .writing else {
                    continuation.resume(throwing: self.writer.error ?? RecordingFailure.message("The MP4 encoder failed. A partial file was retained locally.")); return
                }
                // ScreenCaptureKit sends no new frames for a static screen. Repeat the
                // final image at stop time so a quiet, static recording keeps its duration.
                if let sample = self.lastVideoSample, let lastTime = self.lastVideoTime,
                   self.video.isReadyForMoreMediaData {
                    let now = CMClockGetTime(CMClockGetHostTimeClock())
                    if now > lastTime {
                        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                                       presentationTimeStamp: now, decodeTimeStamp: .invalid)
                        var finalSample: CMSampleBuffer?
                        if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                               sampleBufferOut: &finalSample) == noErr,
                           let finalSample { _ = self.video.append(finalSample) }
                    }
                }
                self.lastVideoSample = nil
                self.video.markAsFinished(); self.systemAudio.markAsFinished(); self.microphone?.markAsFinished()
                self.writer.finishWriting {
                    self.queue.async {
                        if self.writer.status == .completed { continuation.resume(returning: (self.systemAudioFrames, self.micFrames)) }
                        else { continuation.resume(throwing: self.writer.error ?? RecordingFailure.message("MP4 finalization failed. A partial file was retained locally.")) }
                    }
                }
            }
        }
        var warning: String?
        if includeMicrophone && counts.1 == 0 { warning = "No microphone audio arrived; check your input device" }
        if includeMicrophone && counts.0 > 0 && counts.1 > 0 {
            // Multiple MP4 audio tracks are often played as alternatives. Flatten both to
            // one mixed track so normal players hear the microphone and computer together.
            do {
                try await mixAudio(from: temporary, to: output)
                try? FileManager.default.removeItem(at: temporary)
            } catch {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: temporary, to: output)
                warning = "Audio mixing failed; the MP4 preserves separate system and microphone tracks"
            }
        } else {
            try FileManager.default.moveItem(at: temporary, to: output)
        }
        return RecordingResult(url: output, warning: warning)
    }

    private func mixAudio(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1, at: .zero)
            return parameters
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingFailure.message("The audio mixer is unavailable.")
        }
        export.audioMix = mix
        export.outputURL = destination
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        guard export.status == .completed else { throw export.error ?? RecordingFailure.message("Audio mixing did not finish.") }
    }
}

@MainActor
private final class RecordingControlPanel: NSPanel {
    var onStop: (() -> Void)?
    private let timeLabel = NSTextField(labelWithString: "Preparing…")
    private let detailLabel = NSTextField(labelWithString: "Screen recording")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 252, height: 74),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        isMovableByWindowBackground = true
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 252, height: 74))
        background.material = .hudWindow; background.blendingMode = .behindWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 17
        contentView = background
        let dot = NSTextField(labelWithString: "●")
        dot.textColor = .systemRed; dot.font = .systemFont(ofSize: 16, weight: .semibold)
        dot.frame = NSRect(x: 17, y: 35, width: 20, height: 22)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        timeLabel.frame = NSRect(x: 41, y: 34, width: 128, height: 25)
        detailLabel.font = .systemFont(ofSize: 10, weight: .medium); detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 18, y: 14, width: 157, height: 17)
        stopButton.bezelStyle = .rounded; stopButton.keyEquivalent = ""
        stopButton.frame = NSRect(x: 177, y: 21, width: 61, height: 32)
        stopButton.target = self; stopButton.action = #selector(stopPressed)
        for view in [dot, timeLabel, detailLabel, stopButton] { background.addSubview(view) }
        setAccessibilityLabel("Screen recording controls")
    }
    @objc private func stopPressed() { onStop?() }
    func setTime(_ text: String, detail: String?) { timeLabel.stringValue = text; if let detail { detailLabel.stringValue = detail } }
    func setStopEnabled(_ enabled: Bool) { stopButton.isEnabled = enabled }
}

@MainActor
private final class RecordingRegionSelection {
    private let fixedSize: CGSize?
    private var windows: [RecordingSelectionWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private var finished = false

    init(fixedSize: CGSize?) { self.fixedSize = fixedSize }

    func present(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let window = RecordingSelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.isOpaque = false; window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.acceptsMouseMovedEvents = true
            let view = RecordingSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), fixedSize: fixedSize)
            view.onComplete = { [weak self] rect in
                guard let rect else { self?.finish(nil); return }
                self?.finish(rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
            }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            windows.append(window)
        }
        let mouse = NSEvent.mouseLocation
        (windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first)?.makeKey()
    }

    func cancel() { finish(nil) }

    private func finish(_ region: CGRect?) {
        guard !finished else { return }; finished = true
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        let action = completion; completion = nil
        // Ensure the selector has left the window server before ScreenCaptureKit starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { action?(region) }
    }
}

private final class RecordingSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RecordingSelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    private let fixedSize: CGSize?
    private var anchor: CGPoint?
    private var selected = CGRect.zero
    private var tracking: NSTrackingArea?

    init(frame: NSRect, fixedSize: CGSize?) { self.fixedSize = fixedSize; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard fixedSize != nil, anchor == nil else { return }
        let cursor = convert(event.locationInWindow, from: nil)
        selected = RecordingGeometry.selection(anchor: cursor, cursor: cursor, fixedSize: fixedSize, bounds: bounds)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        anchor = convert(event.locationInWindow, from: nil)
        mouseDragged(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        selected = RecordingGeometry.selection(anchor: anchor, cursor: convert(event.locationInWindow, from: nil), fixedSize: fixedSize, bounds: bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selected.width >= 16, selected.height >= 16 else { anchor = nil; return }
        onComplete?(selected)
    }
    override func rightMouseDown(with event: NSEvent) { onComplete?(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onComplete?(nil) }
        else if event.keyCode == 36, selected.width >= 16, selected.height >= 16 { onComplete?(selected) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.46).setFill(); bounds.fill()
        if selected.width > 0, selected.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            selected.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemRed.setStroke()
            let border = NSBezierPath(rect: selected.insetBy(dx: 1, dy: 1)); border.lineWidth = 2; border.stroke()
            let dimensions = "\(Int(selected.width)) × \(Int(selected.height))"
            drawLabel(dimensions, at: CGPoint(x: selected.minX + 8, y: max(8, selected.minY - 30)), fontSize: 12)
        }
        let help = fixedSize == nil ? "Drag to select a recording area  ·  Esc cancels" : "Drag to position the fixed frame  ·  Release to record  ·  Esc cancels"
        drawLabel(help, at: CGPoint(x: max(20, bounds.midX - 245), y: bounds.maxY - 70), fontSize: 14)
    }
    private func drawLabel(_ text: String, at point: CGPoint, fontSize: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let background = NSRect(x: point.x - 9, y: point.y - 5, width: size.width + 18, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: background, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}
