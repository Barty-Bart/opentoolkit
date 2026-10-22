import Foundation
@main struct RecommendationTests {
    static func main() {
        precondition(SpeechRecommendation(memoryGB:8,gpu:true).primary == "Whisper Small")
        precondition(SpeechRecommendation(memoryGB:16,gpu:true).primary == "Parakeet")
        precondition(SpeechRecommendation(memoryGB:64,gpu:false).detail.contains("CPU"))
        precondition(SpeechRecommendation(memoryGB:32,gpu:true).detail.contains("Large v3"))
        print("Speech recommendations: four hardware profiles passed.")
    }
}
