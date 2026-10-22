import AppKit
import SwiftUI
import Carbon
import ScreenCaptureKit
import AVFoundation

let storageRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pico",isDirectory:true)
enum ToolPage: String, CaseIterable, Identifiable {
    case home="Overview", voice="Dictation", history="Speech history", corrections="Corrections", capture="Screenshots", drawing="Annotation", recording="Recording", organizer="Notes", continuous="Meeting & daily notes", settings="Settings"
    var id:String{rawValue}
    var symbol:String { switch self {case .home:return "square.grid.2x2";case .voice:return "waveform";case .corrections:return "text.badge.checkmark";case .history:return "clock.arrow.circlepath";case .capture:return "viewfinder";case .drawing:return "pencil.tip.crop.circle";case .recording:return "record.circle";case .organizer:return "note.text";case .continuous:return "text.bubble";case .settings:return "slider.horizontal.3"} }
    var color:Color {switch self {case .voice:return .cyan;case .capture:return .blue;case .drawing:return .orange;case .recording:return .red;case .organizer:return .yellow;case .continuous:return .mint;default:return .secondary}}
}
@MainActor final class AppModel: ObservableObject {
    @Published var recoveryID = UUID()
    @Published var page:ToolPage = .home
    @Published var notice="Everything stays on this Mac."
    @Published var fixedFrame=false
    @Published var frameWidth="1280"
    @Published var frameHeight="720"
    @Published var includeMic=false
    @Published var draft=""
    @Published var minutes="60"
    @Published var toggles:[String:Bool]
    @Published var keys:[String:String]
    @Published var keyModifiers = UserDefaults.standard.dictionary(forKey:"shortcutModifiers") as? [String:Int] ?? [:]
    @Published var annotationKeys = UserDefaults.standard.dictionary(forKey:"annotationKeys") as? [String:String] ?? AnnotationSettings.defaults
    let correctionPrompts=CorrectionPrompts()
    let voice:VoiceBridge
    let capture:CaptureCoordinator
    let recording:RecordingCoordinator
    let organizer:OrganizerStore
    let meetingAudio:MeetingAudioCapture
    @Published var systemMeetingAudio=true
    private var captureOptionsWindow:NSPanel?
    private var gifRequested=false
    private var scrollCapture:ScrollingCapture?
    private var reviewHour = -1
    private var savedAudioChunks=Set<String>()
    var showWindow:(()->Void)?
    var hotkeys:Hotkeys?
    init() {
        try? FileManager.default.createDirectory(at:storageRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        toggles=UserDefaults.standard.dictionary(forKey:"modules") as? [String:Bool] ?? ["screenshots":true,"drawing":true,"recording":true,"organizer":false,"continuous":false]
        keys=UserDefaults.standard.dictionary(forKey:"shortcuts") as? [String:String] ?? ["screenshots":"S","drawing":"D","recording":"R","notes":"N","reminders":"M","voice":"T"]
        var migrationError:String?
        do {let library=try LibraryDatabase();try library.importMedia(root:storageRoot)}
        catch {migrationError="Library migration paused: "+error.localizedDescription}
        voice=VoiceBridge(storage:storageRoot)
        capture=CaptureCoordinator(storage:storageRoot)
        recording=RecordingCoordinator(storage:storageRoot.appendingPathComponent("Recordings"))
        organizer=OrganizerStore(storage:storageRoot.appendingPathComponent("Organizer"),libraryURL:LibraryDatabase.url)
        meetingAudio=MeetingAudioCapture(storage:storageRoot.appendingPathComponent("MeetingAudio"))
        if !UserDefaults.standard.bool(forKey:"captureShortcutsV2") {
            keys["screenshots"]="4";keys["fullScreenshot"]="3";keys["captureOptions"]="5"
            for name in ["screenshots","fullScreenshot","captureOptions"] {keyModifiers[name]=Int(cmdKey|shiftKey)}
            UserDefaults.standard.set(keyModifiers,forKey:"shortcutModifiers")
            UserDefaults.standard.set(true,forKey:"captureShortcutsV2")
        }
        if keys["recover"] == nil {keys["recover"] = ["L","K","O","P","B","V","G","F","A","C"].first(where:{!keys.values.contains($0)}) ?? "L"}
        voice.settings.organizerEnabled=enabled("organizer");voice.settings.continuousEnabled=enabled("continuous");voice.persist()
        voice.onEvent={ [weak self] event in self?.receive(event) }
        capture.onStatus={ [weak self] text in self?.notice=text }
        recording.onSaved={ [weak self] url in
            guard let self else{return};do {try LibraryDatabase().put(id:"media:"+url.lastPathComponent,kind:"video",title:url.lastPathComponent,body:"Screen recording",path:url.path)}catch{self.notice=error.localizedDescription};guard self.gifRequested else{return};self.gifRequested=false;self.notice="Converting recording to GIF…"
            Task {do {let result=try await Task.detached(priority:.utility){try GIFExport.convert(url)}.value;self.notice="GIF ready: \(result.lastPathComponent)";self.capture.importCapture(result);self.capture.showRecentHistory()}catch{self.notice="GIF conversion failed. The MP4 is preserved: \(error.localizedDescription)"}}
        }
        recording.onStatus={ [weak self] text in self?.notice=text }
        meetingAudio.onStatus={ [weak self] text in self?.notice=text }
        organizer.onStatus={ [weak self] text in self?.notice=text }
        if let migrationError {notice=migrationError}
    }
    var size:CGSize? {guard fixedFrame,let w=Double(frameWidth),let h=Double(frameHeight),w>=32,h>=32,w<=16384,h<=16384 else{return nil};return CGSize(width:w,height:h)}
    func enabled(_ key:String)->Bool{toggles[key] ?? true}
    func toggle(_ key:String,_ value:Bool){toggles[key]=value;UserDefaults.standard.set(toggles,forKey:"modules");voice.settings.organizerEnabled=enabled("organizer");voice.settings.continuousEnabled=enabled("continuous");voice.persist();if !value {if key=="recording" {recording.stop()};if key=="drawing" || key=="screenshots" {capture.cancel()};if key=="continuous" {voice.command("stop");meetingAudio.stop()};if key=="organizer" {organizer.remindersEnabled=false;organizer.hideFocusPanel()}};registerHotkeys()}
    func registerHotkeys(){hotkeys?.clear();for (action,key) in keys {guard enabled(action=="notes" || action=="reminders" ? "organizer":(["fullScreenshot","captureOptions"].contains(action) ? "screenshots":action)) else{continue};if hotkeys?.register(key:key,modifiers:modifiers(action),action:{[weak self] in self?.perform(action)}) == false {notice="Shortcut unavailable: \(shortcutLabel(key,modifiers(action))). Choose another combination or disable it in the other app."}};UserDefaults.standard.set(keys,forKey:"shortcuts")
        if enabled("drawing") {for (name,chord) in annotationKeys {
            let parts=chord.split(separator:"+").map(String.init)
            guard let letter=parts.last,parts.count==2 else{continue}
            let flags:UInt32=parts[0]=="cmd" ? UInt32(cmdKey):parts[0]=="alt" ? UInt32(optionKey):UInt32(controlKey)
            if hotkeys?.register(key:letter,modifiers:flags,release:{[weak self] in self?.capture.releaseDrawing(name)},action:{[weak self] in self?.capture.annotationAction(name)}) == false {notice="Drawing shortcut unavailable: \(chord). Quit the other annotation app or choose another shortcut."}
        }}
        UserDefaults.standard.set(annotationKeys,forKey:"annotationKeys")
    }
    func modifiers(_ action:String)->UInt32 {UInt32(keyModifiers[action] ?? Int(cmdKey|optionKey))}
    func setShortcut(_ action:String,_ key:String,_ flags:UInt32){
        guard !keys.contains(where:{$0.key != action && $0.value==key && modifiers($0.key)==flags}) else {notice="That shortcut is already assigned to another tool.";return}
        keys[action]=key;keyModifiers[action]=Int(flags)
        UserDefaults.standard.set(keyModifiers,forKey:"shortcutModifiers")
        notice="Shortcut saved: \(shortcutLabel(key,flags))";registerHotkeys()
    }
    func perform(_ action:String) {
        if action=="recording" && fixedFrame && size==nil {notice="Enter a frame width and height from 32 to 16,384 points.";return}
        switch action {
        case "fullScreenshot":guard enabled("screenshots") else{return};capture.captureFullScreen()
        case "captureOptions":guard enabled("screenshots") else{return};showCaptureOptions()
        case "screenshots": guard enabled("screenshots") else{return};recording.cancelSelection();capture.captureRegion(fixedSize:nil)
        case "drawing":guard enabled("drawing") else{return};recording.cancelSelection();capture.annotateScreen()
        case "recording":guard enabled("recording") else{return};if recording.isRecording {recording.stop()}else{capture.cancel();recording.selectRegion(fixedSize:size){[weak self] region in guard let self,let region else{return};self.recording.start(region:region,includeMicrophone:self.includeMic)}}
        case "notes":guard enabled("organizer") else{return};page = .organizer;showWindow?()
        case "reminders":guard enabled("organizer") else{return};page = .organizer;showWindow?();organizer.presentReminderComposer()
        case "recover":recoveryID = UUID();page = .history;showWindow?();notice="Latest saved transcription is at the top. Click Copy to recover it."
        case "voice":if voice.state.recording {voice.command("stop")}else{voice.command("start")}
        default:break
        }
    }
    func showCaptureOptions(){
        captureOptionsWindow?.close()
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:644,height:300),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
        panel.title="Capture options";panel.appearance=NSAppearance(named:.darkAqua);panel.isReleasedWhenClosed=false;panel.level = .floating
        panel.contentView=NSHostingView(rootView:CaptureOptionsView(model:self,close:{panel.close()}))
        panel.center();captureOptionsWindow=panel;NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil)
    }
    func startCaptureMode(_ mode:String){
        if mode != "full" && fixedFrame && size==nil {notice="Enter valid frame dimensions.";return}
        switch mode {
        case "full":capture.captureFullScreen()
        case "area":recording.cancelSelection();capture.captureRegion(fixedSize:size)
        case "scroll":
            capture.cancel();recording.selectRegion(fixedSize:size){[weak self] region in
                guard let self,let region else{return}
                let session=ScrollingCapture(region:region,storage:storageRoot.appendingPathComponent("ScrollCapture"))
                session.onSaved={ [weak self] url in self?.capture.importCapture(url) }
                session.onStatus={ [weak self] text in self?.notice=text }
                self.scrollCapture=session;session.show()
            }
        case "gif","video":
            guard enabled("recording"),!recording.isBusy else{notice="Finish the current recording first.";return}
            capture.cancel();recording.selectRegion(fixedSize:size){[weak self] region in
                guard let self,let region else{return};self.gifRequested=mode=="gif"
                self.recording.start(region:region,includeMicrophone:mode=="video" && self.includeMic)
                if mode=="gif" {DispatchQueue.main.asyncAfter(deadline:.now()+30){[weak self] in if self?.gifRequested==true {self?.recording.stop()}}}
            }
        default:break
        }
    }
    func receive(_ e:VoiceEvent){
        if e.kind=="correction_suggestion" || e.kind=="correction_saved" {correctionPrompts.show(e,voice:voice)}
        if e.kind=="session_started",e.mode=="meeting",let session=e.session,systemMeetingAudio {
            meetingAudio.onChunk={ [weak self] url in self?.voice.command("system_audio",extra:["path":url.path,"session":session]) }
            meetingAudio.start()
        }
        if e.kind=="session_stopped",e.mode=="meeting" {meetingAudio.stop()}
        if e.kind=="system_audio_done",let path=e.path {
            if e.success==true && (e.empty==true || savedAudioChunks.remove(path) != nil) {meetingAudio.acknowledge(URL(fileURLWithPath:path))}
            else {meetingAudio.stop();notice="System audio transcription paused. Unprocessed audio is retained locally."}
        }
        if e.kind=="action" {let mapping=["recover":"recover","screenshot":"screenshots","annotate":"drawing","record":"recording"];if e.action=="record_stop" {recording.stop()}else if let action=mapping[e.action ?? ""] {perform(action)}}
        if e.kind=="transcript",let text=e.text {
            if e.mode=="note",enabled("organizer"){organizer.addNote(text,title:nil);notice="Voice note saved"}
            if e.mode=="reminder",enabled("organizer"){if organizer.parseReminder(text){notice="Reminder scheduled"}else{organizer.addNote(text,title:"Reminder to schedule");notice="Saved the reminder text. Choose a time in Notes & reminders."}}
        }
        if e.kind=="segment",let text=e.text,let session=e.session {
            organizer.appendTranscript(text,session:session,kind:e.mode=="ambient" ? "daily":"meeting")
            if let path=e.path,organizer.lastSaveSucceeded {savedAudioChunks.insert(path)}
            let hour=Calendar.current.component(.hour,from:Date())
            if hour != reviewHour {reviewHour=hour;_ = organizer.dailyReview(transcripts:[])}
        }

        if e.kind=="error" || e.kind=="delivery" {notice=e.message ?? "Speech error"}
    }
}
final class Hotkeys {
    static let codes:[String:UInt32]=["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,"Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"O":31,"U":32,"I":34,"P":35,"L":37,"J":38,"K":40,"N":45,"M":46,"`":50,"1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29,"Space":49,"F1":122,"F2":120,"F3":99,"F4":118,"F5":96,"F6":97,"F7":98,"F8":100,"F9":101,"F10":109,"F11":103,"F12":111]
    private var refs:[EventHotKeyRef]=[]
    private var callbacks:[UInt32:()->Void]=[:]
    private var releases:[UInt32:()->Void]=[:]
    private var pressed=Set<UInt32>()
    private var handler:EventHandlerRef?
    init(){
        var specs=[EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(),{_,event,context in
            guard let event,let context else{return OSStatus(eventNotHandledErr)}
            let owner=Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            var id=EventHotKeyID()
            GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            let down=GetEventKind(event)==UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                if down {if owner.pressed.insert(id.id).inserted {owner.callbacks[id.id]?()}}
                else {owner.pressed.remove(id.id);owner.releases[id.id]?()}
            };return noErr
        },2,&specs,Unmanaged.passUnretained(self).toOpaque(),&handler)
    }
    @discardableResult func register(key:String,modifiers:UInt32=UInt32(cmdKey|optionKey),release:(()->Void)?=nil,action:@escaping()->Void)->Bool {
        let codes=Self.codes

        guard let code=codes[key.uppercased()] else{return false}
        let id=UInt32(callbacks.count+1);var ref:EventHotKeyRef?
        guard RegisterEventHotKey(code,modifiers,EventHotKeyID(signature:0x4D544F4C,id:id),GetApplicationEventTarget(),0,&ref)==noErr,let ref else{return false}
        refs.append(ref);callbacks[id]=action;releases[id]=release;return true
    }
    func clear(){for id in pressed {releases[id]?()};pressed=[];refs.forEach{UnregisterEventHotKey($0)};refs=[];callbacks=[:];releases=[:]}
}
struct ToolCard<Content:View>:View {
    let title:String;let subtitle:String;var accent:Color = .cyan;@ViewBuilder var content:()->Content
    var body:some View {VStack(alignment:.leading,spacing:14){Text(title).font(.system(size:14,weight:.semibold));if !subtitle.isEmpty {Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)};content()}.frame(maxWidth:.infinity,alignment:.leading).padding(18).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).overlay{RoundedRectangle(cornerRadius:18).strokeBorder(.white.opacity(0.06),lineWidth:1)}}
}
struct RootView:View {
    @ObservedObject var model:AppModel
    @State private var captureSection="Capture"
    var voiceTabs:some View {Picker("Voice section",selection:$model.page){Text("Settings").tag(ToolPage.voice);Text("History").tag(ToolPage.history);Text("Corrections").tag(ToolPage.corrections)}.pickerStyle(.segmented)}
    var body:some View {HStack(spacing:0){VStack(alignment:.leading,spacing:6){HStack{Image(systemName:"command.square.fill").font(.title).foregroundStyle(.cyan);VStack(alignment:.leading){Text("Pico").font(.headline);Text("YOUR LOCAL TOOLBOX").font(.system(size:9,weight:.semibold,design:.monospaced)).tracking(1.1).foregroundStyle(.secondary)}}.padding(.bottom,26)
        ForEach(ToolPage.allCases.filter{$0 != .history && $0 != .corrections && $0 != .continuous}){p in Button{model.page=p} label:{HStack(spacing:11){Image(systemName:p.symbol).foregroundStyle(p.color).frame(width:22);Text(p.rawValue);Spacer(minLength:0)}.padding(.horizontal,10).frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(Rectangle()).background(model.page==p ? .white.opacity(0.09):.clear,in:RoundedRectangle(cornerRadius:9))}.buttonStyle(.plain)}
        Spacer();Text("LOCAL FIRST · v0.1").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
    }.padding(18).frame(width:224).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:22)).overlay{RoundedRectangle(cornerRadius:22).strokeBorder(.white.opacity(0.12),lineWidth:1)}.padding(8);VStack(spacing:0){HStack{VStack(alignment:.leading,spacing:5){Text(model.page.rawValue).font(.system(size:22,weight:.semibold));Text(subtitle).font(.callout).foregroundStyle(.secondary)};Spacer();Image(systemName:model.page.symbol).font(.system(size:30,weight:.light)).foregroundStyle(model.page.color)}.padding(28)
        ScrollView{content.padding(.horizontal,28).padding(.bottom,28)}.id(model.recoveryID);Divider();Text(model.notice).font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(13)
    }.background(Color.black.opacity(0.12))}.frame(minWidth:960,minHeight:700).preferredColorScheme(.dark).toggleStyle(.switch).tint(.blue)}
    var subtitle:String {switch model.page {case .home:return "Capture an idea. Show it clearly. Keep moving.";case .voice:return "Your voice, transcribed on your Mac.";case .corrections:return "Words your way. Confirm, disable or remove a correction.";case .history:return "Copy a past transcription or tune your word corrections.";case .capture:return "Select, annotate, then drag it wherever you need it.";case .drawing:return "Draw directly over your screen.";case .recording:return "Record a region, with a frame you control.";case .organizer:return "A place for quick thoughts and timely nudges.";case .continuous:return "Visible, optional capture. Always under your control.";case .settings:return "Choose your shortcuts and the tools you want."}}
    @ViewBuilder var content:some View {
        switch model.page {
        case .home: VStack(spacing:18){ToolCard(title:"One menu. Your everyday tools.",subtitle:"Use the menu bar, a shortcut, or an enabled voice command."){LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12){quick("Screenshot","viewfinder","screenshots");quick("Draw on screen","pencil.tip","drawing");quick("Record a region","record.circle","recording");quick("Take a note","note.text","notes")}};VoiceSummary(voice:model.voice);ToolCard(title:"Ready when you are",subtitle:"Screenshot and recording need Screen Recording permission. Start local speech from Setup. The first start downloads the selected model.",accent:.orange){Button("Permissions & settings"){model.page = .settings}}}
        case .voice: VStack(spacing:18){voiceTabs;DictationModesView(voice:model.voice);VoiceFeedbackSettings(voice:model.voice);VoiceView(voice:model.voice)}
        case .corrections:VStack(spacing:18){voiceTabs;SpeechHistoryView(voice:model.voice,correctionsOnly:true)}
        case .history:VStack(spacing:18){voiceTabs;SpeechHistoryView(voice:model.voice,saveAsNote:{text in model.organizer.addNote(text);model.notice="Saved a copy in Notes."})}
        case .capture: VStack(spacing:18){Picker("Screenshot section",selection:$captureSection){Text("Capture").tag("Capture");Text("History").tag("History");Text("Settings").tag("Settings")}.pickerStyle(.segmented)
            if captureSection=="History" {CaptureHistoryView(capture:model.capture)}
            else if captureSection=="Settings" {ToolCard(title:"Screenshot settings",subtitle:"Choose how screenshots are captured and stored."){Toggle("Enable screenshots",isOn:binding("screenshots"));HStack{Text("Capture area shortcut");Spacer();ShortcutRecorder(key:model.keys["screenshots"] ?? "S",modifiers:model.modifiers("screenshots")){key,flags in model.setShortcut("screenshots",key,flags)}.frame(width:180,height:28)};Button("Open capture options…"){model.showCaptureOptions()}};CaptureRetentionView(capture:model.capture)}
            else {ToolCard(title:"Capture a screenshot",subtitle:"Your screenshot appears in the floating tray and History. Drag it into any app, keep it, or save it to a folder.",accent:.blue){Button("Select area  \(shortcutLabel(model.keys["screenshots"] ?? "S",model.modifiers("screenshots")))"){model.perform("screenshots")}.buttonStyle(.borderedProminent)};CaptureShelf(capture:model.capture)}
        }
        case .drawing:AnnotationSettings(model:model)
        case .recording:VStack(spacing:18){ToolCard(title:"Screen recording",subtitle:"Select a free region or lock the dimensions. System audio is included; microphone audio is optional.",accent:.red){Toggle("Enable recording",isOn:binding("recording"));Toggle("Include microphone",isOn:$model.includeMic);frameControls;RecordingControls(recording:model.recording,begin:{model.perform("recording")})};Button("Open recordings folder"){NSWorkspace.shared.open(storageRoot.appendingPathComponent("Recordings"))}}
        case .organizer:if model.enabled("organizer") {NotesLibraryView(model:model)}else{ToolCard(title:"Notes · experimental",subtitle:"Local notes and keyword search. AI summaries and model discovery are deferred."){Button("Enable Notes"){model.toggle("organizer",true)}}}
        case .continuous:ContinuousView(voice:model.voice,organizer:model.organizer,meetingAudio:model.meetingAudio,systemAudio:$model.systemMeetingAudio,enabled:model.enabled("continuous"))
        case .settings:VStack(spacing:18){Button("Setup & speech runtime…"){UserDefaults.standard.set(false,forKey:"setupComplete");model.hotkeys?.clear()};ToolCard(title:"Modules",subtitle:"Turn off the tools you do not need."){ForEach(["screenshots","drawing","recording","organizer","continuous"],id:\.self){key in Toggle(key.capitalized,isOn:binding(key))}};ToolCard(title:"Recover the last transcription",subtitle:"Double-tap to paste your latest saved transcription into the focused text box. Triple-tap to open history. Paste waits briefly for a possible third tap. No GPU work is started."){Picker("Double-tap key",selection:Binding(get:{model.voice.settings.recoveryKey ?? "shift"},set:{model.voice.settings.recoveryKey=$0;model.voice.persist()})){Text("Shift").tag("shift");Text("Command").tag("command");Text("Option").tag("option");Text("Off").tag("off")}};ShortcutSettings(model:model);ToolCard(title:"Permissions & recovery",subtitle:"macOS controls screen capture, microphone and Accessibility access. Enable permissions for Pico when prompted.",accent:.orange){HStack{Button("Screen Recording"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)};Button("Microphone"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)};Button("Accessibility"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)}};Button("Reset speech worker"){model.voice.reset()};Button("Open local data folder"){NSWorkspace.shared.open(storageRoot)};Text("Email watching is deferred. No cloud accounts are connected.").font(.caption).foregroundStyle(.secondary)}}
        }
    }
    func binding(_ key:String)->Binding<Bool>{Binding(get:{model.enabled(key)},set:{model.toggle(key,$0)})}
    func quick(_ title:String,_ symbol:String,_ action:String)->some View{Button{model.perform(action)}label:{HStack{Image(systemName:symbol).font(.title2).frame(width:35);Text(title);Spacer()}.padding(17).background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:10))}.buttonStyle(.plain)}
    var frameControls:some View {VStack(alignment:.leading){Toggle("Lock frame dimensions",isOn:$model.fixedFrame);if model.fixedFrame {HStack{TextField("Width",text:$model.frameWidth).frame(width:90);Text("×");TextField("Height",text:$model.frameHeight).frame(width:90);Text("screen points").foregroundStyle(.secondary)};HStack{Button("16:9 · 1280×720"){model.frameWidth="1280";model.frameHeight="720"};Button("Square · 720×720"){model.frameWidth="720";model.frameHeight="720"};Button("Vertical · 720×1280"){model.frameWidth="720";model.frameHeight="1280"}}.font(.caption)}}}
}
struct VoiceSummary:View {
    @ObservedObject var voice:VoiceBridge
    var body:some View {ToolCard(title:"Voice is \(voice.connected ? "ready":"connecting")",subtitle:voice.state.status){HStack{Circle().fill(voice.connected ? .green:.orange).frame(width:8,height:8);Text(!voice.connected ? "Speech worker disconnected — use Reset speech":voice.state.recording ? "Microphone recording":"Hold Fn to dictate");Spacer();Toggle("Wake phrases",isOn:Binding(get:{voice.settings.wakeEnabled},set:{voice.setWake($0)})).toggleStyle(.switch).tint(.blue)}}}
}
struct VoiceView:View {
    @ObservedObject var voice:VoiceBridge
    private let phraseOrder=["start","stop","cancel","send","screenshot","annotate","record","record_stop","note","reminder","meeting"]
    private let names=["start":"Start dictation","stop":"Stop & save","cancel":"Cancel","send":"Stop & send","screenshot":"Screenshot","annotate":"Screen drawing","record":"Start screen recording","record_stop":"Stop screen recording","note":"Take a note","reminder":"Make a reminder","meeting":"Transcribe a meeting"]
    var body:some View{VStack(spacing:18){VoiceSummary(voice:voice);ToolCard(title:"Dictation",subtitle:"Hold Fn to speak, or tap Fn to toggle. With wake phrases enabled, say your Start phrase, wait for the cue, then speak."){Toggle("Enable dictation",isOn:$voice.settings.dictationEnabled).onChange(of:voice.settings.dictationEnabled){voice.persist()};Toggle("Live typing into the focused text box",isOn:$voice.settings.liveEnabled).onChange(of:voice.settings.liveEnabled){voice.persist()};Text("Text appears in your focused text box every few seconds as you speak. When you stop, the final transcript replaces that provisional text. Editing the text or moving the cursor pauses live typing to protect your changes.").font(.caption).foregroundStyle(.secondary);HStack{Button(voice.state.recording ? "Stop & save":"Start transcribing here"){voice.command(voice.state.recording ? "stop":"live")}.buttonStyle(.borderedProminent);Button("Cancel"){voice.command("cancel")};Button("Reset speech"){voice.reset()}};if !voice.preview.isEmpty || !voice.finalText.isEmpty{Text(voice.preview.isEmpty ? voice.finalText:voice.preview).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(15).background(.black.opacity(0.2),in:RoundedRectangle(cornerRadius:10));Button("Copy text"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(voice.preview.isEmpty ? voice.finalText:voice.preview,forType:.string)}}};ToolCard(title:"Your phrases",subtitle:"Type your own English phrases. Distinct phrases of 2–4 words reduce accidental activations. No voice training required.",accent:.mint){ForEach(phraseOrder,id:\.self){key in HStack{Text(names[key] ?? key).frame(width:160,alignment:.leading);TextField("Phrase",text:Binding(get:{voice.settings.phrases[key] ?? ""},set:{voice.settings.phrases[key]=$0})).textFieldStyle(.roundedBorder)}};Button("Save phrases"){voice.persist()}.buttonStyle(.borderedProminent);if !voice.error.isEmpty {Text(voice.error).foregroundStyle(.orange)}};ToolCard(title:"Voice sending",subtitle:"The Send phrase stops dictation, inserts the final text and presses a verified nearby Send button. Supported apps include ChatGPT/Codex, Claude, Slack and Messages. If the target cannot be verified, it keeps the text saved.",accent:.orange){Toggle("Finish dictation and send when I say my Send phrase",isOn:$voice.settings.sendEnabled).onChange(of:voice.settings.sendEnabled){voice.persist()};Toggle("Also let this phrase send the current message when I am not dictating",isOn:$voice.settings.standaloneSend).disabled(!voice.settings.sendEnabled).onChange(of:voice.settings.standaloneSend){voice.persist()};Text("The first switch sends after dictation. The second also works on text already in your message box. Continuous notes never sends messages.").font(.caption).foregroundStyle(.secondary)}}}
}
struct CaptureShelf:View {
    @ObservedObject var capture:CaptureCoordinator
    var body:some View{ToolCard(title:"Recent captures",subtitle:capture.status,accent:.blue){if capture.captures.isEmpty {Text("Your first screenshot will appear here and in the floating tray.").foregroundStyle(.secondary)};ForEach(capture.captures.prefix(6)){item in HStack{Image(nsImage:captureThumbnail(item.url,maxPixels:220) ?? NSImage()).resizable().aspectRatio(contentMode:.fit).frame(width:100,height:65).cornerRadius(5);Text(item.url.lastPathComponent).lineLimit(1);Spacer();Button("Annotate"){capture.openEditor(item)};Button("Show"){capture.reveal(item)}}}}}
}
struct RecordingControls:View {
    @ObservedObject var recording:RecordingCoordinator
    var begin:()->Void
    var body:some View{VStack(alignment:.leading,spacing:12){Text(recording.status).foregroundStyle(.secondary);Button(recording.isRecording ? "Stop recording":"Select area & record",action:begin).buttonStyle(.borderedProminent).tint(recording.isRecording ? .red:.blue).disabled(recording.isBusy && !recording.isRecording);if let url=recording.lastRecording{Button("Show latest recording"){NSWorkspace.shared.activateFileViewerSelecting([url])}}}}
}
struct ContinuousView:View {
    @ObservedObject var voice:VoiceBridge
    @ObservedObject var organizer:OrganizerStore
    @ObservedObject var meetingAudio:MeetingAudioCapture
    @Binding var systemAudio:Bool
    var enabled:Bool = true
    var body:some View{VStack(spacing:18){ToolCard(title:"Meeting transcript",subtitle:"Transcribe your microphone in short segments and collect them in one local note. System audio can be added when Screen Recording permission is enabled.",accent:.mint){Toggle("Include audio from the meeting app",isOn:$systemAudio).disabled(voice.state.mode=="meeting");Text(meetingAudio.status).font(.caption).foregroundStyle(.secondary);Button(voice.state.mode=="meeting" ? "Stop meeting transcript":"Start meeting transcript"){voice.command(voice.state.mode=="meeting" ? "stop":"meeting")}.buttonStyle(.borderedProminent).disabled(!enabled);Text(voice.state.status).foregroundStyle(.secondary)};ToolCard(title:"Continuous notes",subtitle:"Opt in when you want to capture your spoken thoughts. Microphone speech is transcribed into a local session note. A visible indicator stays on, and locking the screen pauses capture.",accent:.orange){Button(voice.state.mode=="ambient" ? "Stop continuous notes":"Start continuous notes"){voice.command(voice.state.mode=="ambient" ? "stop":"ambient")}.disabled(!enabled);Text("This mode saves what it hears. It does not execute ambient voice commands, send messages, or upload recordings.").font(.caption).foregroundStyle(.secondary)};ToolCard(title:"Daily review",subtitle:"Find recurring words and explicit follow-ups in today's saved notes. This first version uses local text analysis; it does not infer your mood or claim to know what you are stuck on."){Button("Build today's review"){_ = organizer.dailyReview(transcripts:[])};Text("Your review is saved in Notes → Library → Reviews.").font(.caption).foregroundStyle(.secondary)}}}
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    var model:AppModel!;var window:NSWindow!;var statusItem:NSStatusItem!;var stateTimer:Timer?
    func applicationDidFinishLaunching(_ notification:Notification){
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        model=AppModel();model.hotkeys=Hotkeys();if UserDefaults.standard.bool(forKey:"setupComplete"){model.registerHotkeys();if model.voice.settings.dictationEnabled {model.voice.startSpeech()}}
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1050,height:788),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:.darkAqua)
        window.backgroundColor=NSColor(calibratedRed:0.13,green:0.15,blue:0.16,alpha:1)
        window.title="Pico";window.titleVisibility = .hidden
        window.titlebarAppearsTransparent=true;window.isReleasedWhenClosed=false
        // One native material spans the content AND titlebar. Keep controls in a
        // dedicated top strip; never put a second title behind the traffic lights.
        let glass=NSVisualEffectView()
        glass.material = .sidebar;glass.blendingMode = .behindWindow;glass.state = .active
        glass.appearance=NSAppearance(named:.darkAqua)
        let hosting=NSHostingView(rootView:ApplicationShell(model:model))
        hosting.translatesAutoresizingMaskIntoConstraints=false
        glass.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo:glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo:glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo:glass.topAnchor,constant:28),
            hosting.bottomAnchor.constraint(equalTo:glass.bottomAnchor)
        ])
        window.contentView=glass
        window.center();window.minSize=NSSize(width:960,height:728)
        model.showWindow={ [weak self] in self?.show() }
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        statusItem.button?.image=NSImage(systemSymbolName:"command.square",accessibilityDescription:"Pico")
        statusItem.button?.imagePosition = .imageLeading
        let menu=NSMenu()
        add(menu,"Open Pico",#selector(showAction),"")
        menu.addItem(.separator())
        add(menu,"Screenshot history",#selector(screenshotHistory),"")
        add(menu,"Settings & hotkeys…",#selector(settingsAction),",")
        add(menu,"Voice appearance & sounds…",#selector(voiceSettingsAction),"")
        menu.addItem(.separator())
        add(menu,"Pause all speech capture",#selector(pauseSpeech),"")
        add(menu,"Quit Pico",#selector(quit),"q")
        statusItem.menu=menu
        stateTimer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in guard let self else{return};let active=self.model.voice.state.recording || ["meeting","ambient"].contains(self.model.voice.state.mode);self.statusItem.button?.title=self.model.recording.isRecording ? " REC":active ? " MIC":"";self.statusItem.button?.toolTip=self.model.voice.state.status}}
        show()
    }
    private func installMainMenu(){
        let bar=NSMenu()
        let appItem=NSMenuItem();let appMenu=NSMenu(title:"Pico");appItem.submenu=appMenu;bar.addItem(appItem)
        appMenu.addItem(withTitle:"Hide Pico",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"Quit Pico",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();let edit=NSMenu(title:"Edit");editItem.submenu=edit;bar.addItem(editItem)
        for (title,selector,key) in [("Undo","undo:","z"),("Redo","redo:","Z"),("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {edit.addItem(withTitle:title,action:NSSelectorFromString(selector),keyEquivalent:key)}
        NSApp.mainMenu=bar
    }
    func add(_ menu:NSMenu,_ title:String,_ action:Selector,_ key:String){let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=self;menu.addItem(item)}
    func show(){NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)}
    @objc func showAction(){show()}
    @objc func screenshotHistory(){model.capture.showRecentHistory()}
    @objc func settingsAction(){model.page = .settings;show()}
    @objc func voiceSettingsAction(){model.page = .voice;show()}
    @objc func toolAction(_ sender:NSMenuItem){if let action=sender.representedObject as? String{model.perform(action)}}
    @objc func pauseSpeech(){model.voice.settings.wakeEnabled=false;model.voice.persist();model.voice.command("pause")}
    @objc func resetSpeech(){model.voice.reset()}
    @objc func quit(){NSApp.terminate(nil)}

    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{guard model.capture.prepareToQuit() else{return .terminateCancel};model.voice.command("pause");Task{@MainActor in await model.meetingAudio.finishBeforeQuit();await model.recording.finishBeforeQuit();NSApp.reply(toApplicationShouldTerminate:true)};return .terminateLater}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{show();return true}
}
@main struct PicoMain {
    @MainActor static func main(){let app=NSApplication.shared;let delegate=AppDelegate();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}}
}
