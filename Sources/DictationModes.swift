import SwiftUI
struct DictationModesView:View {
    @ObservedObject var voice:VoiceBridge
    var body:some View {ToolCard(title:"Writing mode",subtitle:"Choose how the final text is formatted. These modes run locally, preserve your words and never send automatically."){
        Picker("Mode",selection:Binding(get:{voice.settings.writingMode ?? "verbatim"},set:{voice.settings.writingMode=$0;voice.persist()})) {
            Text("Verbatim").tag("verbatim");Text("Clean text").tag("clean");Text("Email").tag("email");Text("Message").tag("message");Text("Bullet points").tag("bullets")
        }.pickerStyle(.segmented)
        Text(description).font(.caption).foregroundStyle(.secondary)
        if voice.settings.writingMode=="message" {Stepper("Sentences per paragraph: \(voice.settings.messageSentences ?? 2)",value:Binding(get:{voice.settings.messageSentences ?? 2},set:{voice.settings.messageSentences=$0;voice.persist()}),in:1...5)}
    }}
    var description:String {switch voice.settings.writingMode ?? "verbatim" {case "email":return "Separates spoken greetings and sign-offs. Does not add a subject, facts or a signature.";case "message":return "Groups sentences into short paragraphs in one draft. Does not split or send separate messages.";case "bullets":return "Turns each sentence into a bullet. No summarizing or omitted sentences.";case "clean":return "Tidies repeated spaces. No model rewriting.";default:return "Keeps the transcript as spoken, with your approved corrections. Live text is provisional until you stop."}}
}
