import Foundation
import NaturalLanguage
import SwiftUI

enum HomePeriod:String,CaseIterable,Identifiable {
    case today="Today",week="Week",month="Month"
    var id:String{rawValue}
    var component:Calendar.Component {switch self {case .today:return .day;case .week:return .weekOfYear;case .month:return .month}}
}

/// Everything the Home summary shows for one period, computed locally.
struct HomeSnapshot:Equatable {
    struct AppWords:Equatable {let name:String;let words:Int}
    struct Busiest:Equatable {let weekday:Int;let hour:Int}   // weekday 0 = Monday
    var period:DateInterval
    var words=0,previousWords=0,dictations=0
    var speakingSeconds=0.0,longestSeconds=0.0
    var wordsPerMinute:Int?
    var screenshots=0,previousScreenshots=0
    var recordings=0,gifs=0,recordingSeconds=0.0
    var drawingSessions=0,drawingSeconds=0.0
    var exports=0,wakeCommands=0
    var correctionsLearned=0
    var heatmap=Array(repeating:Array(repeating:0,count:24),count:7)   // [weekday][hour]
    var busiest:Busiest?
    var apps:[AppWords]=[]
    var topWords:[String]=[]
    /// The word cloud: the period's most-said nouns, each with the words said most often near it.
    struct CloudWord:Hashable,Identifiable {let word:String;let count:Int;let related:[String];var apps:[String]=[];var id:String{word}}
    var wordCloud:[CloudWord]=[]
    /// Typing at a fixed 40 words a minute, less the time spent speaking.
    var typingMinutesSaved:Int {max(0,Int((Double(words)/HomeStatsQuery.typingWordsPerMinute-speakingSeconds/60).rounded()))}
    var isEmpty:Bool {dictations==0 && screenshots==0 && recordings==0 && gifs==0 && drawingSessions==0}
}

enum HomeStatsQuery {
    static let defaultTypingWordsPerMinute=40.0
    /// Typing-test score: correctly typed characters ÷ 5 per minute, and the share of keys that were right.
    static func typingScore(sample:String,typed:String,seconds:Double)->(wpm:Int,accuracy:Int) {
        guard seconds>0 else{return (0,0)}
        let correct=zip(sample,typed).filter{$0==$1}.count
        return (Int((Double(correct)/5/(seconds/60)).rounded()),typed.isEmpty ? 0:Int((Double(correct)/Double(typed.count)*100).rounded()))
    }
    /// The user's measured typing speed (Settings › Home summary › Measure…), else 40 wpm.
    static var typingWordsPerMinute:Double {
        let measured=UserDefaults.standard.double(forKey:"typingWordsPerMinute")
        return (10...250).contains(measured) ? measured:defaultTypingWordsPerMinute
    }
    /// Meeting and continuous-notes segments store their mode where the app name goes.
    static let segmentApps=["meeting","ambient","meeting system audio"]
    /// Practice runs in the Dictation tab are saved with OpenToolkit (formerly Pico) in front.
    static let practiceApps=["OpenToolkit","Pico","Mac Multi-Tool"]
    static let stopWords:Set<String>=["that","this","with","have","from","they","will","would","there","their","what","about","which","when","your","just","like","then","them","than","been","were","into","some","could","also","more","only","other","these","those","because","really","think","know","going","want","need","okay","yeah","actually","something","thing","things","make","sure","said","very","much","well","here","where","does","doesn't","don't","it's","that's","can't","should","maybe","right","kind","sort","even","still","back","over","after","before","being","through","again","while","each","every","same","most","many","such","look","good","let's","gonna","wanna","you're","i've","we're","there's","what's","didn't","isn't","get","got","getting","thank","thanks","please","hello"]

