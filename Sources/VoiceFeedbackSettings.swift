import SwiftUI
import AppKit
import UniformTypeIdentifiers
struct VoiceFeedbackSettings:View {
    @ObservedObject var voice:VoiceBridge
    @State private var soundError=""
    private let sounds=["none","Tink","Pop","Glass","Ping","Submarine","Blow","Purr","UFO"]
    func string(_ path:WritableKeyPath<VoiceSettings,String?>,_ fallback:String)->Binding<String>{Binding(get:{voice.settings[keyPath:path] ?? fallback},set:{voice.settings[keyPath:path]=$0;voice.persist()})}
    func flag(_ path:WritableKeyPath<VoiceSettings,Bool?>,_ fallback:Bool)->Binding<Bool>{Binding(get:{voice.settings[keyPath:path] ?? fallback},set:{voice.settings[keyPath:path]=$0;voice.persist()})}
    var customSounds:[String] {let dir=storageRoot.appendingPathComponent("Sounds");return ((try? FileManager.default.contentsOfDirectory(atPath:dir.path)) ?? []).sorted().map{"custom:"+$0}}
    var availableSounds:[String] {sounds+customSounds}
    func importSound(){
        let picker=NSOpenPanel();picker.allowedContentTypes=[.audio];picker.allowsMultipleSelection=false
        guard picker.runModal() == .OK,let source=picker.url else{return}
        do {
            let size=(try source.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
            guard size<=10_000_000 else{soundError="Choose a sound smaller than 10 MB.";return}
            let dir=storageRoot.appendingPathComponent("Sounds");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let name=UUID().uuidString.prefix(6)+"-"+source.lastPathComponent
            let destination=dir.appendingPathComponent(String(name));try FileManager.default.copyItem(at:source,to:destination)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
            soundError="Sound imported. Choose it for the start, end or ongoing sound."
        }catch{soundError=error.localizedDescription}
    }
    var body:some View {
        ToolCard(title:"Dictation feedback",subtitle:"Choose what you see and hear while speaking.",accent:.mint){
            VoicePlayground(voice:voice)
            SpeechOptions(voice:voice)
            Button("Restart speech with selected model"){voice.reset()}.disabled(voice.state.recording || voice.state.busy)
            Toggle("Spoken formatting commands",isOn:flag(\.spokenFormatting,false))
            Text("Say ‘new line’ or ‘new paragraph’. Begin with ‘I’m writing an email’ to separate a greeting and sign-off. This changes layout only and does not send the message.").font(.caption).foregroundStyle(.secondary)
            Toggle("Show recording indicator",isOn:flag(\.indicatorEnabled,true))
            Picker("Indicator position",selection:string(\.indicatorPosition,"text")){Text("Bottom of current screen").tag("bottom");Text("Near the text cursor").tag("text")}
            Picker("Indicator style",selection:string(\.indicatorStyle,"waveform")){Text("Waveform").tag("waveform");Text("Waveform only").tag("waves");Text("Minimal dot").tag("dot");Text("Glowing orb").tag("orb")}
            Picker("Indicator colour",selection:string(\.indicatorColor,"cyan")){Text("Cyan").tag("cyan");Text("Blue").tag("blue");Text("Purple").tag("purple");Text("Green").tag("green");Text("Red").tag("red");Text("Orange").tag("orange");Text("Pink").tag("pink")}
            Text("Follows the blinking text caret when the app exposes it. If exact caret bounds are unavailable, it sits beside the focused text box. Screen-bottom placement is the last fallback when the app exposes neither.").font(.caption).foregroundStyle(.secondary)
            Toggle("Glow around the focused text box",isOn:flag(\.glowEnabled,false))
            Picker("Glow colour",selection:string(\.glowColor,"cyan")){Text("Cyan").tag("cyan");Text("Blue").tag("blue");Text("Purple").tag("purple");Text("Green").tag("green")}
            Text("Glow works where macOS exposes the text box bounds. The waveform stays available in other apps.").font(.caption).foregroundStyle(.secondary)
            HStack{Picker("Start sound",selection:string(\.startSound,"Tink")){ForEach(availableSounds,id:\.self){Text($0=="none" ? "None":$0).tag($0)}};Picker("End sound",selection:string(\.endSound,"Pop")){ForEach(availableSounds,id:\.self){Text($0=="none" ? "None":$0).tag($0)}}}
            HStack {
                Picker("Wake confirmation",selection:string(\.wakeSound,"Tink")){ForEach(availableSounds,id:\.self){Text($0=="none" ? "None":$0).tag($0)}}
                Button("Hear wake cue"){voice.command("test_sound",extra:["cue":"wakeSound"])}.disabled(voice.state.recording)
            }
            Picker("Sound while dictating",selection:string(\.talkingSound,"off")){Text("Off").tag("off");Text("Quiet UFO hum").tag("UFO");ForEach(customSounds,id:\.self){Text($0.replacingOccurrences(of:"custom:",with:"")).tag($0)}}
            Button("Import sound…"){importSound()}
            if !soundError.isEmpty {Text(soundError).font(.caption).foregroundStyle(.secondary)}
            Slider(value:Binding(get:{voice.settings.soundVolume ?? 0.25},set:{voice.settings.soundVolume=$0;voice.persist()}),in:0...1){Text("Sound volume")}
            Text("Choose None for either cue to use only one sound. The UFO hum is optional; headphones help keep it out of your microphone. Changes apply to the next dictation.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
