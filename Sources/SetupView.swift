import SwiftUI
import AppKit

struct SetupView: View {
    @ObservedObject var model: AppModel
    @AppStorage("setupComplete") private var complete = false
    @State private var speech = true
    @State private var notes = false
    @State private var screen = true
    @State private var message = ""
    private var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            Label("Welcome to OpenToolkit",systemImage:"command.square.fill").font(.largeTitle.bold()).foregroundStyle(.cyan)
            Text("opentoolkit.app").font(.callout).foregroundStyle(.secondary)
            Text("Your everyday Mac toolkit.").font(.title3)
            GroupBox("This Mac") {
                VStack(alignment:.leading,spacing:8) {
                    Text("macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion) · \(memoryGB) GB memory")
                    SpeechOptions(voice:model.voice)
                    Text("Only OS, GPU and memory are checked. OpenToolkit does not scan files, other apps, CLI accounts, or local model servers.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
            }
            Toggle("Screenshots, annotation and screen recording",isOn:$screen)
            Toggle("Local dictation",isOn:$speech)
            Toggle("Notes and meeting transcripts (experimental)",isOn:$notes)
            Text("The downloadable app includes its speech runtime. First start downloads the selected model from Hugging Face and can take several minutes. Dictation then runs locally. Wake phrases, sending, and continuous capture start off.").font(.callout).foregroundStyle(.secondary)
            PermissionsView(voice:model.voice)
            if !message.isEmpty {Text(message).foregroundStyle(.orange)}
            HStack {
                Button("Open OpenToolkit") {
                    if speech && !model.voice.runtimeInstalled {message="Speech runtime is missing. Run the CLI installer without --native-only, or turn Local dictation off for now.";return}
                    model.toggle("screenshots",screen);model.toggle("drawing",screen);model.toggle("recording",screen)
                    model.toggle("organizer",notes);model.toggle("continuous",notes)
                    model.voice.settings.dictationEnabled=speech;model.voice.persist()
                    complete=true;model.registerHotkeys()
                    if speech {model.voice.startSpeech()}
                }.buttonStyle(.borderedProminent)
                Button("Stop speech"){model.voice.stopSpeech()}
                Spacer()
            }
            Text("No sign-in, sync, embeddings, or AI note summaries in this preview.").font(.caption).foregroundStyle(.secondary)
        }.padding(36) }.frame(minWidth:900,minHeight:650).preferredColorScheme(.dark)
         .onAppear{speech=model.voice.runtimeInstalled;notes=model.enabled("organizer")}
    }
    private func permission(_ name:String){if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_"+name){NSWorkspace.shared.open(url)}}
}
struct ApplicationShell:View {
    @ObservedObject var model:AppModel
    @AppStorage("setupComplete") private var complete=false
    var body:some View {if complete {RootView(model:model)} else {SetupView(model:model)}}
}
