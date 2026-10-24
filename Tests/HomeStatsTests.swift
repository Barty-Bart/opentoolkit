import Foundation

@main struct HomeStatsTests {
    static func main()throws {
        let schema=URL(fileURLWithPath:CommandLine.arguments[1])
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("opentoolkit-home-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var count=0
        func check(_ value:Bool,_ message:String){if !value{fatalError(message)};count+=1}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Australia/Melbourne")!;calendar.firstWeekday=2
        func at(_ y:Int,_ m:Int,_ d:Int,_ h:Int,_ min:Int=0)->Date {calendar.date(from:DateComponents(year:y,month:m,day:d,hour:h,minute:min))!}
        func fresh(_ name:String)throws->LibraryDatabase {try LibraryDatabase(url:root.appendingPathComponent(name+".sqlite"),schema:schema)}
        func dictation(_ db:LibraryDatabase,_ when:String,_ text:String,_ app:String?,_ seconds:Double)throws {
            try db.execute("INSERT INTO dictations(created_at,text,app,audio_seconds) VALUES(?,?,?,?)",[when,text,app,String(seconds)])
        }
        func event(_ db:LibraryDatabase,_ kind:String,_ date:Date,_ seconds:Double?=nil)throws {
            try db.execute("INSERT INTO usage_events(at,kind,seconds) VALUES(?,?,?)",[String(date.timeIntervalSince1970),kind,seconds.map{String($0)}])
        }
        let now=at(2026,10,22,15)   // Thursday afternoon; the week runs Monday 19 to Monday 26 October

        // Main fixture.
        let db=try fresh("week")
        try dictation(db,"2026-10-20 10:15:00","Ship the release update tomorrow morning","Slack",4)
        try dictation(db,"2026-10-20 10:40:00","release notes need the Parakeet model name","Slack",6)
        try dictation(db,"2026-10-21 14:05:00","Invoice for the release","Mail",2)
        try dictation(db,"2026-10-21 09:00:00","A long meeting segment that must not count","meeting",30)
        try dictation(db,"2026-10-21 09:01:00","System audio from the meeting app","meeting system audio",30)
        try dictation(db,"2026-10-21 11:00:00","Continuous notes segment","ambient",30)
        try dictation(db,"2026-10-21 12:00:00","Practice run in the Dictation tab","OpenToolkit",3)
        try dictation(db,"2026-10-21 12:05:00","Older practice run","Pico",3)
        try dictation(db,"2026-10-18 23:59:59","Sunday night before the week","Notes",1)
        try dictation(db,"2026-10-26 00:00:00","Next Monday","Notes",1)
        try dictation(db,"2026-10-13 09:00:00","one two three","Notes",1)          // last week, before Thursday 15:00
        try dictation(db,"2026-10-16 09:00:00","Friday last week is later in the week","Notes",1)
        try event(db,"capture_area",at(2026,10,20,10,20));try event(db,"capture_full",at(2026,10,21,16));try event(db,"capture_scroll",at(2026,10,22,9))
        try event(db,"record_video",at(2026,10,21,11),30);try event(db,"record_gif",at(2026,10,21,11,30))
        try event(db,"draw_session",at(2026,10,20,15),120);try event(db,"editor_export",at(2026,10,20,10,21));try event(db,"wake_command",at(2026,10,21,17))
        try event(db,"capture_area",at(2026,10,13,10));try event(db,"capture_area",at(2026,10,16,10))   // last week: before and after the matching point
        try event(db,"capture_area",at(2026,10,26,0))                                                 // next week
        try db.set("corrections","[{\"id\":\"a\",\"wrong\":\"pair cake\",\"right\":\"Parakeet\",\"enabled\":true,\"created\":\(at(2026,10,20,9).timeIntervalSince1970)},{\"id\":\"b\",\"wrong\":\"x\",\"right\":\"Y\",\"enabled\":true,\"created\":\(at(2026,9,1,9).timeIntervalSince1970)}]")

        let week=try HomeStatsQuery.load(db:db,period:.week,now:now,calendar:calendar)
        check(week.period.start==at(2026,10,19,0) && week.period.end==at(2026,10,26,0),"Week runs Monday to Monday")
        check(week.dictations==3 && week.words==17,"Only real dictations in the week count: \(week.dictations) / \(week.words)")
        check(week.previousWords==3,"Last week compared up to the same point: \(week.previousWords)")
        check(week.speakingSeconds==12 && week.longestSeconds==6,"Speaking time and longest dictation")
        check(week.wordsPerMinute==78,"Speed uses dictations over 3 seconds: \(String(describing:week.wordsPerMinute))")
        check(week.typingMinutesSaved==0,"Time saved is rounded and never negative")
        check(week.apps==[.init(name:"Slack",words:13),.init(name:"Mail",words:4)],"Apps ranked by words, meeting and practice excluded")
        check(week.topWords==["release","invoice","model","morning","name","note","Parakeet","tomorrow"],"Top words are nouns: \(week.topWords)")
        check(week.wordCloud.first?.word=="release" && week.wordCloud.first?.count==3,"Cloud leads with the most-said word")
        check(week.wordCloud.first{$0.word=="Parakeet"}?.related.contains("model")==true,"Cloud words carry the words said near them")
        check(week.wordCloud.first?.apps==["Slack","Mail"],"Cloud words list the apps they're said in, most first: \(week.wordCloud.first?.apps ?? [])")
        let filler=HomeStatsQuery.contentTokens("I want a little video for whatever channel we are doing, something different")
        check(filler.contains("video") && filler.contains("channel") && !filler.contains("little") && !filler.contains("whatever") && !filler.contains("doing") && !filler.contains("different"),"Filler words are left out: \(filler)")
        let plural=HomeStatsQuery.contentTokens("Two screenshots and one screenshot for the editor")
        check(plural.filter{$0=="screenshot"}.count==2 && !plural.contains("screenshots"),"Plurals count with the singular: \(plural)")
        let near=HomeStatsQuery.neighbours(of:["video"],in:[["video","channel","edit"],["channel","video"],["video","thumbnail"]])
        check(near["video"]==["channel"],"Related words prefer pairs said more than once: \(near)")
        check(week.screenshots==3 && week.previousScreenshots==1,"Screenshots counted across area, full screen and scrolling")
        check(week.recordings==1 && week.recordingSeconds==30 && week.gifs==1,"Recordings and GIFs counted separately")
        check(week.drawingSessions==1 && week.drawingSeconds==120,"Drawing sessions and time")
        check(week.exports==1 && week.wakeCommands==1,"Exports and voice commands")
        check(week.correctionsLearned==1,"Only corrections learned this week")
        check(week.heatmap[1][10]==3,"Tuesday 10 am: two dictations and one screenshot")
        check(week.heatmap.joined().reduce(0,+)==3+7,"Heatmap: dictations, captures, recordings, drawing and commands; exports excluded")
        check(week.busiest == .init(weekday:1,hour:10),"Busiest hour is Tuesday 10 am")
        check(!week.isEmpty,"Week has data")

        let today=try HomeStatsQuery.load(db:db,period:.today,now:now,calendar:calendar)
        check(today.dictations==0 && today.screenshots==1 && !today.isEmpty,"Today: the morning's scrolling capture")
        check(today.previousScreenshots==0,"Yesterday before 3 pm had no screenshots")

        // Edges: midnight, daylight saving, unknown apps, more than five apps, odd spacing.
        let edge=try fresh("edges")
        try dictation(edge,"2026-10-19 00:00:00","  Starts   exactly at   midnight  ",nil,0)
        try dictation(edge,"2026-10-04 03:30:00","After clocks went forward","Notes",2)   // Melbourne skipped 2–3 am that day
        for (i,app) in ["A","B","C","D","E","F","G"].enumerated() {try dictation(edge,"2026-10-20 1\(i):00:00",String(repeating:"word ",count:7-i),app,0)}
        let edgeWeek=try HomeStatsQuery.load(db:edge,period:.week,now:now,calendar:calendar)
        check(edgeWeek.apps.map(\.name)==["A","B","C","D","Unknown","Other"] && edgeWeek.apps.last?.words==3+2+1,"Top five apps (no app name shows as Unknown), then Other")
        check(edgeWeek.wordsPerMinute==nil,"No speed without timed dictations")
        check(edgeWeek.heatmap[0][0]==1,"Midnight belongs to the new week")
        let dstWeek=try HomeStatsQuery.load(db:edge,period:.week,now:at(2026,10,4,12),calendar:calendar)
        check(dstWeek.period.duration==7*86400-3600 && dstWeek.dictations==1 && dstWeek.heatmap[6][3]==1,"Daylight-saving week is 167 hours and buckets local time")
        let month=try HomeStatsQuery.load(db:edge,period:.month,now:now,calendar:calendar)
        check(month.dictations==9 && month.period.start==at(2026,10,1,0),"Month covers October")
        check(HomeStatsQuery.wordCount("  a\tb\nc  ")==3 && HomeStatsQuery.tokens("Don’t ship it's notarization!")==["ship","notarization"],"Word counting and tokens")

        // An empty library is an empty summary, not an error.
        let empty=try HomeStatsQuery.load(db:try fresh("empty"),period:.week,now:now,calendar:calendar)
        check(empty.isEmpty && empty.busiest==nil && empty.apps.isEmpty && empty.topWords.isEmpty && empty.correctionsLearned==0,"Empty library")
        // Typing test: 100 correct characters in 30 s = 20 words in half a minute = 40 wpm.
        let sample=String(repeating:"abcde",count:20)
        let perfect=HomeStatsQuery.typingScore(sample:sample,typed:sample,seconds:30)
        check(perfect.wpm==40 && perfect.accuracy==100,"perfect typing scores 40 wpm, 100%")
        let typos=HomeStatsQuery.typingScore(sample:sample,typed:String(repeating:"abcdX",count:20),seconds:30)
        check(typos.wpm==32 && typos.accuracy==80,"typos lower both speed and accuracy")
        check(HomeStatsQuery.typingScore(sample:sample,typed:"",seconds:0)==(0,0),"no time, no score")
        check(HomeStatsQuery.typingWordsPerMinute==HomeStatsQuery.defaultTypingWordsPerMinute || UserDefaults.standard.double(forKey:"typingWordsPerMinute")>0,"falls back to 40 wpm until measured")
        print("Home stats: \(count) checks passed using disposable synthetic data.")
    }
}
