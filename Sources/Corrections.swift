import SwiftUI
import AppKit
struct CorrectionRule:Codable,Identifiable {var id:String;var wrong:String;var right:String;var enabled:Bool;var created:Double}
@MainActor final class CorrectionPrompts {
    private var panel:NSPanel?
    func show(_ event:VoiceEvent,voice:VoiceBridge){
        guard let id=event.action,let old=event.text,let new=event.message else{return}
        panel?.close()
        let saved=event.kind=="correction_saved"
        let content=VStack(alignment:.leading,spacing:12){
            Text(saved ? "Correction saved":"Remember this correction?").font(.headline)
            Text("\(old) → \(new)").textSelection(.enabled)
            HStack{
                if saved {Button("Undo"){voice.command("correction_undo",extra:["rule":id]);self.panel?.close()}}
                else {Button("Save correction"){voice.command("correction_save",extra:["rule":id]);self.panel?.close()}.buttonStyle(.borderedProminent)}
                Button(saved ? "Done":"Not now"){if !saved {voice.command("correction_dismiss")};self.panel?.close()}
            }
        }.padding(18).frame(width:330).background(.regularMaterial)
        let p=NSPanel(contentRect:NSRect(x:0,y:0,width:366,height:145),styleMask:[.titled,.utilityWindow,.nonactivatingPanel],backing:.buffered,defer:false)
        p.title="Word corrections";p.isReleasedWhenClosed=false;p.level = .floating;p.hidesOnDeactivate=false
        p.contentView=NSHostingView(rootView:content)
        if let f=NSScreen.main?.visibleFrame {p.setFrameOrigin(NSPoint(x:f.maxX-390,y:f.maxY-200))}
        panel=p;p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline:.now()+110){[weak self,weak p] in if self?.panel===p {p?.close()}}
    }
}
struct CorrectionsView:View {
    @ObservedObject var voice:VoiceBridge
    @State private var rules:[CorrectionRule]=[]
    @State private var failure=""
    let timer=Timer.publish(every:1,on:.main,in:.common).autoconnect()
    func refresh(){
        let path=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pico/Speech/corrections.json")
        do {let raw=try LibraryDatabase().legacyValue("corrections",file:path,fallback:"[]");rules=try JSONDecoder().decode([CorrectionRule].self,from:Data(raw.utf8));failure=""}catch{failure="Could not read saved corrections."}
    }
    var body:some View {ToolCard(title:"Learned corrections",subtitle:"After dictation, edit a word in the same text box within 30 seconds. After you pause, we ask before saving it. Supported text boxes only."){
        Toggle("Suggest corrections after I edit dictated text",isOn:Binding(get:{voice.settings.learnCorrections ?? true},set:{voice.settings.learnCorrections=$0;voice.persist()}))
        if !failure.isEmpty {Text(failure).foregroundStyle(.red)}
        if rules.isEmpty {Text("No learned corrections yet. Nothing is learned without your confirmation.").foregroundStyle(.secondary)}
        ForEach(rules){rule in HStack{
            VStack(alignment:.leading){Text(rule.wrong+" → "+rule.right);Text(rule.enabled ? "Applied to future dictation":"Disabled").font(.caption).foregroundStyle(.secondary)}
            Spacer()
            Toggle("Enabled",isOn:Binding(get:{rule.enabled},set:{value in voice.command(value ? "correction_enable":"correction_disable",extra:["rule":rule.id])})).labelsHidden()
            Button("Undo"){voice.command("correction_undo",extra:["rule":rule.id])}.help("Remove this learned rule. Existing messages are unchanged.")
        }.padding(.vertical,6)}
    }.onAppear{refresh()}.onReceive(timer){_ in refresh()} }
}
