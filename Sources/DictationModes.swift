import SwiftUI

struct DictationModesView: View {
    @ObservedObject var voice: VoiceBridge
    private let modes = [("verbatim", "Verbatim"), ("clean", "Clean spacing"), ("email", "Email spacing"), ("message", "Message paragraphs"), ("bullets", "Sentence bullets"), ("summary", "AI bullet summary"), ("email_ai", "AI email draft")]
    var body: some View {
        VStack(spacing: 16) {
            ToolCard(title: "Writing mode", subtitle: "Choose the result you want in your text box. Your original transcript stays in history.") {
                Picker("Default mode", selection: Binding(get: { voice.settings.writingMode ?? "verbatim" }, set: { voice.settings.writingMode = $0; voice.persist() })) {
                    ForEach(modes, id: \.0) { Text($0.1).tag($0.0) }
                }
                Text(description).font(.caption).foregroundStyle(.secondary)
                if voice.settings.writingMode == "message" {
                    Stepper("Sentences per paragraph: \(voice.settings.messageSentences ?? 2)", value: Binding(get: { voice.settings.messageSentences ?? 2 }, set: { voice.settings.messageSentences = $0; voice.persist() }), in: 1...5)
                }
                Text("Or say ‘Hey Toolkit’, wait for the cue, then ‘summarize into bullet points’ or ‘turn this into an email’. That mode applies to the next dictation only. Stop to generate and paste the finished draft.").font(.caption).foregroundStyle(.secondary)
            }
            ToolCard(title: "Local AI", subtitle: "Parakeet and Whisper turn speech into words. A separate local text model can summarize those words or draft an email.") {
                Toggle("Enable local summaries and email drafts", isOn: Binding(get: { voice.settings.aiWritingEnabled ?? false }, set: { voice.settings.aiWritingEnabled = $0; voice.persist() }))
                Text("In LM Studio, load an instruction model and start its local server. OpenToolkit connects only to this Mac; it does not scan for apps or send your words to a cloud service.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Local server").frame(width: 110, alignment: .leading)
                    TextField("http://127.0.0.1:1234/v1", text: Binding(get: { voice.settings.aiWritingEndpoint ?? "http://127.0.0.1:1234/v1" }, set: { voice.settings.aiWritingEndpoint = $0 })).textFieldStyle(.roundedBorder)
                    Button("Find models") { voice.persist(); voice.localWritingStatus = "Checking local server…"; voice.command("ai_probe") }
                }
                HStack {
                    Text("Model").frame(width: 110, alignment: .leading)
                    TextField("Model identifier", text: Binding(get: { voice.settings.aiWritingModel ?? "" }, set: { voice.settings.aiWritingModel = $0 })).textFieldStyle(.roundedBorder)
                    if !voice.localWritingModels.isEmpty {
                        Menu("Choose") { ForEach(voice.localWritingModels, id: \.self) { model in Button(model) { voice.settings.aiWritingModel = model; voice.persist() } } }
                    }
                }
                HStack { Button("Save local AI settings") { voice.persist() }; Text(voice.localWritingStatus).font(.caption).foregroundStyle(.secondary) }
                Text("AI modes paste after you stop, even when live typing is enabled. If the model is unavailable, the original transcript is saved and sending is cancelled. Drafts can make mistakes; review them before sending.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var description: String {
        switch voice.settings.writingMode ?? "verbatim" {
        case "email": return "Separates spoken greetings and sign-offs, without model rewriting."
        case "message": return "Groups sentences into short paragraphs in one draft."
        case "bullets": return "One bullet per sentence. This preserves every sentence rather than summarizing."
        case "summary": return "Uses your local text model to combine repetition and produce concise bullet points."
        case "email_ai": return "Uses your local text model to produce an email draft from what you say."
        case "clean": return "Tidies repeated spaces without rewriting your words."
        default: return "Keeps your words, with approved corrections. Live text is provisional until you stop."
        }
    }
}
