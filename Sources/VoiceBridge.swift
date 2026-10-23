import Foundation
import Combine

struct SpeechState: Decodable {
    var accessibilityGranted: Bool? = nil
    /// The speech helper's own microphone permission: 0 not asked, 1 restricted, 2 denied, 3 allowed.
    var microphoneAccess: Int? = nil
    /// True while the speech model is still loading or downloading.
    var loading: Bool? = nil
    var keyListenerReady: Bool? = nil
    var compute: String? = nil
    var fallback: Bool? = nil
    var time: Double = 0
    var status: String = "Connecting to local speech worker…"
    var recording = false
    var busy = false
    var wake = false
    var awaitingCommand: Bool? = nil
    var microphone = false
    var detectorReady = false
    var mode = "dictation"
    var level: Double = 0
}
struct VoiceEvent: Decodable {
    var id: String
    var kind: String
    var time: Double
    var text: String?
    var mode: String?
    var action: String?
    var session: String?
    var message: String?
    var path: String?
    var success: Bool?
    var models: [String]?
    var empty: Bool?
}
@MainActor final class VoiceBridge: ObservableObject {
    @Published var settings = VoiceSettings()
    @Published var state = SpeechState()
    @Published var preview = ""
    @Published var finalText = ""
    @Published var practiceText = ""
    @Published var practiceResultID = UUID()
    @Published var error = ""
    @Published var connected = false
    @Published var localWritingModels: [String] = []
    @Published var localWritingStatus = ""
    var onEvent: ((VoiceEvent)->Void)?
    let root: URL
    private var timer: Timer?
    init(storage: URL) {
        root=storage.appendingPathComponent("VoiceBridge")
        for path in [root,root.appendingPathComponent("inbox"),root.appendingPathComponent("events")] {
            try? FileManager.default.createDirectory(at:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
        if let data=try? Data(contentsOf:root.appendingPathComponent("config.json")), var config=try? JSONDecoder().decode(VoiceSettings.self,from:data) {
            let migrated=config.migrateBranding();settings=config
            if migrated {persist()}
        }
        else { persist() }
        timer=Timer.scheduledTimer(withTimeInterval:0.3,repeats:true) { [weak self] _ in Task { @MainActor in self?.poll() } }
    }
    func persist() {
        let prefix=(settings.wakePhrase ?? VoiceSettings.defaultWakePhrase).trimmingCharacters(in:.whitespacesAndNewlines)
        for (key,phrase) in settings.phrases where phrase.lowercased().hasPrefix(prefix.lowercased()+" ") {
            settings.phrases[key]=String(phrase.dropFirst(prefix.count+1))
        }
        settings.wakePhrase=prefix
        let values=settings.phrases.values.map{prefix+" "+$0.trimmingCharacters(in:.whitespacesAndNewlines)}
        guard values.allSatisfy({ $0.range(of:"^[A-Za-z]+(?:[' -][A-Za-z]+)*$",options:.regularExpression) != nil && (1...8).contains($0.split(separator:" ").count) && $0.count<=80 }), Set(values.map{$0.lowercased()}).count==values.count else {
            error="Use a wake phrase and distinct actions: 1–8 English words in each complete command.";return
        }
        do { let url=root.appendingPathComponent("config.json");try JSONEncoder().encode(settings).write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);error="" }
        catch { self.error=error.localizedDescription }
    }
    func setWake(_ enabled: Bool) { settings.wakeEnabled=enabled;persist();command(enabled ? "wake_on":"wake_off") }
    func command(_ action:String,extra:[String:Any] = [:]) {
        var body:[String:Any] = ["id":UUID().uuidString,"action":action,"time":Date().timeIntervalSince1970]
        for (key,value) in extra {body[key]=value}
        let url=root.appendingPathComponent("inbox/\(String(format:"%020.0f",Date().timeIntervalSince1970 * 1_000_000))-\(UUID().uuidString).json")
        do {try JSONSerialization.data(withJSONObject:body).write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)} catch { self.error=error.localizedDescription }
    }
    var runtimeInstalled:Bool {
        let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OpenToolkit Speech.app/Contents")
        let bundled=FileManager.default.fileExists(atPath:helper.appendingPathComponent("Resources/bundled-runtime.json").path)
            && FileManager.default.isExecutableFile(atPath:helper.appendingPathComponent("MacOS/OpenToolkitSpeech").path)
        return bundled || FileManager.default.isExecutableFile(atPath:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pico/Speech/venv/bin/python").path)
    }
    private var service:String {"gui/\(getuid())/local.pico.speech"}
    /// launchctl can wait many seconds for the old worker to exit; never run it on the main thread.
    nonisolated private static func launchctl(_ arguments:[String])->Bool {
        let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/launchctl");process.arguments=arguments
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        do{try process.run();process.waitUntilExit();return process.terminationStatus==0}catch{return false}
    }
    @discardableResult private func launchctl(_ arguments:[String]) async ->Bool {
        await Task.detached(priority:.userInitiated){Self.launchctl(arguments)}.value
    }
    @Published var restarting=false
    func startSpeech() {
        guard runtimeInstalled else{error="Install the speech runtime using the CLI installer first.";return}
        let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OpenToolkit Speech.app/Contents/MacOS/OpenToolkitSpeech")
        // An explicit app start resumes the saved wake preference after a prior quit.
        if settings.wakeEnabled {
            let marker=root.deletingLastPathComponent().appendingPathComponent("Speech/voice-commands.disabled")
            try? FileManager.default.removeItem(at:marker)
            command("wake_on")
        }
        guard FileManager.default.isExecutableFile(atPath:helper.path) else{error="Speech helper is missing. Rebuild OpenToolkit.";return}
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let agent=directory.appendingPathComponent("local.pico.speech.plist")
        let log=root.deletingLastPathComponent().appendingPathComponent("speech.log")
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            if !FileManager.default.fileExists(atPath:log.path){try Data().write(to:log)}
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:log.path)
            let values:[String:Any] = ["Label":"local.pico.speech","ProgramArguments":[helper.path],"RunAtLoad":false,"KeepAlive":false,"StandardOutPath":log.path,"StandardErrorPath":log.path,"Umask":63,"EnvironmentVariables":["TOKENIZERS_PARALLELISM":"false"]]
            try PropertyListSerialization.data(fromPropertyList:values,format:.xml,options:0).write(to:agent,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:agent.path)
            let service=self.service,agentPath=agent.path
            state.status="Starting local speech; first use may download the model…";error=""
            Task{
                if !(await launchctl(["print",service])) {_ = await launchctl(["bootstrap","gui/\(getuid())",agentPath])}
                if !(await launchctl(["kickstart",service])) {error="Could not start speech. Check the local speech log in Settings."}
            }
        }catch{self.error=error.localizedDescription}
    }
    func stopSpeech() {
        guard !state.recording && !state.busy && !["ambient","meeting"].contains(state.mode) else{error="Finish the current capture before stopping speech.";return}
        settings.wakeEnabled=false;persist()
        let service=self.service;Task{_ = await launchctl(["bootout",service])};connected=false;state.status="Speech stopped"
    }
    func reset() {
        guard !state.recording && !state.busy && !["ambient","meeting"].contains(state.mode) else{error="Finish the current capture before resetting speech.";return}
        // Reset repairs speech without silently turning the user's wake setting off.
        let marker=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pico/Speech/voice-commands.disabled")
        if settings.wakeEnabled {try? FileManager.default.removeItem(at:marker)}
        guard !restarting else{return}
        restarting=true;state.status="Restarting speech…"
        let service=self.service
        Task{
            if await launchctl(["print",service]) {_ = await launchctl(["kickstart","-k",service])}else{startSpeech()}
            restarting=false
        }
    }
    private func poll() {
        if let data=try? Data(contentsOf:root.appendingPathComponent("state.json")),let state=try? JSONDecoder().decode(SpeechState.self,from:data) {
            self.state=state; connected=Date().timeIntervalSince1970-state.time<5
        } else {connected=false}
        guard let files=try? FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("events"),includingPropertiesForKeys:nil) else{return}
        for url in files.filter({$0.pathExtension=="json"}).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}).prefix(40) {
            guard let data=try? Data(contentsOf:url),let event=try? JSONDecoder().decode(VoiceEvent.self,from:data) else {
                // Events are written atomically; a stale unreadable file would otherwise block the queue.
                let modified=(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? Date()
                if Date().timeIntervalSince(modified)>60 {try? FileManager.default.removeItem(at:url)}
                continue
            }
            if ["action","preview","capture_started","correction_suggestion","correction_saved"].contains(event.kind) && Date().timeIntervalSince1970-event.time>30 {try? FileManager.default.removeItem(at:url);continue}
            if event.kind=="preview" {preview=event.text ?? ""}
            if event.kind=="transcript",event.mode=="practice" {practiceText=event.text ?? "";practiceResultID=UUID()}
            if event.kind=="transcript" {finalText=event.text ?? "";preview=""}
            if event.kind=="capture_started" {preview=""}
            if event.kind=="ai_models" {localWritingModels=event.models ?? [];localWritingStatus=event.message ?? ""}
            if event.kind=="error" {error=event.message ?? "Speech error"}
            onEvent?(event)
            try? FileManager.default.removeItem(at:url)
        }
    }
}
