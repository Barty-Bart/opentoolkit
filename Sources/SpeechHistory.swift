import SwiftUI
import AppKit
import SQLite3
struct SpeechEntry:Identifiable {let id:Int64;let date:String;let text:String;let app:String}
@MainActor final class SpeechHistory:ObservableObject {
    @Published var entries:[SpeechEntry]=[]
    @Published var status=""
    @Published var dictionary=""
    private let support=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pico/Speech")
    func refresh(){var db:OpaquePointer?;guard sqlite3_open_v2(LibraryDatabase.url.path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else{if db != nil {sqlite3_close(db)};status="History will appear after the first dictation.";return};defer{sqlite3_close(db)};sqlite3_busy_timeout(db,500);var stmt:OpaquePointer?;guard sqlite3_prepare_v2(db,"SELECT id,created_at,text,COALESCE(app,'') FROM dictations ORDER BY id DESC LIMIT 100",-1,&stmt,nil)==SQLITE_OK else{status="Could not read history";return};defer{sqlite3_finalize(stmt)};var result:[SpeechEntry]=[];while sqlite3_step(stmt)==SQLITE_ROW{func string(_ col:Int32)->String{guard let bytes=sqlite3_column_text(stmt,col) else{return ""};return String(cString:bytes)};result.append(SpeechEntry(id:sqlite3_column_int64(stmt,0),date:string(1),text:string(2),app:string(3)))};entries=result;status="Showing the most recent \(result.count) saved transcriptions";dictionary=(try? LibraryDatabase().legacyValue("manual_replacements",file:support.appendingPathComponent("replacements.txt"),fallback:"")) ?? ""}
    func saveDictionary(){let lines=dictionary.components(separatedBy:.newlines);guard lines.allSatisfy({$0.trimmingCharacters(in:.whitespaces).isEmpty || $0.trimmingCharacters(in:.whitespaces).hasPrefix("#") || $0.contains("=>")}) else{status="Use one rule per line: heard word => correct word";return};do{try LibraryDatabase().set("manual_replacements",dictionary);status="Word corrections saved. Applied to future transcriptions."}catch{status=error.localizedDescription}}
}
struct ManualCorrectionsView:View {
    @ObservedObject var history:SpeechHistory
    @State private var heard=""
    @State private var replacement=""
    var lines:[String]{history.dictionary.components(separatedBy:.newlines)}
    func update(_ index:Int,_ value:String?){var copy=lines;if let value {copy[index]=value}else{copy.remove(at:index)};history.dictionary=copy.joined(separator:"\n");history.saveDictionary()}
    func add(){
        let a=heard.trimmingCharacters(in:.whitespacesAndNewlines),b=replacement.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !a.isEmpty,!b.isEmpty,!a.contains("=>"),!b.contains("=>"),!a.contains("\n"),!b.contains("\n") else{return}
        history.dictionary += (history.dictionary.isEmpty ? "":"\n")+a+" => "+b
        history.saveDictionary();heard="";replacement=""
    }
    var body:some View {ToolCard(title:"Your word replacements",subtitle:"Add a word or phrase that dictation often gets wrong."){
        HStack{TextField("Heard, e.g. bear",text:$heard);Image(systemName:"arrow.right");TextField("Replace with, e.g. Taylor",text:$replacement);Button("Add"){add()}.disabled(heard.trimmingCharacters(in:.whitespaces).isEmpty || replacement.trimmingCharacters(in:.whitespaces).isEmpty)}.textFieldStyle(.roundedBorder)
        ForEach(Array(lines.enumerated()),id:\.offset){index,line in
            if line.contains("=>") && !(line.trimmingCharacters(in:.whitespaces).hasPrefix("#") && line.contains(":")) {
                let enabled = !line.trimmingCharacters(in:.whitespaces).hasPrefix("#")
                let clean=enabled ? line:String(line.trimmingCharacters(in:.whitespaces).dropFirst()).trimmingCharacters(in:.whitespaces)
                HStack{Text(clean.replacingOccurrences(of:"=>",with:"→"));Spacer();Toggle("Enabled",isOn:Binding(get:{enabled},set:{value in update(index,value ? clean:"# "+clean)})).labelsHidden();Button("Remove"){update(index,nil)}}.padding(.vertical,5)
            }
        }
    }}
}
struct SpeechHistoryView:View {
    @ObservedObject var voice:VoiceBridge
    var correctionsOnly=false
    var saveAsNote:((String)->Void)?=nil
    @StateObject private var history=SpeechHistory()
    var body:some View{VStack(alignment:.leading,spacing:18){
        if correctionsOnly {CorrectionsView(voice:voice);ManualCorrectionsView(history:history);Text(history.status).font(.caption).foregroundStyle(.secondary)}
        else {
            ToolCard(title:"Saved transcriptions",subtitle:history.status){Button("Refresh"){history.refresh()}}
            ForEach(history.entries){entry in ToolCard(title:entry.date,subtitle:entry.app){Text(entry.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading);Button("Copy"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(entry.text,forType:.string)};if let saveAsNote {Button("Save a copy to Notes"){saveAsNote(entry.text)}}}}
        }
    }.onAppear{history.refresh()}}
}
