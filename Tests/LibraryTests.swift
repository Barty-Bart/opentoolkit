import Foundation

@main struct LibraryTests {
    @MainActor static func main()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("multitool-library-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try LibraryDatabase(url:root.appendingPathComponent("library.sqlite"))
        var count=0
        func check(_ value:Bool,_ message:String){if !value{fatalError(message)};count+=1}
        try db.put(id:"note:a",kind:"note",title:"Launch decision",body:"The screenshot shortcut is Command Shift Four.")
        check(try db.items(query:"screenshot").count==1,"FTS finds note")
        try db.put(id:"dictation:test",kind:"dictation",title:"History",body:"Spoken history")
        try db.put(id:"capture:test",kind:"screenshot",title:"Capture",body:"Screen")
        check(try db.items(notesOnly:true).count==1,"Notes excludes dictation and screenshots")
        check(try db.items(kind:"dictation").count==1,"Dictation remains in history")
        try db.execute("DELETE FROM items WHERE id IN ('dictation:test','capture:test')")
        check(try db.items(query:"\" OR DROP TABLE items; --").isEmpty,"Search syntax is treated as text")
        check(try db.items(kind:"dictation").isEmpty,"Type filter")
        try db.execute("INSERT INTO folders VALUES('f','Product')")
        try db.execute("UPDATE items SET folder='f' WHERE id='note:a'")
        check(try db.items(folder:"f").count==1,"Folder assignment")
        try db.put(id:"note:a",kind:"note",title:"Launch decision",body:"Changed to freeform.")
        check(try db.items(query:"screenshot").isEmpty,"Old words removed")
        check(try db.items(query:"freeform").first?.folder=="f","Edit preserves folder")
        let long=(0..<300).map{"Sentence \($0) about the design."}.joined(separator:" ")
        try db.put(id:"note:long",kind:"meeting",title:"Meeting",body:long)
        check(try db.items(query:"Sentence 299").count==1,"Long notes remain keyword searchable")
        try db.put(id:"note:long",kind:"meeting",title:"Meeting",body:"Completely revised")
        try db.execute("DELETE FROM items WHERE id='note:long'")
        check(try db.items(query:"revised").isEmpty,"Delete removes FTS entries")
        do {try db.atomic{try db.put(id:"rollback",kind:"note",title:"Rollback",body:"test");throw LibraryFailure(message:"Synthetic")}}catch{}
        check(try db.rows("SELECT id FROM items WHERE id='rollback'").isEmpty,"Failed transaction rolls back")
        let legacy=root.appendingPathComponent("Organizer");try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true)
        let raw="""
        {"version":1,"notes":[{"id":"11111111-1111-1111-1111-111111111111","title":"Migrated","text":"Original legacy note","createdAt":"2026-10-22T00:00:00Z","updatedAt":"2026-10-22T00:00:00Z"}],"reminders":[],"focusTask":"","reviewText":""}
        """
        let file=legacy.appendingPathComponent("organizer.json");try raw.write(to:file,atomically:true,encoding:.utf8)
        let organizer=OrganizerStore(storage:legacy,startMonitoring:false,libraryURL:db.url)
        check(organizer.lastSaveSucceeded && organizer.notes.count==1,"Legacy organizer migrates")
        check(try String(contentsOf:file,encoding:.utf8)==raw,"Legacy JSON untouched")
        organizer.updateNote(organizer.notes[0].id,title:"Edited",text:"Dragonfruit decision")
        check(try db.items(query:"Dragonfruit").count==1,"Organizer edits searchable")
        let reload=OrganizerStore(storage:legacy,startMonitoring:false,libraryURL:db.url)
        check(reload.notes.first?.title=="Edited","Relaunch uses DB instead of stale JSON")
        organizer.appendTranscript("First segment.",session:"session-a",kind:"meeting")
        organizer.appendTranscript("Second segment.",session:"session-a",kind:"meeting")
        check(organizer.notes.filter{$0.session=="session-a"}.count==1,"One note per session")
        check(try db.items(query:"Second segment",kind:"meeting").count==1,"New segments searchable")
        organizer.deleteNote(organizer.notes.first!.id)
        check(try db.items(query:"Second segment").isEmpty,"Organizer deletion cleans index")
        try db.execute("CREATE TRIGGER reject_save BEFORE UPDATE ON library_meta WHEN new.key='organizer' BEGIN SELECT RAISE(ABORT,'synthetic disk error'); END")
        organizer.appendTranscript("Retained unsaved segment",session:"failure")
        check(!organizer.lastSaveSucceeded,"Failed DB commit prevents audio acknowledgment")
        check(try db.items(query:"Retained").isEmpty,"No partial indexed save")
        try db.execute("DROP TRIGGER reject_save")
        organizer.appendTranscript("Recovery segment",session:"failure")
        check(try organizer.lastSaveSucceeded && db.items(query:"Retained").count==1,"Retry preserves unsaved segment")
        print("Library: \(count) checks passed using disposable synthetic data.")
    }
}
