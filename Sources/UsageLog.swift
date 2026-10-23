import Foundation
import AVFoundation

/// Counts what happened and when, for the Home summary. It never stores text,
/// file names, window titles or app names. Writes are best-effort: a failure is
/// dropped and never blocks or fails the capture, recording or dictation counted.
final class UsageLog {
    static let enabledKey="usageStatsEnabled"
    static let kinds:Set<String>=["capture_area","capture_full","capture_scroll","record_video","record_gif","draw_session","editor_export","wake_command"]
    /// Set by AppModel so editors and the tray can count exports without new plumbing.
    static var shared:UsageLog?
    private let queue=DispatchQueue(label:"OpenToolkit.UsageLog",qos:.utility)
    private let open:()throws->LibraryDatabase
    private let isEnabled:()->Bool
    private var db:LibraryDatabase?
    init(open:@escaping()throws->LibraryDatabase={try LibraryDatabase()},isEnabled:@escaping()->Bool={UserDefaults.standard.object(forKey:UsageLog.enabledKey) as? Bool ?? true}){
        self.open=open;self.isEnabled=isEnabled
        queue.async{[self] in backfill()}
    }
    func record(_ kind:String,trigger:String?=nil,seconds:Double?=nil,at date:Date=Date()){
        guard Self.kinds.contains(kind),isEnabled() else{return}
        queue.async{[self] in insert(kind,trigger:trigger,seconds:seconds,at:date)}
    }
    /// Reads the length off the main thread; an unreadable file is still counted.
    func recordVideo(_ url:URL,trigger:String?=nil){
        guard isEnabled() else{return}
        let date=Date()
        queue.async{[self] in
            let seconds=CMTimeGetSeconds(AVURLAsset(url:url).duration)
            insert("record_video",trigger:trigger,seconds:seconds.isFinite && seconds>0 ? seconds:nil,at:date)
        }
    }
    /// Blocks until queued writes finish. Tests only.
    func waitUntilIdle(){queue.sync{}}
    private func database()->LibraryDatabase?{if db==nil {db=try? open()};return db}
    private func insert(_ kind:String,trigger:String?,seconds:Double?,at date:Date){
        try? database()?.execute("INSERT INTO usage_events(at,kind,trigger,seconds) VALUES(?,?,?,?)",[String(date.timeIntervalSince1970),kind,trigger,seconds.map{String($0)}])
    }
    /// One-time import of history that predates the log. Screenshots already removed
    /// by retention and earlier drawing sessions can't be recovered. A recording whose
    /// GIF sits beside it counts as a GIF; its GIF copy in screenshot history is skipped.
    private func backfill(){
        guard isEnabled(),let db=database() else{return}
        try? db.atomic{
            guard try db.value("migration:usage_events")==nil else{return}
            try db.execute("INSERT INTO usage_events(at,kind,trigger) SELECT created,'capture_area','backfill' FROM captures WHERE lower(name) NOT LIKE '%.gif'")
            for row in try db.rows("SELECT created,COALESCE(path,'') FROM items WHERE kind='video'") {
                let gif=URL(fileURLWithPath:row[1]).deletingPathExtension().appendingPathExtension("gif")
                let kind = !row[1].isEmpty && FileManager.default.fileExists(atPath:gif.path) ? "record_gif":"record_video"
                try db.execute("INSERT INTO usage_events(at,kind,trigger) VALUES(?,?,'backfill')",[row[0],kind])
            }
            try db.set("migration:usage_events","1")
        }
    }
}
