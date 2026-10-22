import Foundation

@main struct VoiceSettingsTests {
    static func main() throws {
        var count=0
        func check(_ result:Bool,_ message:String){precondition(result,message);count+=1}
        func legacy(prefix:String? = "hey pico") throws -> VoiceSettings {
            var values=try JSONSerialization.jsonObject(with:JSONEncoder().encode(VoiceSettings())) as! [String:Any]
            values.removeValue(forKey:"brandingVersion")
            values["wakePhrase"]=prefix
            values["recoveryKey"]="option"
            values["liveEnabled"]=true
            values["phrases"]=["start":"hey pico start dictating","stop":"stop transcribing"]
            return try JSONDecoder().decode(VoiceSettings.self,from:JSONSerialization.data(withJSONObject:values))
        }
        var fresh=VoiceSettings()
        check(fresh.wakePhrase=="hey toolkit","Fresh settings use the new spoken name")
        check(!fresh.migrateBranding(),"Fresh settings need no migration")
        var old=try legacy()
        check(old.migrateBranding(),"Legacy settings migrate")
        check(old.wakePhrase=="hey toolkit","Old default gets new name")
        check(old.phrases["start"]=="start dictating","Legacy embedded prefix is removed")
        check(old.recoveryKey=="option" && old.liveEnabled,"Custom behavior survives")
        check(!old.migrateBranding(),"Migration is idempotent")
        var noPrefix=try legacy(prefix:nil)
        noPrefix.migrateBranding()
        check(noPrefix.wakePhrase=="hey toolkit","Pre-prefix config gets new default")
        var custom=try legacy(prefix:"hello pocket")
        custom.phrases["start"]="begin writing"
        custom.migrateBranding()
        check(custom.wakePhrase=="hello pocket","Custom wake phrase is preserved")
        check(custom.phrases["start"]=="begin writing","Custom action is preserved")
        old.wakePhrase="hey pico"
        check(!old.migrateBranding() && old.wakePhrase=="hey pico","Users can choose the old phrase afterward")
        let roundTrip=try JSONDecoder().decode(VoiceSettings.self,from:JSONEncoder().encode(old))
        check(roundTrip.brandingVersion==2 && roundTrip.recoveryKey=="option","Migration survives saving")
        print("Voice settings: \(count) checks passed")
    }
}
