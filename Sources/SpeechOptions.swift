import SwiftUI
import Metal

struct SpeechOptions: View {
    @ObservedObject var voice: VoiceBridge
    private let gpu = MTLCreateSystemDefaultDevice()
    private var memory: Int {Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)}
    private var recommendation: SpeechRecommendation {SpeechRecommendation(memoryGB:memory,gpu:gpu != nil)}
    private let sizes = ["tiny","base","small","medium","large-v3-turbo","large-v3"]
    private func title(_ key:String)->String {
        switch key {case "large-v3-turbo":return "Large v3 Turbo";case "large-v3":return "Large v3";default:return key.capitalized}
    }
    private func repo(_ key:String)->String {key == "large-v3-turbo" ? "mlx-community/whisper-large-v3-turbo" : "mlx-community/whisper-\(key)-mlx"}
    private func setting(_ key:WritableKeyPath<VoiceSettings,String?>,_ fallback:String)->Binding<String> {
        Binding(get:{voice.settings[keyPath:key] ?? fallback},set:{voice.settings[keyPath:key]=$0;voice.persist()})
    }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("\(gpu?.name ?? "No Metal GPU") · \(memory) GB shared memory").font(.headline)
            Text(recommendation.detail).font(.callout)
            Button("Use recommended settings") {
                voice.settings.computeMode = gpu == nil ? "cpu" : "gpu"
                voice.settings.speechEngine = recommendation.primary == "Parakeet" ? "parakeet" : "whisper"
                voice.settings.whisperModel = repo("small")
                voice.settings.cpuModel = "base"
                voice.persist()
            }
            Picker("Processing",selection:setting(\.computeMode,"gpu")) {
                Text("GPU").tag("gpu")
                Text("CPU").tag("cpu")
                Text("GPU with CPU fallback").tag("gpu_fallback")
            }
            if voice.settings.computeMode != "cpu" {
                Picker("GPU model",selection:setting(\.speechEngine,"parakeet")) {
                    Text("Parakeet · fast English").tag("parakeet");Text("Whisper").tag("whisper")
                }
                if voice.settings.speechEngine == "whisper" {
                    Picker("Whisper size",selection:setting(\.whisperModel,repo("large-v3-turbo"))) {
                        ForEach(sizes,id:\.self){Text(title($0)).tag(repo($0))}
                    }
                }
            }
            if voice.settings.computeMode == "cpu" || voice.settings.computeMode == "gpu_fallback" {
                Picker(voice.settings.computeMode == "cpu" ? "CPU model" : "CPU fallback model",selection:setting(\.cpuModel,"base")) {
                    ForEach(sizes,id:\.self){Text("Whisper " + title($0)).tag($0)}
                }
                Text("CPU uses Whisper with int8 precision. Base is a lighter starting point; larger models can be much slower. Parakeet uses the GPU only.").font(.caption).foregroundStyle(.secondary)
            }
            if voice.settings.computeMode == "gpu_fallback" {
                Text("On a recoverable GPU memory or device error, retry the same recording once on CPU and stay there until speech restarts. The fallback model may download on first use. This cannot recover an OS-killed or hung process.").font(.caption).foregroundStyle(.secondary)
            }
            if let compute=voice.state.compute,voice.connected {
                Label(compute,systemImage:voice.state.fallback == true ? "exclamationmark.arrow.triangle.2.circlepath":"cpu").foregroundStyle(voice.state.fallback == true ? .orange:.cyan)
            }
            Text("Suggestions use GPU availability and total shared memory, not a benchmark or a guarantee of free memory. All models currently transcribe in English. Changes apply after restarting speech; first use downloads model weights.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
