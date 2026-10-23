import Foundation

@main struct UsageLogTests {
    static func main()throws {
        let schema=URL(fileURLWithPath:CommandLine.arguments[1])
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("opentoolkit-usage-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var count=0
        func check(_ value:Bool,_ message:String){if !value{fatalError(message)};count+=1}
        func fresh(_ name:String)throws->LibraryDatabase{try LibraryDatabase(url:root.appendingPathComponent(name+".sqlite"),schema:schema)}
        func events(_ db:LibraryDatabase,_ kind:String)throws->Int{Int(try db.rows("SELECT count(*) FROM usage_events WHERE kind=?",[kind])[0][0]) ?? -1}

        // Schema: additive, idempotent, and holds no content columns.
        let db=try fresh("main");_ = try fresh("main")
        check(try db.rows("PRAGMA table_info(usage_events)").map{$0[1]}==["id","at","kind","trigger","seconds"],"Usage log stores only kind, time, trigger and duration")
        check(try db.value("schema_version")=="2","Schema version 2")

        // Recording events.
        var enabled=true
        let log=UsageLog(open:{try fresh("main")},isEnabled:{enabled})
        log.record("capture_area",trigger:"shortcut");log.record("draw_session",seconds:12.5,at:Date(timeIntervalSince1970:1_000));log.record("unknown_kind")
        log.waitUntilIdle()
        check(try events(db,"capture_area")==1,"Capture counted")
        check(try db.rows("SELECT trigger FROM usage_events WHERE kind='capture_area'")[0][0]=="shortcut","Trigger kept")
        check(try db.rows("SELECT at,seconds FROM usage_events WHERE kind='draw_session'")[0]==["1000.0","12.5"],"Drawing start time and length kept")
        check(try db.rows("SELECT count(*) FROM usage_events WHERE kind='unknown_kind'")[0][0]=="0","Unknown kinds rejected")
        enabled=false;log.record("capture_full");log.recordVideo(root.appendingPathComponent("none.mp4"));log.waitUntilIdle()
        check(try events(db,"capture_full")==0 && events(db,"record_video")==0,"Nothing written while turned off")
        enabled=true;log.recordVideo(root.appendingPathComponent("unreadable.mp4"));log.waitUntilIdle()
        check(try db.rows("SELECT seconds IS NULL FROM usage_events WHERE kind='record_video'")[0][0]=="1","Unreadable video still counted, without a length")

        // Backfill from existing history, exactly once.
        let old=try fresh("history")
        let recordings=root.appendingPathComponent("Recordings");try FileManager.default.createDirectory(at:recordings,withIntermediateDirectories:true)
        let plain=recordings.appendingPathComponent("a.mp4"),animated=recordings.appendingPathComponent("b.mp4")
        for url in [plain,animated,animated.deletingPathExtension().appendingPathExtension("gif")] {try Data().write(to:url)}
        try old.execute("CREATE TABLE IF NOT EXISTS captures(name TEXT PRIMARY KEY,created REAL NOT NULL,kept INTEGER NOT NULL DEFAULT 0,exported TEXT)")
        try old.execute("INSERT INTO captures(name,created) VALUES('Capture-1.png',100),('Capture-2.png',200),('Capture-3.gif',300)")
        try old.put(id:"media:a.mp4",kind:"video",title:"a.mp4",body:"Screen recording",path:plain.path,created:400)
        try old.put(id:"media:b.mp4",kind:"video",title:"b.mp4",body:"Screen recording",path:animated.path,created:500)
        enabled=false;UsageLog(open:{try fresh("history")},isEnabled:{enabled}).waitUntilIdle()
        check(try old.rows("SELECT count(*) FROM usage_events")[0][0]=="0" && old.value("migration:usage_events")==nil,"No backfill while turned off, and it stays pending")
        enabled=true;UsageLog(open:{try fresh("history")},isEnabled:{enabled}).waitUntilIdle()
        check(try events(old,"capture_area")==2,"PNG screenshots backfilled; GIF copies skipped")
        check(try events(old,"record_gif")==1 && events(old,"record_video")==1,"Recording with a GIF beside it counts as a GIF")
        check(try old.rows("SELECT count(*) FROM usage_events WHERE trigger!='backfill'")[0][0]=="0","Backfilled rows are marked")
        UsageLog(open:{try fresh("history")},isEnabled:{enabled}).waitUntilIdle()
        check(try old.rows("SELECT count(*) FROM usage_events")[0][0]=="4","Backfill runs once")

        // Upgrading a version 1 library adds the log and keeps existing rows.
        let v1=try fresh("upgrade")
        try v1.execute("INSERT INTO dictations(text,app) VALUES('Kept dictation','Notes')")
        try v1.execute("DROP TABLE usage_events");try v1.execute("UPDATE library_meta SET value='1' WHERE key='schema_version'")
        let upgraded=try fresh("upgrade")
        check(try upgraded.value("schema_version")=="2","Version 1 library upgrades")
        check(try upgraded.rows("SELECT count(*) FROM usage_events")[0][0]=="0","Log table recreated empty")
        check(try upgraded.rows("SELECT text FROM dictations")[0][0]=="Kept dictation","Existing dictations untouched")

        // A broken database never throws into the caller.
        let broken=UsageLog(open:{throw LibraryFailure(message:"Synthetic")},isEnabled:{true})
        broken.record("capture_area");broken.waitUntilIdle()
        check(true,"Failed open is ignored")
        print("Usage log: \(count) checks passed using disposable synthetic data.")
    }
}
