import SwiftUI

struct VoiceCommandsView: View {
    @ObservedObject var voice: VoiceBridge
    @State private var customize = false
    private let commands = [("start", "Start dictation"), ("stop", "Stop & save"), ("cancel", "Cancel"), ("send", "Stop & send"), ("screenshot", "Screenshot"), ("annotate", "Draw on screen"), ("record", "Record screen"), ("record_stop", "Stop recording"), ("note", "Take a note"), ("reminder", "Make a reminder"), ("meeting", "Transcribe a meeting"), ("summarize", "Summarize speech"), ("email", "Draft an email")]
    private var prefix: String { voice.settings.wakePhrase ?? VoiceSettings.defaultWakePhrase }
    var body: some View {
        ToolCard(title: "Hey Toolkit", subtitle: "Wake first. Choose an action. Then speak.", accent: .mint) {
            Toggle("Glow around the pointer while listening for a command", isOn: Binding(get: { PointerGlow.enabled }, set: { PointerGlow.enabled = $0; voice.objectWillChange.send() }))
            HStack(spacing: 12) {
                Label(prefix.capitalized, systemImage: "waveform").font(.title3.weight(.semibold))
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                Text("Wait for the cue").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                Text("Say your command")
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            Text("You have eight seconds after the cue. To stop dictation, say “\(prefix)”, wait for the cue, then “\(voice.settings.phrases["stop"] ?? "stop transcribing")”.").font(.callout)
            ForEach(commands, id: \.0) { key, name in
                HStack {
                    Text(name).frame(width: 150, alignment: .leading)
                    Text(voice.settings.phrases[key] ?? "").foregroundStyle(.secondary)
                    Spacer()
                    if ["summarize", "email"].contains(key), voice.settings.aiWritingEnabled != true { Text("Set up Local AI").font(.caption).foregroundStyle(.orange) }
                    if ["note", "reminder"].contains(key), !voice.settings.organizerEnabled { Text("Enable Notes").font(.caption).foregroundStyle(.orange) }
                    if key == "meeting", !voice.settings.continuousEnabled { Text("Enable meeting capture").font(.caption).foregroundStyle(.orange) }
                    if key == "send", !voice.settings.sendEnabled { Text("Sending off").font(.caption).foregroundStyle(.orange) }
                }.padding(.vertical, 3)
            }
            DisclosureGroup("Customize wake phrase & commands", isExpanded: $customize) {
                VStack(spacing: 10) {
                    HStack { Text("Wake phrase").frame(width: 150, alignment: .leading); TextField("Hey Toolkit", text: Binding(get: { prefix }, set: { voice.settings.wakePhrase = $0 })).textFieldStyle(.roundedBorder) }
                    ForEach(commands, id: \.0) { key, name in
                        HStack { Text(name).frame(width: 150, alignment: .leading); TextField("Action after wake phrase", text: Binding(get: { voice.settings.phrases[key] ?? "" }, set: { voice.settings.phrases[key] = $0 })).textFieldStyle(.roundedBorder) }
                    }
                    HStack {
                        Button("Save commands") { voice.persist() }
                        Button("Restore defaults") { voice.settings.wakePhrase = VoiceSettings.defaultWakePhrase; voice.settings.phrases = VoiceSettings().phrases; voice.persist() }
                    }
                }.padding(.top, 12)
            }
            if !voice.error.isEmpty { Text(voice.error).foregroundStyle(.orange) }
        }
    }
}
