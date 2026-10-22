import Foundation
import SQLite3
import SwiftUI

final class CaptureIndex {
    private var db: OpaquePointer?
    init(url: URL) {
        if sqlite3_open_v2(url.deletingLastPathComponent().appendingPathComponent("library.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            sqlite3_busy_timeout(db, 5000)
            _ = run("PRAGMA foreign_keys=ON")
            _ = run("CREATE TABLE IF NOT EXISTS captures(name TEXT PRIMARY KEY, created REAL NOT NULL, kept INTEGER NOT NULL DEFAULT 0, exported TEXT)")
            try? FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:url.deletingLastPathComponent().appendingPathComponent("library.sqlite").path)
        }
    }
    deinit { if let db { sqlite3_close(db) } }
    private func quoted(_ value:String)->String { "'" + value.replacingOccurrences(of:"'",with:"''") + "'" }
    @discardableResult private func run(_ sql:String)->Bool { guard let db else{return false};return sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK }
    @discardableResult func register(name:String,date:Date,kept:Bool)->Bool {
        guard run("INSERT OR IGNORE INTO captures(name,created,kept) VALUES(\(quoted(name)),\(date.timeIntervalSince1970),\(kept ? 1:0))") else{return false}
        do {let library=try LibraryDatabase();try library.put(id:"capture:"+name,kind:"screenshot",title:name,body:"Screenshot",path:LibraryDatabase.url.deletingLastPathComponent().appendingPathComponent("Captures/"+name).path,created:date.timeIntervalSince1970);return true}catch{return false}
    }
    func remove(name:String){_ = run("DELETE FROM captures WHERE name=\(quoted(name))");_ = run("DELETE FROM items WHERE id=\(quoted("capture:"+name))")}
    func keep(name:String,exported:String? = nil)->Bool { run("UPDATE captures SET kept=1,exported=\(exported.map(quoted) ?? "exported") WHERE name=\(quoted(name))") }
    func kept(name:String)->Bool {
        guard let db else{return true};var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,"SELECT kept FROM captures WHERE name=\(quoted(name))",-1,&stmt,nil)==SQLITE_OK else{return true};defer{sqlite3_finalize(stmt)}
        guard sqlite3_step(stmt)==SQLITE_ROW else{return true};return sqlite3_column_int(stmt,0) != 0
    }
    func expired(name:String,date:Date,hours:Int,now:Date)->Bool { hours>0 && !kept(name:name) && now.timeIntervalSince(date)>=Double(hours)*3600 }
}

struct CaptureHistoryView:View {
    @ObservedObject var capture:CaptureCoordinator
    @State private var filter="All"
    @State private var showAll=false
    var filtered:[CaptureItem] {capture.captures.filter{filter=="All" || (filter=="Kept" ? capture.isKept($0):!capture.isKept($0))}}
    var body:some View {
        VStack(alignment:.leading,spacing:16){
            Picker("Show",selection:$filter){Text("All").tag("All");Text("Temporary").tag("Temporary");Text("Kept").tag("Kept")}.pickerStyle(.segmented)
            Text(capture.status).font(.caption).foregroundStyle(.secondary)
            if filtered.isEmpty {Text("No screenshots here yet.").foregroundStyle(.secondary)}
            ForEach(Array(filtered.prefix(showAll ? filtered.count:10))){item in
                ToolCard(title:item.date.formatted(date:.abbreviated,time:.shortened),subtitle:capture.isKept(item) ? "Kept · excluded from automatic cleanup":"Temporary · follows your retention setting",accent:.blue){
                    HStack{CaptureDragPreview(url:item.url,onOpen:{capture.openEditor(item)}).frame(width:180,height:100);Spacer();VStack(alignment:.leading){HStack{Button("Copy"){capture.copy(item)};Button("Annotate"){capture.openEditor(item)};Button("Show preview"){capture.restorePreview(item)}};HStack{Button("Keep"){capture.keep(item)}.disabled(capture.isKept(item));Button("Save to…"){capture.saveAs(item)};Button("Show in Finder"){capture.reveal(item)}}}}
                }
            }
            if filtered.count>10 {Button(showAll ? "Show latest 10":"Show all \(filtered.count)"){showAll.toggle()}}
        }
    }
}
struct CaptureRetentionView:View {
    @ObservedObject var capture:CaptureCoordinator
    var body:some View {
        ToolCard(title:"Screenshot storage",subtitle:"PNG images stay on this Mac; a local SQLite index tracks their history. Kept and exported captures never expire automatically.",accent:.blue){
            Picker("Keep temporary captures for",selection:Binding(get:{capture.retentionHours},set:{capture.setRetention($0)})){
                Text("1 hour").tag(1);Text("24 hours").tag(24);Text("7 days").tag(168);Text("30 days").tag(720);Text("Until I remove them").tag(0)
            }
            Text("Expired temporary captures move to the Trash. Existing captures were marked Kept during this update. Save to… starts in Desktop and lets you choose another folder.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
