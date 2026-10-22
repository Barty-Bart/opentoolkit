import Foundation
import SQLite3

struct LibraryItem:Identifiable,Equatable {
    var id:String;var kind:String;var title:String;var body:String;var created:Double;var updated:Double;var folder:String;var path:String
}
struct LibraryFailure:LocalizedError {let message:String;var errorDescription:String?{message}}
final class LibraryDatabase {
    static let url=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pico/library.sqlite")
    let url:URL
    private var db:OpaquePointer?
    init(url:URL=LibraryDatabase.url, schema:URL?=nil)throws {
        self.url=url
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else{throw LibraryFailure(message:"Cannot open the local library.")}
        sqlite3_busy_timeout(db,5000)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        try execute("PRAGMA journal_mode=WAL")
        let resource=schema ?? Bundle.main.resourceURL!.appendingPathComponent("Voice/library_schema.sql")
        let fallback=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Voice/library_schema.sql")
        let sql=try String(contentsOf:FileManager.default.fileExists(atPath:resource.path) ? resource:fallback,encoding:.utf8)
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw LibraryFailure(message:"Cannot initialize the library schema.")}
    }
    deinit{sqlite3_close(db)}
    func execute(_ sql:String,_ values:[String?]=[])throws {
        var s:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&s,nil)==SQLITE_OK else{throw LibraryFailure(message:"Library query could not be prepared.")};defer{sqlite3_finalize(s)}
        bind(s,values)
        var code=sqlite3_step(s);while code==SQLITE_ROW {code=sqlite3_step(s)}
        guard code==SQLITE_DONE else{throw LibraryFailure(message:"Library write failed. Existing data has been preserved.")}
    }
    func rows(_ sql:String,_ values:[String?]=[])throws->[[String]] {
        var s:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&s,nil)==SQLITE_OK else{throw LibraryFailure(message:"Library search could not be prepared.")};defer{sqlite3_finalize(s)}
        bind(s,values);var result:[[String]]=[]
        while true {let code=sqlite3_step(s);if code==SQLITE_DONE {return result};guard code==SQLITE_ROW else{throw LibraryFailure(message:"Library read failed.")};result.append((0..<sqlite3_column_count(s)).map{sqlite3_column_text(s,$0).map{String(cString:$0)} ?? ""})}
    }
    private func bind(_ s:OpaquePointer?,_ values:[String?]){for (i,v) in values.enumerated(){if let v {sqlite3_bind_text(s,Int32(i+1),v,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}else{sqlite3_bind_null(s,Int32(i+1))}}}
    func atomic<T>(_ body:()throws->T)throws->T {try execute("BEGIN IMMEDIATE");do{let result=try body();try execute("COMMIT");return result}catch{try? execute("ROLLBACK");throw error}}
    func value(_ key:String)throws->String?{try rows("SELECT value FROM library_meta WHERE key=?",[key]).first?.first}
    func set(_ key:String,_ value:String)throws{try execute("INSERT INTO library_meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[key,value])}
    func legacyValue(_ key:String,file:URL,fallback:String)throws->String {
        try atomic {if let current=try value(key){return current};let content=FileManager.default.fileExists(atPath:file.path) ? try String(contentsOf:file,encoding:.utf8):fallback;if key=="corrections" {guard (try JSONSerialization.jsonObject(with:Data(content.utf8))) is [[String:Any]] else{throw LibraryFailure(message:"Invalid legacy corrections. Original file preserved.")}};try set(key,content);return content}
    }
    func migrateLegacy(history:URL,captures:URL)throws {
        for (name,file,columns) in [("dictations",history,"id,created_at,text,app,audio_seconds,transcribe_ms,model"),("captures",captures,"name,created,kept,exported")] {
            guard FileManager.default.fileExists(atPath:file.path) else{continue}
            if try value("migration:"+name) != nil {continue}
            try execute("ATTACH DATABASE ? AS legacy",[file.path]);defer{try? execute("DETACH DATABASE legacy")}
            try atomic {
                if try value("migration:"+name) == nil {
                    try execute("INSERT INTO \(name)(\(columns)) SELECT \(columns) FROM legacy.\(name)")
                    try set("migration:"+name,"1")
                }
            }
        }
    }
    func importMedia(root:URL)throws {
        for (directory,kind) in [("Recordings","video"),("Reviews","review")] {
            let dir=root.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath:dir.path) else{continue}
            for file in try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.creationDateKey],options:.skipsHiddenFiles) {
                guard ["mp4","mov","gif","txt"].contains(file.pathExtension.lowercased()) else{continue}
                let id=(kind=="video" ? "media:":"review:")+file.lastPathComponent
                guard try rows("SELECT id FROM items WHERE id=?",[id]).isEmpty else{continue}
                let body=kind=="review" ? try String(contentsOf:file,encoding:.utf8):"Screen recording"
                try put(id:id,kind:kind,title:file.lastPathComponent,body:body,path:file.path,created:(try? file.resourceValues(forKeys:[.creationDateKey]).creationDate?.timeIntervalSince1970) ?? Date().timeIntervalSince1970)
            }
        }
    }
    func put(id:String,kind:String,title:String,body:String,path:String?=nil,source:String="library",created:Double=Date().timeIntervalSince1970)throws {
        try execute("INSERT INTO items(id,kind,title,body,created,updated,path,source) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,title=excluded.title,body=excluded.body,path=excluded.path,updated=CASE WHEN items.title!=excluded.title OR items.body!=excluded.body THEN excluded.updated ELSE items.updated END",[id,kind,title,body,String(created),String(Date().timeIntervalSince1970),path,source])
    }
    func items(query:String="",kind:String="",folder:String="",notesOnly:Bool=false)throws->[LibraryItem] {
        let tokens=query.split{!$0.isLetter && !$0.isNumber}.prefix(20).map{"\"\($0)\"*"}.joined(separator:" AND ")
        let scope=notesOnly ? " AND i.kind IN ('note','meeting','daily','review')":""
        let clause=tokens.isEmpty ? "":" AND i.id IN (SELECT c.item_id FROM chunk_search JOIN chunks c ON c.id=chunk_search.rowid WHERE chunk_search MATCH ?)"
        var values:[String?]=[kind,kind,folder,folder];if !tokens.isEmpty{values.append(tokens)}
        return try rows("SELECT i.id,i.kind,i.title,i.body,i.created,i.updated,COALESCE(i.folder,''),COALESCE(i.path,'') FROM items i WHERE (?='' OR kind=?) AND (?='' OR folder=?)"+scope+clause+" ORDER BY updated DESC LIMIT 500",values).map{LibraryItem(id:$0[0],kind:$0[1],title:$0[2],body:$0[3],created:Double($0[4]) ?? 0,updated:Double($0[5]) ?? 0,folder:$0[6],path:$0[7])}
    }
}
