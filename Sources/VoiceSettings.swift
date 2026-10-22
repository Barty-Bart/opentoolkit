import Foundation

struct VoiceSettings: Codable {
    static let defaultWakePhrase = "hey toolkit"
    var brandingVersion: Int? = 2
    var wakePhrase: String? = VoiceSettings.defaultWakePhrase
    var writingMode: String? = nil
    var aiWritingEnabled: Bool? = nil
    var aiWritingEndpoint: String? = nil
    var aiWritingModel: String? = nil
    var wakeSound: String? = nil
    var messageSentences: Int? = nil
    var speechEngine: String? = nil
    var whisperModel: String? = nil
    var computeMode: String? = nil
    var cpuModel: String? = nil
    var spokenFormatting: Bool? = nil
    var learnCorrections: Bool? = nil
    var recoveryKey: String? = nil
    var startSound: String? = nil
    var endSound: String? = nil
    var talkingSound: String? = nil
    var soundVolume: Double? = nil
    var indicatorEnabled: Bool? = nil
    var indicatorPosition: String? = nil
    var indicatorStyle: String? = nil
    var indicatorColor: String? = nil
    var glowEnabled: Bool? = nil
    var glowColor: String? = nil
    var dictationEnabled = true
    var wakeEnabled = false
    var liveEnabled = false
    var sendEnabled = false
    var standaloneSend = false
    var organizerEnabled = false
    var continuousEnabled = false
    var phrases: [String:String] = ["start":"start dictating", "stop":"stop transcribing", "cancel":"cancel dictation", "send":"finish and send", "screenshot":"take a screenshot", "annotate":"draw on screen", "record":"record my screen", "record_stop":"stop screen recording", "note":"take a note", "reminder":"make a reminder", "meeting":"transcribe a meeting", "summarize":"summarize into bullet points", "email":"turn this into an email"]
    /// Migrate the former default once, without replacing custom wake phrases.
    @discardableResult mutating func migrateBranding() -> Bool {
        let version = brandingVersion ?? 0
        guard version < 2 else { return false }
        let old = (wakePhrase ?? "hey pico").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        if (version == 0 && old == "hey pico") || old == "hey open toolkit" {
            wakePhrase = Self.defaultWakePhrase
            for (key, value) in phrases {
                let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if normalized.lowercased().hasPrefix(old + " ") {
                    phrases[key] = String(normalized.dropFirst(old.count + 1))
                }
            }
        }
        phrases["summarize"] = phrases["summarize"] ?? "summarize into bullet points"
        phrases["email"] = phrases["email"] ?? "turn this into an email"
        brandingVersion = 2
        return true
    }
}
