import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

/// Read access in the process that actually needs it. Main-app Accessibility
/// status cannot stand in for the separately signed speech helper's status.
struct PermissionsView: View {
    @ObservedObject var voice: VoiceBridge
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var recordingMic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var message = ""
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private func settings(_ page: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + page) {
            NSWorkspace.shared.open(url)
        }
    }
    private func row(_ title: String, _ detail: String, _ status: String, ready: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status).font(.caption).foregroundStyle(.secondary)
            Button(ready ? "Settings…" : "Set up…", action: action)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions").font(.headline)
            Text("Grant access once for the tools you use. These checks refresh when you return from System Settings.")
                .font(.callout).foregroundStyle(.secondary)
            row("Screen & System Audio Recording", "OpenToolkit · screenshots, video and meeting audio", screenAllowed ? "Allowed" : "Needs access", ready: screenAllowed) {
                if !CGPreflightScreenCaptureAccess() {
                    _ = CGRequestScreenCaptureAccess()
                    message = "Enable OpenToolkit. If macOS asks to reopen the app, finish any recording first, then quit and open OpenToolkit again."
                }
                settings("ScreenCapture")
            }
            Divider()
            row("Microphone for dictation", "OpenToolkit Speech · your voice stays on this Mac", voice.connected ? (voice.state.microphone ? "Input ready" : "Input unavailable") : "Start speech to check", ready: voice.connected && voice.state.microphone) {
                if !voice.connected { voice.startSpeech() }
                settings("Microphone")
            }
            row("Accessibility for dictation", "OpenToolkit Speech · Fn shortcut and typing into other apps", voice.connected ? (voice.state.accessibilityGranted == true ? "Allowed" : "Needs access") : "Start speech to check", ready: voice.connected && voice.state.accessibilityGranted == true) {
                if !voice.connected { voice.startSpeech() }
                settings("Accessibility")
            }
            Text(voice.connected && voice.state.keyListenerReady == true ? "Fn listener is running." : "Fn listener is not ready. After granting Accessibility, use Restart speech below.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            row("Microphone for screen recordings", "OpenToolkit · optional voiceover when recording video", recordingMic == .authorized ? "Allowed" : "Optional", ready: recordingMic == .authorized) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                settings("Microphone")
            }
            HStack {
                Button("Restart speech") { voice.reset() }
                    .disabled(voice.state.recording || voice.state.busy || ["meeting", "ambient"].contains(voice.state.mode))
                Button("Show installed speech helper") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OpenToolkit Speech.app")])
                }
            }
            Text("Screen capture belongs to OpenToolkit; dictation permissions belong to OpenToolkit Speech. You do not need to grant access to Terminal or Python. Signed releases keep the same app identities across updates. macOS can still ask again after a system reset or security change.")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .padding(18).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .onReceive(refresh) { _ in
            screenAllowed = CGPreflightScreenCaptureAccess()
            recordingMic = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }
}
