import Foundation

struct SpeechRecommendation {
    let memoryGB: Int
    let gpu: Bool
    var primary: String { !gpu || memoryGB < 12 ? "Whisper Small" : "Parakeet" }
    var detail: String {
        if !gpu {return "No Metal GPU detected. Start with CPU Whisper Base; Small may improve recognition but takes longer."}
        if memoryGB < 12 {return "Start with Whisper Small to leave room for other apps. Base and Tiny use less memory. Parakeet is also available for fast English dictation."}
        if memoryGB < 24 {return "Parakeet is a good starting point for English. Whisper Small uses less memory; Medium and Large v3 Turbo are alternatives when other apps leave enough memory free."}
        return "Start with Parakeet for fast English. Try Whisper Large v3 Turbo for a balance of speed and accuracy, or Large v3 when speed matters less. Small and Medium remain lighter options."
    }
}
