import SwiftUI
import AppKit

struct NotesLibraryView:View {
    @ObservedObject var model:AppModel
    @State private var section="Library"
    var body:some View {VStack(alignment:.leading,spacing:18){
        Text("Experimental · local notes and keyword search. AI summaries are deferred.").font(.caption).foregroundStyle(.secondary)
        Picker("Notes section",selection:$section){Text("Library").tag("Library");Text("Record meeting / day").tag("Capture");Text("Reminders").tag("Reminders")}.pickerStyle(.segmented)
        switch section {
        case "Capture":ContinuousView(voice:model.voice,organizer:model.organizer,meetingAudio:model.meetingAudio,systemAudio:$model.systemMeetingAudio,enabled:model.enabled("continuous"))
        case "Reminders":RemindersSection(store:model.organizer).frame(minHeight:450)
        default:LibraryBrowser(store:model.organizer)
        }
    }}
}
struct LibraryBrowser:View {
    @ObservedObject var store:OrganizerStore
    @State private var query=""
    @State private var kind=""
    @State private var folder=""
    @State private var folderName=""
    @State private var folders:[[String]]=[]
    @State private var items:[LibraryItem]=[]
    @State private var selected:String?
    @State private var status=""
    let timer=Timer.publish(every:3,on:.main,in:.common).autoconnect()
    func refresh(){do{let db=try LibraryDatabase();items=try db.items(query:query,kind:kind,folder:folder,notesOnly:true);folders=try db.rows("SELECT id,name FROM folders ORDER BY name");status="\(items.count) items · saved locally"}catch{status=error.localizedDescription}}
    func newFolder(){let name=folderName.trimmingCharacters(in:.whitespacesAndNewlines);guard !name.isEmpty else{return};do{let db=try LibraryDatabase();try db.execute("INSERT INTO folders VALUES(?,?)",[UUID().uuidString,name]);folderName="";refresh()}catch{status="Could not create folder. Use a unique name."}}
    var body:some View {VStack(alignment:.leading,spacing:14){
        HStack{TextField("Search notes, meetings and reviews",text:$query).textFieldStyle(.roundedBorder);Button("New note"){store.addNote("Start writing here…",title:"Untitled note");refresh();selected=store.notes.first.map{"note:"+$0.id.uuidString}}}
        HStack{
            Picker("Show",selection:$kind){Text("All notes").tag("");Text("Quick notes").tag("note");Text("Meetings").tag("meeting");Text("Daily journal").tag("daily");Text("Reviews").tag("review")}
            Picker("Folder",selection:$folder){Text("All folders").tag("");ForEach(folders,id:\.first){r in Text(r[1]).tag(r[0])}}
        }
        HStack{TextField("New folder name",text:$folderName).textFieldStyle(.roundedBorder);Button("Add folder"){newFolder()}.disabled(folderName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
        HStack(alignment:.top,spacing:14){
            ScrollView{LazyVStack(spacing:5){ForEach(items){item in Button{selected=item.id}label:{VStack(alignment:.leading,spacing:5){Text(item.title).lineLimit(2);Text(item.kind.capitalized).font(.caption).foregroundStyle(.secondary)}.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(selected==item.id ? Color.blue.opacity(0.2):Color.clear,in:RoundedRectangle(cornerRadius:8)).contentShape(Rectangle())}.buttonStyle(.plain)}}}.frame(width:220,height:440)
            Divider()
            if let item=items.first(where:{$0.id==selected}) {
                VStack(alignment:.leading,spacing:12){
                    Picker("Move to folder",selection:Binding(get:{item.folder},set:{value in do{try LibraryDatabase().execute("UPDATE items SET folder=? WHERE id=?",[value.isEmpty ? nil:value,item.id]);refresh()}catch{status=error.localizedDescription}})){Text("Unfiled").tag("");ForEach(folders,id:\.first){r in Text(r[1]).tag(r[0])}}
                    if let note=store.notes.first(where:{"note:"+$0.id.uuidString==item.id}) {
                        NoteEditor(note:note,save:{title,text,original in store.updateNote(note.id,title:title,text:text,basedOn:original);refresh()},remove:{store.deleteNote(note.id);selected=nil;refresh()}).id(item.id).frame(minHeight:360)
                    }else{
                        Text(item.title).font(.headline)
                        if item.kind=="screenshot",!item.path.isEmpty,let image=NSImage(contentsOfFile:item.path){Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:220)}
                        ScrollView{Text(item.body).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(maxHeight:280)
                        HStack{Button("Copy text"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(item.body,forType:.string)};if !item.path.isEmpty {Button("Open file"){NSWorkspace.shared.open(URL(fileURLWithPath:item.path))}}}
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }else{Text(items.isEmpty ? "No matching items. Create a note or change the filters.":"Select an item to read it or move it into a folder.").foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:350)}
        }
        Text(status).font(.caption).foregroundStyle(.secondary)
    }.onAppear{refresh()}.onChange(of:query){refresh()}.onChange(of:kind){refresh()}.onChange(of:folder){refresh()}.onReceive(timer){_ in refresh()}}
}
