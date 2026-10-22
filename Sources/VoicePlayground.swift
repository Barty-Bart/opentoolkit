import SwiftUI
import AppKit

struct VoicePlayground:View {
    @ObservedObject var voice:VoiceBridge
    @State private var text=""
    @State private var startedHere=false
    @FocusState private var focused:Bool
    private func colour(_ name:String?)->Color {switch name {case "blue":return .blue;case "orange":return .orange;case "pink":return .pink;case "purple":return .purple;case "green":return .green;case "red":return .red;default:return .cyan}}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text("Try it here").font(.headline);Spacer();Text(voice.state.recording ? "Listening":voice.state.busy ? "Transcribing":"Appearance preview").font(.caption).foregroundStyle(.secondary)}
            HStack(spacing:14) {
                TimelineView(.animation(minimumInterval:0.08)){context in
                    let phase=context.date.timeIntervalSinceReferenceDate
                    let level=voice.state.recording ? min(1,voice.state.level*18):0.45+0.25*sin(phase*3)
                    let style=voice.settings.indicatorStyle ?? "waveform"
                    Group {
                        if voice.settings.indicatorEnabled == false {Text("Indicator hidden").font(.caption)}
                        else if style=="dot" || style=="orb" {
                            Circle().fill(colour(voice.settings.indicatorColor)).frame(width:(style=="orb" ? 18:8)+level*7,height:(style=="orb" ? 18:8)+level*7).shadow(color:colour(voice.settings.indicatorColor).opacity(style=="orb" ? 0.7:0),radius:6)
                        } else {
                            HStack(spacing:3) {
                                if style != "waves" {Circle().fill(colour(voice.settings.indicatorColor)).frame(width:7,height:7).padding(.trailing,3)}
                                ForEach(0..<5){n in Capsule().fill(style=="waves" ? colour(voice.settings.indicatorColor):.white).frame(width:3,height:3+14*level*abs(sin(phase*4+Double(n))))}
                            }
                        }
                    }.frame(width:66,height:32).background(style=="waves" ? Color.clear:Color.black.opacity(0.5),in:Capsule())
                }
                Text("Appearance changes live. The animation is a demo until recording starts.").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text:$text).font(.body).scrollContentBackground(.hidden).padding(10).frame(height:115).background(.black.opacity(0.2),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(voice.settings.glowEnabled == true ? colour(voice.settings.glowColor):.white.opacity(0.12),lineWidth:voice.settings.glowEnabled == true ? 2:1).shadow(color:voice.settings.glowEnabled == true ? colour(voice.settings.glowColor).opacity(0.6):.clear,radius:6)).focused($focused).accessibilityLabel("Dictation practice text")
            HStack {
                Button(startedHere && voice.state.recording ? "Stop & insert":"Test dictation") {
                    focused=true
                    if startedHere && voice.state.recording {voice.command("stop")} else {
                        startedHere=true
                        Task{@MainActor in try? await Task.sleep(nanoseconds:200_000_000);if focused {voice.command("practice")}}
                    }
                }.disabled(voice.state.busy || (voice.state.recording && !startedHere))
                Button("Clear"){text="";focused=true}.disabled(voice.state.recording || voice.state.busy)
                Spacer()
                Button("Hear start"){voice.command("test_sound",extra:["cue":"startSound"])}.disabled(voice.state.recording)
                Button("Hear end"){voice.command("test_sound",extra:["cue":"endSound"])}.disabled(voice.state.recording)
                Button("Hear ongoing"){voice.command("test_sound",extra:["cue":"talkingSound"])}.disabled(voice.state.recording)
            }.controlSize(.small)
            Button("Try a correction example"){
                NSApp.activate(ignoringOtherApps:true)
                text="I use pair cake for dictation.";focused=true
                Task{@MainActor in try? await Task.sleep(nanoseconds:300_000_000);voice.command("watch_practice",extra:["text":text])}
            }.disabled(voice.state.recording || voice.state.busy)
            Text("To test corrections, change ‘pair cake’ to ‘parakeet’ in the example, then pause for two seconds.").font(.caption).foregroundStyle(.secondary)
            Text("Or click in the box and hold Fn. Test speech is saved in local speech history, like normal dictation.").font(.caption).foregroundStyle(.secondary)
        }.onChange(of:voice.practiceResultID){_ in if startedHere {text += (text.isEmpty ? "":"\n")+voice.practiceText;startedHere=false;focused=true;Task{@MainActor in try? await Task.sleep(nanoseconds:300_000_000);voice.command("watch_practice",extra:["text":voice.practiceText])}}}.padding(16).background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:14))
    }
}