    static func load(db:LibraryDatabase,period:HomePeriod,now:Date=Date(),calendar:Calendar = .current)throws->HomeSnapshot {
        guard let current=calendar.dateInterval(of:period.component,for:now),
              let previousStart=calendar.date(byAdding:period.component,value:-1,to:current.start) else{throw LibraryFailure(message:"Could not work out the period.")}
        // Compare with the same stretch of the previous period, so a Tuesday isn't measured against a whole week.
        let elapsed=max(0,min(now.timeIntervalSince(current.start),current.duration))
        let previous=DateInterval(start:previousStart,duration:elapsed)
        var s=HomeSnapshot(period:current)
        let local=DateFormatter();local.calendar=calendar;local.timeZone=calendar.timeZone;local.locale=Locale(identifier:"en_US_POSIX");local.dateFormat="yyyy-MM-dd HH:mm:ss"
        let excluded=(segmentApps+practiceApps).map{"'"+$0.replacingOccurrences(of:"'",with:"''")+"'"}.joined(separator:",")
        func dictations(_ range:DateInterval)throws->[[String]] {
            try db.rows("SELECT created_at,text,COALESCE(app,''),COALESCE(audio_seconds,0) FROM dictations WHERE created_at>=? AND created_at<? AND COALESCE(app,'') NOT IN (\(excluded))",[local.string(from:range.start),local.string(from:range.end)])
        }
        func weekday(_ date:Date)->Int {(calendar.component(.weekday,from:date)+5)%7}
        func mark(_ date:Date){s.heatmap[weekday(date)][calendar.component(.hour,from:date)]+=1}

        let display=correctionSpellings(db)
        var counts:[String:Int]=[:],wordApps:[String:[String:Int]]=[:],sequences:[[String]]=[],perApp:[String:Int]=[:],timedWords=0,timedSeconds=0.0
        for row in try dictations(current) {
            let n=wordCount(row[1]),seconds=Double(row[3]) ?? 0
            s.words+=n;s.dictations+=1;s.speakingSeconds+=seconds;s.longestSeconds=max(s.longestSeconds,seconds)
            if seconds>3 {timedWords+=n;timedSeconds+=seconds}
            perApp[row[2].isEmpty ? "Unknown":row[2],default:0]+=n
            if let date=local.date(from:row[0]) {mark(date)}
            let words=contentTokens(row[1]);sequences.append(words)
            for word in words {counts[word,default:0]+=1;if !row[2].isEmpty {wordApps[word,default:[:]][row[2],default:0]+=1}}
        }
        s.previousWords=try dictations(previous).reduce(0){$0+wordCount($1[1])}
        if timedSeconds>0 {s.wordsPerMinute=Int((Double(timedWords)/(timedSeconds/60)).rounded())}
        let ranked=perApp.sorted{$0.value != $1.value ? $0.value>$1.value:$0.key<$1.key}
        s.apps=ranked.prefix(5).map{HomeSnapshot.AppWords(name:$0.key,words:$0.value)}
        let rest=ranked.dropFirst(5).reduce(0){$0+$1.value};if rest>0 {s.apps.append(.init(name:"Other",words:rest))}
        let top=counts.sorted{$0.value != $1.value ? $0.value>$1.value:$0.key<$1.key}.prefix(cloudSize)
        let related=neighbours(of:Set(top.map(\.key)),in:sequences)
        s.wordCloud=top.map{word in
            let apps=(wordApps[word.key] ?? [:]).sorted{$0.value != $1.value ? $0.value>$1.value:$0.key<$1.key}.prefix(3).map(\.key)
            return HomeSnapshot.CloudWord(word:display[word.key] ?? word.key,count:word.value,related:(related[word.key] ?? []).map{display[$0] ?? $0},apps:apps)
        }
        s.topWords=s.wordCloud.prefix(8).map(\.word)

        let screenshotKinds:Set<String>=["capture_area","capture_full","capture_scroll"]
        for row in try db.rows("SELECT at,kind,COALESCE(seconds,0) FROM usage_events WHERE at>=? AND at<?",[String(current.start.timeIntervalSince1970),String(current.end.timeIntervalSince1970)]) {
            let seconds=Double(row[2]) ?? 0
            switch row[1] {
            case let kind where screenshotKinds.contains(kind):s.screenshots+=1
            case "record_video":s.recordings+=1;s.recordingSeconds+=seconds
            case "record_gif":s.gifs+=1
            case "draw_session":s.drawingSessions+=1;s.drawingSeconds+=seconds
            case "editor_export":s.exports+=1
            case "wake_command":s.wakeCommands+=1
            default:break
            }
            if row[1] != "editor_export",let at=Double(row[0]) {mark(Date(timeIntervalSince1970:at))}
        }
        s.previousScreenshots=Int(try db.rows("SELECT count(*) FROM usage_events WHERE at>=? AND at<? AND kind IN ('capture_area','capture_full','capture_scroll')",[String(previous.start.timeIntervalSince1970),String(previous.end.timeIntervalSince1970)])[0][0]) ?? 0

        var best=0
        for d in 0..<7 {for h in 0..<24 where s.heatmap[d][h]>best {best=s.heatmap[d][h];s.busiest = .init(weekday:d,hour:h)}}
        s.correctionsLearned=correctionsCreated(db,in:current)
        return s
    }
    static let cloudSize=40
    /// Nouns only, found by the Mac's on-device language tagger, so filler such as "little",
    /// "whatever" or "doing" doesn't crowd out what you actually talk about.
    static func contentTokens(_ text:String)->[String] {
        let tagger=NLTagger(tagSchemes:[.lexicalClass,.lemma]);tagger.string=text
        var nouns:[String:String]=[:]   // word -> singular form, so "screenshots" counts as "screenshot"
        tagger.enumerateTags(in:text.startIndex..<text.endIndex,unit:.word,scheme:.lexicalClass,options:[.omitPunctuation,.omitWhitespace]){tag,range in
            if tag == .noun {
                let word=text[range].lowercased().replacingOccurrences(of:"’",with:"'")
                let lemma=tagger.tag(at:range.lowerBound,unit:.word,scheme:.lemma).0?.rawValue.lowercased()
                nouns[word]=(lemma?.count ?? 0)>=4 ? lemma:word
            }
            return true
        }
        return tokens(text).compactMap{nouns[$0]}
    }
    /// For each word, the other nouns said within a few words of it most often (at least twice when there's enough data).
    static func neighbours(of words:Set<String>,in sequences:[[String]],window:Int=5,limit:Int=5)->[String:[String]] {
        var pairs:[String:[String:Int]]=[:]
        for sequence in sequences {
            for (i,word) in sequence.enumerated() where words.contains(word) {
                for j in max(0,i-window)...min(sequence.count-1,i+window) where j != i && sequence[j] != word {pairs[word,default:[:]][sequence[j],default:0]+=1}
            }
        }
        return pairs.mapValues{near in
            let ranked=near.sorted{$0.value != $1.value ? $0.value>$1.value:$0.key<$1.key}
            let repeated=ranked.filter{$0.value>=2}
            return (repeated.isEmpty ? ranked:repeated).prefix(limit).map(\.key)
        }
    }
    static func wordCount(_ text:String)->Int {text.split{$0.isWhitespace}.count}
    static func tokens(_ text:String)->[String] {
        text.lowercased().split{!($0.isLetter || $0=="'" || $0=="’")}.map{$0.replacingOccurrences(of:"’",with:"'").trimmingCharacters(in:CharacterSet(charactersIn:"'"))}
            .filter{$0.count>=4 && !stopWords.contains($0)}
    }
    /// Learned corrections keep their own capitalisation in the word list ("Parakeet", not "parakeet").
    private static func correctionSpellings(_ db:LibraryDatabase)->[String:String] {
        var result:[String:String]=[:]
        for rule in corrections(db) {if let right=rule["right"] as? String {for word in right.split(separator:" ") {result[word.lowercased()]=String(word)}}}
        return result
    }
    private static func correctionsCreated(_ db:LibraryDatabase,in range:DateInterval)->Int {
        corrections(db).filter{($0["created"] as? Double).map{range.contains(Date(timeIntervalSince1970:$0))} ?? false}.count
    }
    private static func corrections(_ db:LibraryDatabase)->[[String:Any]] {
        guard let raw=try? db.value("corrections"),let rules=try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [[String:Any]] else{return []}
        return rules
    }
}

/// Loads the Home summary off the main thread and republishes it as one value.
@MainActor final class HomeStats:ObservableObject {
    @Published var period:HomePeriod = .week {didSet{refresh()}}
    @Published private(set) var snapshot:HomeSnapshot?
    @Published private(set) var failure:String?
    private var task:Task<Void,Never>?
    func refresh(){
        task?.cancel();let period=period
        task=Task{
            let result=await Task.detached(priority:.utility){try HomeStatsQuery.load(db:LibraryDatabase(),period:period)}.result
            guard !Task.isCancelled else{return}
            switch result {
            case .success(let value):snapshot=value;failure=nil
            case .failure:failure="Your summary couldn't be loaded. Your data is unchanged."
            }
        }
    }
}
