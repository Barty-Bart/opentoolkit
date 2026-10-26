import AppKit
import SwiftUI
import Carbon
import ScreenCaptureKit
import AVFoundation
import Combine

let storageRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pico",isDirectory:true)
enum ToolPage: String, CaseIterable, Identifiable {
    case home="Home", voice="Dictation", history="Speech history", corrections="Corrections", capture="Screenshots", drawing="Annotation", recording="Recording", organizer="Notes", continuous="Meeting & daily notes", settings="Settings"
    var id:String{rawValue}
    var symbol:String { switch self {case .home:return "house";case .voice:return "waveform";case .corrections:return "text.badge.checkmark";case .history:return "clock.arrow.circlepath";case .capture:return "viewfinder";case .drawing:return "pencil.tip.crop.circle";case .recording:return "record.circle";case .organizer:return "note.text";case .continuous:return "text.bubble";case .settings:return "slider.horizontal.3"} }
    var color:Color {switch self {case .voice:return .cyan;case .capture:return .blue;case .drawing:return .orange;case .recording:return .red;case .organizer:return .yellow;case .continuous:return .mint;default:return .secondary}}
}
@MainActor final class AppModel: ObservableObject {
    @Published var recoveryID = UUID()
    @Published var page:ToolPage = .home
    /// Dictation › History shows only transcripts containing this word (set from Home's Your words).
    @Published var historyFilter:String?
    @Published var captureSection="Capture"
    @Published var settingsSection:SettingsSection = .general
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
    let updates=AppUpdates()
    private var updateObserver:AnyCancellable?
    let voice:VoiceBridge
    let capture:CaptureCoordinator
    let recording:RecordingCoordinator
    let organizer:OrganizerStore
    let meetingAudio:MeetingAudioCapture
    let usage:UsageLog
    private var drawingStartedAt:Date?
    @Published var systemMeetingAudio=true
    private var captureOptionsWindow:NSPanel?
    // Identifies the GIF recording in flight; a failed start must not convert or stop a later recording.
    private var gifRecording:UUID?
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
        usage=UsageLog();UsageLog.shared=usage
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
        capture.onShowAllHistory={ [weak self] in self?.page = .capture;self?.showWindow?() }
        capture.onDrawingActiveChanged={ [weak self] active in
            guard let self else{return}
            if active {drawingStartedAt=Date()}
            else if let start=drawingStartedAt {drawingStartedAt=nil;usage.record("draw_session",seconds:Date().timeIntervalSince(start),at:start)}
            registerDrawingTools()
        }
        // The sidebar bubble and Settings order follow update availability.
        updateObserver=updates.objectWillChange.sink{ [weak self] _ in self?.objectWillChange.send() }
        updates.busyReason={ [weak self] in
            guard let self else{return nil}
            if voice.state.recording || voice.state.busy {return "Finish your dictation, then install the update."}
            if recording.isRecording || recording.isBusy {return "Stop the screen recording, then install the update."}
            if ["meeting","ambient"].contains(voice.state.mode) {return "Stop the meeting or continuous notes, then install the update."}
            return nil
        }
        recording.onSaved={ [weak self] url in
            guard let self else{return};do {try LibraryDatabase().put(id:"media:"+url.lastPathComponent,kind:"video",title:url.lastPathComponent,body:"Screen recording",path:url.path)}catch{self.notice=error.localizedDescription};guard self.gifRecording != nil else{self.usage.recordVideo(url);return};self.gifRecording=nil;self.notice="Converting recording to GIF…"
            Task {do {let result=try await Task.detached(priority:.utility){try GIFExport.convert(url)}.value;self.notice="GIF ready: \(result.lastPathComponent)";self.usage.record("record_gif");self.capture.importCapture(result)}catch{self.notice="GIF conversion failed. The MP4 is preserved: \(error.localizedDescription)"}}
        }
        recording.onStatus={ [weak self] text in self?.notice=text }
        meetingAudio.onStatus={ [weak self] text in self?.notice=text }
        organizer.onStatus={ [weak self] text in self?.notice=text }
        if let migrationError {notice=migrationError}
    }
    var size:CGSize? {guard fixedFrame,let w=Double(frameWidth),let h=Double(frameHeight),w>=32,h>=32,w<=16384,h<=16384 else{return nil};return CGSize(width:w,height:h)}
    func enabled(_ key:String)->Bool{toggles[key] ?? true}
    func toggle(_ key:String,_ value:Bool){toggles[key]=value;UserDefaults.standard.set(toggles,forKey:"modules");voice.settings.organizerEnabled=enabled("organizer");voice.settings.continuousEnabled=enabled("continuous");voice.persist();if !value {if key=="recording" {recording.stop()};if key=="drawing" || key=="screenshots" {capture.cancel()};if key=="continuous" {voice.command("stop");meetingAudio.stop()};if key=="organizer" {organizer.remindersEnabled=false;organizer.hideFocusPanel()}};registerHotkeys()}
    func registerHotkeys(){hotkeys?.clear();shortcutIssues=[:];for (action,key) in keys {guard !key.isEmpty,enabled(action=="notes" || action=="reminders" ? "organizer":(["fullScreenshot","captureOptions"].contains(action) ? "screenshots":action)) else{continue}
            let registered=action=="drawing"
                ? hotkeys?.register(key:key,modifiers:modifiers(action),release:{[weak self] in self?.drawingKeyReleased()},action:{[weak self] in self?.drawingKeyPressed()})
                : hotkeys?.register(key:key,modifiers:modifiers(action),action:{[weak self] in self?.perform(action)})
            if registered == false {shortcutIssues[action]="macOS or another app is already using \(shortcutLabel(key,modifiers(action))). Choose another combination or turn it off in that app.";notice="Shortcut unavailable: \(shortcutLabel(key,modifiers(action)))"}};UserDefaults.standard.set(keys,forKey:"shortcuts")
        registerDrawingTools()
        UserDefaults.standard.set(annotationKeys,forKey:"annotationKeys")
    }
    /// Tool keys such as ⌃A or ⌃E are standard text-editing keys in every app, so
    /// they are registered only while screen drawing is on, then released again.
    func registerDrawingTools(){
        hotkeys?.clear(group:"drawing")
        guard enabled("drawing"),capture.isDrawingActive else{return}
        for (name,chord) in annotationKeys {
            let parts=chord.split(separator:"+").map(String.init)
            guard let letter=parts.last,parts.count==2 else{continue}
            let flags:UInt32=parts[0]=="cmd" ? UInt32(cmdKey):parts[0]=="alt" ? UInt32(optionKey):UInt32(controlKey)
            if hotkeys?.register(key:letter,modifiers:flags,group:"drawing",release:{[weak self] in self?.capture.releaseDrawing(name)},action:{[weak self] in self?.capture.annotationAction(name)}) == false {notice="Drawing shortcut unavailable: \(chord). Quit the other annotation app or choose another shortcut."}
        }
    }
    private var drawingKeyDownAt:Date?
    /// Tap Draw on Screen to toggle drawing; hold it to draw only while held.
    func drawingKeyPressed(){let starting = !capture.isDrawingActive;perform("drawing");drawingKeyDownAt = starting && capture.isDrawingActive ? Date():nil}
    func drawingKeyReleased(){if let start=drawingKeyDownAt,Date().timeIntervalSince(start)>0.45,capture.isDrawingActive {capture.endDrawing()};drawingKeyDownAt=nil}
    func modifiers(_ action:String)->UInt32 {UInt32(keyModifiers[action] ?? Int(cmdKey|optionKey))}
    /// Per-shortcut problems shown inline under the row in Settings › Shortcuts.
    @Published var shortcutIssues:[String:String]=[:]
    static let shortcutTitles=["screenshots":"Capture area","fullScreenshot":"Capture full screen","captureOptions":"All capture options","recording":"Record screen","drawing":"Draw on screen","voice":"Start or stop dictation","recover":"Open dictation history","notes":"Open Notes","reminders":"New reminder"]
    func setShortcut(_ action:String,_ key:String,_ flags:UInt32){
        if let other=keys.first(where:{$0.key != action && !$0.value.isEmpty && $0.value==key && modifiers($0.key)==flags})?.key {
            shortcutIssues[action]="\(shortcutLabel(key,flags)) is already used by “\(Self.shortcutTitles[other] ?? other)”. Clear that one first.";return
        }
        keys[action]=key;keyModifiers[action]=Int(flags)
        UserDefaults.standard.set(keyModifiers,forKey:"shortcutModifiers")
        notice="Shortcut saved: \(shortcutLabel(key,flags))";registerHotkeys()
    }
    /// An empty key means "no shortcut"; it is kept so defaults aren't restored on launch.
    func clearShortcut(_ action:String){keys[action]="";shortcutIssues[action]=nil;notice="Shortcut removed";registerHotkeys()}
    func perform(_ action:String) {
        if action=="recording" && fixedFrame && size==nil {notice="Enter a frame width and height from 32 to 16,384 points.";return}
        switch action {
        case "fullScreenshot":guard enabled("screenshots") else{return};capture.captureFullScreen()
        case "captureOptions":guard enabled("screenshots") else{return};showCaptureOptions()
        case "screenshots": guard enabled("screenshots") else{return};recording.cancelSelection();capture.captureRegion(fixedSize:nil)
        case "drawing":guard enabled("drawing") else{return};if capture.isDrawingActive {capture.endDrawing()}else{recording.cancelSelection();capture.annotateScreen()}
        case "recording":guard enabled("recording") else{return};if recording.isRecording {recording.stop()}else{capture.cancel();recording.selectRegion(fixedSize:size){[weak self] region in guard let self,let region else{return};self.gifRecording=nil;self.recording.start(region:region,includeMicrophone:self.includeMic)}}
        case "notes":guard enabled("organizer") else{return};page = .organizer;showWindow?()
        case "reminders":guard enabled("organizer") else{return};page = .organizer;showWindow?();organizer.presentReminderComposer()
        case "recover":recoveryID = UUID();historyFilter=nil;page = .history;showWindow?();notice="Latest saved transcription is at the top. Click Copy to recover it."
        case "voice":if voice.state.recording {voice.command("stop")}else{voice.command("start")}
        default:break
        }
    }
    func showCaptureOptions(){
        captureOptionsWindow?.close()
        var close:()->Void={}
        let host=NSHostingView(rootView:CaptureOptionsView(model:self,close:{close()}))
        let panel=CaptureBarPanel(content:host)
        close={[weak panel] in panel?.close()};panel.onCancel=close
        // Size to the bar and sit near the bottom centre of the screen with the pointer.
        let screen=NSScreen.screens.first{NSMouseInRect(NSEvent.mouseLocation,$0.frame,false)} ?? NSScreen.main
        let fitting=host.fittingSize,visible=screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x:visible.midX-fitting.width/2,y:visible.minY+90,width:fitting.width,height:fitting.height),display:true)
        captureOptionsWindow=panel;panel.makeKeyAndOrderFront(nil)
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
                session.onSaved={ [weak self] url in self?.usage.record("capture_scroll");self?.capture.importCapture(url) }
                session.onStatus={ [weak self] text in self?.notice=text }
                self.scrollCapture=session;session.show()
            }
        case "gif","video":
            guard enabled("recording"),!recording.isBusy else{notice="Finish the current recording first.";return}
            capture.cancel();recording.selectRegion(fixedSize:size){[weak self] region in
                guard let self,let region else{return};let token=UUID();self.gifRecording=mode=="gif" ? token:nil
                self.recording.start(region:region,includeMicrophone:mode=="video" && self.includeMic)
                if mode=="gif" {DispatchQueue.main.asyncAfter(deadline:.now()+30){[weak self] in if self?.gifRecording==token,self?.recording.isRecording==true {self?.recording.stop()}}}
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
        if e.kind=="action" {usage.record("wake_command",trigger:"voice");let mapping=["recover":"recover","screenshot":"screenshots","annotate":"drawing","record":"recording"];if e.action=="record_stop" {recording.stop()}else if let action=mapping[e.action ?? ""] {perform(action)}}
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
    private var refs:[UInt32:(ref:EventHotKeyRef,group:String)]=[:]
    private var nextID:UInt32=1
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
    @discardableResult func register(key:String,modifiers:UInt32=UInt32(cmdKey|optionKey),group:String="main",release:(()->Void)?=nil,action:@escaping()->Void)->Bool {
        let codes=Self.codes

        guard let code=codes[key.uppercased()] else{return false}
        // IDs are never reused, so a late release event can't reach a newer registration.
        let id=nextID;nextID+=1;var ref:EventHotKeyRef?
        guard RegisterEventHotKey(code,modifiers,EventHotKeyID(signature:0x4D544F4C,id:id),GetApplicationEventTarget(),0,&ref)==noErr,let ref else{return false}
        refs[id]=(ref,group);callbacks[id]=action;releases[id]=release;return true
    }
    func clear(){for id in pressed {releases[id]?()};pressed=[];refs.values.forEach{UnregisterEventHotKey($0.ref)};refs=[:];callbacks=[:];releases=[:]}
    func clear(group:String){
        for (id,entry) in refs where entry.group==group {UnregisterEventHotKey(entry.ref);refs[id]=nil;callbacks[id]=nil;releases[id]=nil;pressed.remove(id)}
    }
}
struct ToolCard<Content:View>:View {
    let title:String;let subtitle:String;var accent:Color = .cyan;@ViewBuilder var content:()->Content
    var body:some View {VStack(alignment:.leading,spacing:14){Text(title).font(.system(size:14,weight:.semibold));if !subtitle.isEmpty {Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)};content()}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).padding(18).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).overlay{RoundedRectangle(cornerRadius:18).strokeBorder(.white.opacity(0.06),lineWidth:1)}}
}
/// Settings sections, shown as a list inside the Settings page (and later a Settings window).
enum SettingsSection:String,CaseIterable,Identifiable {
    case update="Software Update",general="General",shortcuts="Shortcuts",screenshots="Screenshots",recording="Recording",drawing="Draw on Screen",dictation="Dictation",permissions="Permissions",advanced="Advanced"
    var id:String{rawValue}
    var symbol:String {switch self {case .update:return "arrow.down.circle";case .general:return "gearshape";case .shortcuts:return "keyboard";case .screenshots:return "viewfinder";case .recording:return "record.circle";case .drawing:return "pencil.tip.crop.circle";case .dictation:return "waveform";case .permissions:return "hand.raised";case .advanced:return "wrench.and.screwdriver"}}
    // Recording and drawing options live on their own sidebar pages; dictation controls on the Dictation page.
    static let groups:[(String,[SettingsSection])]=[("",[.update,.general,.shortcuts]),("Tools",[.screenshots,.dictation]),("System",[.permissions,.advanced])]
}

struct RootView:View {
    @ObservedObject var model:AppModel
    /// Sidebar groups: Home, then Speak, Capture and Draw (rows hide with their tool), Notes when on; Settings pinned at the bottom.
    private var groups:[(String,[ToolPage])] {
        var list:[(String,[ToolPage])]=[("",[.home])]
        if model.voice.settings.dictationEnabled {list.append(("Speak",[.voice,.history,.corrections]))}
        let capture=(model.enabled("screenshots") ? [ToolPage.capture]:[])+(model.enabled("recording") ? [.recording]:[])
        if !capture.isEmpty {list.append(("Capture",capture))}
        list.append(("Draw",[.drawing]))   // shown even when off; the page has the switch
        if model.enabled("organizer") {list.append(("",[.organizer]))}
        return list
    }
    /// The sidebar row that owns the current page; every row is its own page now.
    private var current:ToolPage {model.page == .continuous ? .organizer:model.page}
    private func title(_ page:ToolPage)->String {page.rawValue}
    private func row(_ page:ToolPage)->some View {
        Button{model.page = page} label:{
            HStack(spacing:11) {
                Image(systemName:page.symbol).foregroundStyle(page.color == .secondary ? Color.gray:page.color).frame(width:22)
                Text(title(page));Spacer(minLength:0)
                if page == .settings && model.updates.available != nil {Text("1").font(.system(size:11,weight:.bold)).foregroundStyle(.white).padding(.horizontal,7).padding(.vertical,2).background(Capsule().fill(Color.red)).help("An update is available")}
            }
            .padding(.horizontal,10).frame(maxWidth:.infinity,minHeight:36,alignment:.leading).contentShape(Rectangle())
            .background(current == page ? .white.opacity(0.09):.clear,in:RoundedRectangle(cornerRadius:9))
        }.buttonStyle(.plain)
    }
    var body:some View {
        HStack(spacing:0) {
            // Glass sidebar card with the coloured tool icons; Settings pinned to the bottom.
            VStack(alignment:.leading,spacing:4) {
                ForEach(groups,id:\.1) {group in
                    if !group.0.isEmpty {
                        Text(group.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal,10).padding(.top,12).padding(.bottom,2)
                    }
                    ForEach(group.1) {page in row(page)}
                }
                Spacer()
                row(.settings)
            }
            .padding(12).frame(width:212)
            .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:22))
            .overlay{RoundedRectangle(cornerRadius:22).strokeBorder(.white.opacity(0.12),lineWidth:1)}
            .padding(8)
            VStack(spacing:0) {
                if current != .home {
                    Text(title(current)).font(.system(size:22,weight:.semibold))
                        .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,28).padding(.top,22).padding(.bottom,16)
                }
                if current == .settings {settings} else {ScrollView{content.padding(.horizontal,28).padding(.bottom,28)}.id(model.recoveryID)}
                if current != .home {
                    Divider()
                    Text(model.notice).font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(13)
                }
            }.background(Color.black.opacity(0.12))
        }
        .frame(minWidth:960,minHeight:700).preferredColorScheme(.dark).toggleStyle(.switch).tint(.blue)
    }
    @ViewBuilder var content:some View {
        switch current {
        case .home:HomeDashboard(model:model)
        case .voice:VoiceView(voice:model.voice)
        case .history:SpeechHistoryView(voice:model.voice,filter:model.historyFilter,clearFilter:{model.historyFilter=nil},saveAsNote:{text in model.organizer.addNote(text);model.notice="Saved a copy in Notes."})
        case .corrections:SpeechHistoryView(voice:model.voice,correctionsOnly:true)
        case .recording:
            VStack(spacing:18) {
                ToolCard(title:"Screen recording",subtitle:"System audio is included; microphone audio is optional."){
                    Toggle("Include microphone",isOn:$model.includeMic);frameControls
                    RecordingControls(recording:model.recording,begin:{model.perform("recording")})
                    Button("Open recordings folder"){NSWorkspace.shared.open(storageRoot.appendingPathComponent("Recordings"))}
                }
                ToolCard(title:"Cursor in recordings",subtitle:"Make the pointer easy to follow in videos and GIFs."){CursorEffectsSettings()}
            }
        case .drawing:AnnotationSettings(model:model)
        case .capture:
            VStack(alignment:.leading,spacing:18) {
                HStack {
                    Spacer()
                    Button("Screenshot settings…"){model.settingsSection = .screenshots;model.page = .settings}
                }
                CaptureHistoryView(capture:model.capture)
            }
        case .organizer,.continuous:
            if model.enabled("organizer") {NotesLibraryView(model:model)}
            else {ToolCard(title:"Notes · experimental",subtitle:"Local notes and keyword search."){Button("Turn on Notes"){model.toggle("organizer",true)}}}
        default:EmptyView()
        }
    }
    /// Settings: a section list beside the selected section's controls.
    var settings:some View {
        HStack(spacing:0) {
            List(selection:Binding(get:{model.settingsSection},set:{if let section=$0 {model.settingsSection=section}})) {
                ForEach(SettingsSection.groups,id:\.0) {group in
                    Section(group.0) {
                        ForEach(group.1) {section in
                            HStack {
                                Label(section.rawValue,systemImage:section.symbol)
                                Spacer(minLength:0)
                                if section == .update && model.updates.available != nil {Circle().fill(Color.red).frame(width:8,height:8)}
                            }.tag(section)
                        }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).frame(width:210)
            Divider()
            ScrollView{settingsDetail.padding(.horizontal,24).padding(.vertical,8).padding(.bottom,20)}
        }
    }
    @ViewBuilder var settingsDetail:some View {
        VStack(spacing:18) {
            switch model.settingsSection {
            case .update:UpdateSettingsView(updates:model.updates)
            case .general:
                ToolCard(title:"Tools",subtitle:"Turn off the tools you don't need."){
                    Toggle("Dictation",isOn:Binding(get:{model.voice.settings.dictationEnabled},set:{model.voice.settings.dictationEnabled=$0;model.voice.persist()}))
                    ForEach(["screenshots","recording","drawing","organizer","continuous"],id:\.self){key in Toggle(["screenshots":"Screenshots","drawing":"Draw on screen","recording":"Screen recording","organizer":"Notes","continuous":"Meeting & daily notes"][key] ?? key,isOn:binding(key))}
                }
                UsageSettings()
            case .shortcuts:ShortcutsView(model:model)
            case .screenshots:
                ToolCard(title:"Screenshots",subtitle:"How capture looks and sounds."){
                    CrosshairColorPicker()
                    Toggle("Play a shutter sound when capturing",isOn:Binding(get:{CaptureSound.enabled},set:{UserDefaults.standard.set($0,forKey:"captureSound");if $0 {CaptureSound.play()}}))
                    Button("Open the capture bar (⇧⌘5)"){model.showCaptureOptions()}
                }
                CaptureRetentionView(capture:model.capture)
            // Older links to these sections land on the pages that now hold them.
            case .recording:Button("Recording options are on the Recording page"){model.page = .recording}
            case .drawing:Button("Drawing options are on the Annotation page"){model.page = .drawing}
            case .dictation:DictationModesView(voice:model.voice);VoiceFeedbackSettings(voice:model.voice);ToolCard(title:"Your words on Home",subtitle:"Words you hide from the Home word cloud with right-click stay hidden until you show them again here."){HiddenWordsSettings()}
            case .permissions:PermissionsView(voice:model.voice)
            case .advanced:
                ToolCard(title:"Advanced",subtitle:"Your library, settings and recordings stay in this folder on your Mac."){
                    Button("Open local data folder"){NSWorkspace.shared.open(storageRoot)}
                    Text("No accounts, cloud transcription or sync are used.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    func binding(_ key:String)->Binding<Bool>{Binding(get:{model.enabled(key)},set:{model.toggle(key,$0)})}
    var frameControls:some View {VStack(alignment:.leading){Toggle("Lock frame dimensions",isOn:$model.fixedFrame);if model.fixedFrame {HStack{TextField("Width",text:$model.frameWidth).frame(width:90);Text("×");TextField("Height",text:$model.frameHeight).frame(width:90);Text("screen points").foregroundStyle(.secondary)};HStack{Button("16:9 · 1280×720"){model.frameWidth="1280";model.frameHeight="720"};Button("Square · 720×720"){model.frameWidth="720";model.frameHeight="720"};Button("Vertical · 720×1280"){model.frameWidth="720";model.frameHeight="1280"}}.font(.caption)}}}
}
struct VoiceSummary:View {
    @ObservedObject var voice:VoiceBridge
    private var title:String {
        if !voice.connected {return "Speech is stopped"}
        if voice.state.busy {return "Transcribing…"}
        if voice.state.recording {return "Recording your voice"}
        if voice.state.awaitingCommand == true {return "Listening for your command…"}
        if voice.settings.wakeEnabled {
            return voice.state.wake && voice.state.microphone && voice.state.detectorReady ? "Listening for “\((voice.settings.wakePhrase ?? VoiceSettings.defaultWakePhrase).capitalized)”" : "Wake listener needs attention"
        }
        return voice.state.keyListenerReady == true ? "Hold Fn to dictate" : "Fn needs Accessibility permission"
    }
    var body:some View {ToolCard(title:title,subtitle:voice.connected ? voice.state.status : "Start speech to use Fn and voice commands."){
        Toggle("Listen for wake phrase",isOn:Binding(get:{voice.settings.wakeEnabled},set:{voice.setWake($0)}))
        HStack {
            Label(voice.state.keyListenerReady == true && voice.connected ? "Fn ready" : "Fn unavailable",systemImage:"keyboard")
            Spacer()
            if !voice.connected {Button("Start speech"){voice.startSpeech()}}
            else if voice.settings.wakeEnabled && !voice.state.wake {Button("Resume wake listener"){voice.setWake(true)}}
        }.font(.callout)
        if !voice.error.isEmpty {Text(voice.error).foregroundStyle(.orange)}
    }}
}
struct VoiceView:View {
    @ObservedObject var voice:VoiceBridge
    private let phraseOrder=["start","stop","cancel","send","screenshot","annotate","record","record_stop","note","reminder","meeting","summarize","email"]
    private let names=["start":"Start dictation","stop":"Stop & save","cancel":"Cancel","send":"Stop & send","screenshot":"Screenshot","annotate":"Screen drawing","record":"Start screen recording","record_stop":"Stop screen recording","note":"Take a note","reminder":"Make a reminder","meeting":"Transcribe a meeting","summarize":"Summarize speech","email":"Draft an email"]
    var body:some View{VStack(spacing:18){VoiceSummary(voice:voice);ToolCard(title:"Dictation",subtitle:"Hold Fn to speak, or tap Fn to toggle. With voice commands enabled, say your wake phrase, wait for its cue, then say “start dictating”."){Toggle("Enable dictation",isOn:$voice.settings.dictationEnabled).onChange(of:voice.settings.dictationEnabled){voice.persist()};Toggle("Live typing into the focused text box",isOn:$voice.settings.liveEnabled).onChange(of:voice.settings.liveEnabled){voice.persist()};Text("Text appears in your focused text box every few seconds as you speak. When you stop, the final transcript replaces that provisional text. Editing the text or moving the cursor pauses live typing to protect your changes.").font(.caption).foregroundStyle(.secondary);HStack{Button(voice.state.recording ? "Stop & save":"Start transcribing here"){voice.command(voice.state.recording ? "stop":"live")}.buttonStyle(.borderedProminent);Button("Cancel"){voice.command("cancel")};Button("Reset speech"){voice.reset()}};if !voice.preview.isEmpty || !voice.finalText.isEmpty{Text(voice.preview.isEmpty ? voice.finalText:voice.preview).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(15).background(.black.opacity(0.2),in:RoundedRectangle(cornerRadius:10));Button("Copy text"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(voice.preview.isEmpty ? voice.finalText:voice.preview,forType:.string)}}};VoiceCommandsView(voice:voice);ToolCard(title:"Voice sending",subtitle:"The Send phrase stops dictation, inserts the final text and presses a verified nearby Send button. Supported apps include ChatGPT/Codex, Claude, Slack and Messages. If the target cannot be verified, it keeps the text saved.",accent:.orange){Toggle("Finish dictation and send when I say my Send phrase",isOn:$voice.settings.sendEnabled).onChange(of:voice.settings.sendEnabled){voice.persist()};Toggle("Also let this phrase send the current message when I am not dictating",isOn:$voice.settings.standaloneSend).disabled(!voice.settings.sendEnabled).onChange(of:voice.settings.standaloneSend){voice.persist()};Text("The first switch sends after dictation. The second also works on text already in your message box. Continuous notes never sends messages.").font(.caption).foregroundStyle(.secondary)}}}
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
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSMenuDelegate {
    var model:AppModel!;var window:NSWindow!;var statusItem:NSStatusItem!;var stateTimer:Timer?
    func applicationDidFinishLaunching(_ notification:Notification){
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        model=AppModel();model.hotkeys=Hotkeys();model.updates.startAutomaticChecks();pointerGlow.bind(to:model.voice);if UserDefaults.standard.bool(forKey:"setupComplete"){model.registerHotkeys();if model.voice.settings.dictationEnabled {model.voice.startSpeech()}}
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1050,height:788),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:.darkAqua)
        window.backgroundColor=NSColor(calibratedRed:0.13,green:0.15,blue:0.16,alpha:1)
        window.title="OpenToolkit";window.titleVisibility = .hidden
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
        statusItem.button?.image=Self.menuBarSymbol()
        statusItem.button?.imagePosition = .imageLeading
        // Rebuilt on every open so shortcuts, recording/drawing state and the wake
        // checkmark always match the current settings.
        let menu=NSMenu();menu.delegate=self;menu.autoenablesItems=false
        statusItem.menu=menu
        stateTimer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in guard let self else{return};let active=self.model.voice.state.recording || ["meeting","ambient"].contains(self.model.voice.state.mode);self.statusItem.button?.title=self.model.recording.isRecording ? " REC":active ? " MIC":"";self.statusItem.button?.toolTip=self.model.updates.available.map{"OpenToolkit \($0.tag_name) is available"} ?? self.model.voice.state.status;self.showUpdateBadge(self.model.updates.available != nil)}}
        // Maintenance updates can resume the menu-bar app without stealing the
        // text field the user is working in. A normal launch still opens Tools.
        if !CommandLine.arguments.contains("--background") {show()}
    }
    private func installMainMenu(){
        let bar=NSMenu()
        let appItem=NSMenuItem();let appMenu=NSMenu(title:"OpenToolkit");appItem.submenu=appMenu;bar.addItem(appItem)
        appMenu.addItem(withTitle:"About OpenToolkit",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator())
        let settings=NSMenuItem(title:"Settings…",action:#selector(settingsAction),keyEquivalent:",");settings.target=self;appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Hide OpenToolkit",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"Quit OpenToolkit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();let edit=NSMenu(title:"Edit");editItem.submenu=edit;bar.addItem(editItem)
        for (title,selector,key) in [("Undo","undo:","z"),("Redo","redo:","Z"),("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {edit.addItem(withTitle:title,action:NSSelectorFromString(selector),keyEquivalent:key)}
        let windowItem=NSMenuItem();let windowMenu=NSMenu(title:"Window");windowItem.submenu=windowMenu;bar.addItem(windowItem)
        windowMenu.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windowMenu.addItem(withTitle:"Close",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        NSApp.windowsMenu=windowMenu
        NSApp.mainMenu=bar
    }
    func add(_ menu:NSMenu,_ title:String,_ action:Selector,_ key:String){let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=self;menu.addItem(item)}
    func menuNeedsUpdate(_ menu:NSMenu){
        guard menu === statusItem.menu else{return}
        menu.removeAllItems()
        if let release=model.updates.available {
            let item=NSMenuItem(title:"Update Available: OpenToolkit \(release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()):release.tag_name)…",action:#selector(updateAvailableAction),keyEquivalent:"")
            item.target=self;item.image=NSImage(systemSymbolName:"circle.fill",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:8,weight:.regular).applying(.init(paletteColors:[.systemRed])))
            menu.addItem(item);menu.addItem(.separator())
        }
        func tool(_ title:String,_ action:String,shortcut:String?=nil){
            let item=NSMenuItem(title:title,action:#selector(toolAction(_:)),keyEquivalent:"");item.target=self;item.representedObject=action
            if let name=shortcut,let key=model.keys[name] {item.keyEquivalent=key.lowercased();item.keyEquivalentModifierMask=modifierMask(model.modifiers(name))}
            menu.addItem(item)
        }
        func heading(_ title:String){menu.addItem(NSMenuItem.sectionHeader(title:title))}
        if model.enabled("screenshots") {
            heading("Capture")
            tool("Capture Area","screenshots",shortcut:"screenshots")
            tool("Capture Full Screen","fullScreenshot",shortcut:"fullScreenshot")
            tool("Scrolling Capture","mode:scroll")
            tool("All Capture Options…","captureOptions",shortcut:"captureOptions")
        }
        if model.enabled("recording") {
            if model.recording.isRecording {tool("Stop Recording","recording",shortcut:"recording")}
            else {tool("Record Screen…","recording",shortcut:"recording");tool("Record GIF…","mode:gif")}
        }
        // Draw stays in the menu when it's off, so it's easy to find and switch back on.
        heading("Draw")
        if model.enabled("drawing") {
            tool(model.capture.isDrawingActive ? "Stop Drawing":"Draw on Screen","drawing",shortcut:"drawing")
            tool("Clear Drawing","clearDrawing")
        } else {tool("Turn On Draw on Screen…","enable:drawing")}
        if model.voice.settings.dictationEnabled {
            heading("Dictation")
            if model.voice.state.modelError == true {
                let retry=NSMenuItem(title:"Speech Model Didn’t Download: Try Again",action:#selector(resetSpeech),keyEquivalent:"");retry.target=self;menu.addItem(retry)
            } else if model.voice.state.loading == true {
                let loading=NSMenuItem(title:model.voice.state.status,action:nil,keyEquivalent:"");loading.isEnabled=false;menu.addItem(loading)
            }
            tool(model.voice.state.recording ? "Stop Dictation":"Start Dictation","voice",shortcut:"voice")
            let hint=NSMenuItem(title:"Hold Fn to dictate · double-tap ⇧ to paste the last one",action:nil,keyEquivalent:"");hint.isEnabled=false;menu.addItem(hint)
            let phrase=(model.voice.settings.wakePhrase ?? "").trimmingCharacters(in:.whitespaces)
            let wake=NSMenuItem(title:"Listen for “\(phrase.isEmpty ? "Hey Toolkit":phrase.capitalized)”",action:#selector(toggleWake),keyEquivalent:"")
            wake.target=self;wake.state=model.voice.settings.wakeEnabled ? .on:.off;menu.addItem(wake)
            tool("Customize Hey Toolkit Commands…","page:voice")
        }
        menu.addItem(.separator())
        if model.enabled("screenshots") {tool("Screenshot History…","page:screenshotHistory")}
        if model.voice.settings.dictationEnabled {tool("Dictation History…","page:dictationHistory")}
        if model.enabled("organizer") {tool("Notes…","notes",shortcut:"notes")}
        menu.addItem(.separator())
        add(menu,"Open OpenToolkit",#selector(showAction),"")
        tool("Keyboard Shortcuts…","page:shortcuts")
        add(menu,"Settings…",#selector(settingsAction),",")
        add(menu,"Check for Updates…",#selector(updateAction),"")
        menu.addItem(.separator())
        add(menu,"Quit OpenToolkit",#selector(quit),"q")
    }
    private func modifierMask(_ flags:UInt32)->NSEvent.ModifierFlags{
        var mask:NSEvent.ModifierFlags=[]
        if flags & UInt32(cmdKey) != 0 {mask.insert(.command)};if flags & UInt32(optionKey) != 0 {mask.insert(.option)}
        if flags & UInt32(controlKey) != 0 {mask.insert(.control)};if flags & UInt32(shiftKey) != 0 {mask.insert(.shift)}
        return mask
    }
    /// Menu-bar ⌘, sized like other menu-bar icons (the default symbol size looked small).
    static func menuBarSymbol()->NSImage? {
        // 14 pt regular matches the system's menu-bar icons; 16 pt semibold was clipped at the top and bottom.
        let image=NSImage(systemSymbolName:"command",accessibilityDescription:"OpenToolkit")?.withSymbolConfiguration(.init(pointSize:14,weight:.regular))
        image?.isTemplate=true;return image
    }
    private let pointerGlow=PointerGlow()
    private var badgeShown:Bool?
    /// A small red dot on the menu-bar icon and a Dock badge while an update is waiting (no flashing).
    func showUpdateBadge(_ visible:Bool){
        guard badgeShown != visible else{return};badgeShown=visible
        NSApp.dockTile.badgeLabel=visible ? "1":nil
        guard let symbol=Self.menuBarSymbol() else{return}
        guard visible else{statusItem.button?.image=symbol;return}
        let size=NSSize(width:symbol.size.width+5,height:symbol.size.height+2)
        let image=NSImage(size:size,flipped:false){rect in
            // Drawn on demand, so the symbol follows the menu bar's light or dark appearance.
            let tinted=symbol.copy() as! NSImage;tinted.isTemplate=false
            let glyph=NSRect(x:0,y:1,width:symbol.size.width,height:symbol.size.height)
            tinted.draw(in:glyph);NSColor.labelColor.set();glyph.fill(using:.sourceAtop)
            NSColor.systemRed.setFill();NSBezierPath(ovalIn:NSRect(x:rect.maxX-7,y:rect.maxY-7,width:7,height:7)).fill()
            return true
        }
        image.isTemplate=false;statusItem.button?.image=image
    }
    @objc func toggleWake(){model.voice.setWake(!model.voice.settings.wakeEnabled)}
    func show(){NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)}
    @objc func showAction(){show()}
    @objc func screenshotHistory(){model.capture.showRecentHistory()}
    @objc func updateAction(){model.settingsSection = .update;model.page = .settings;show();model.updates.check()}
    @objc func updateAvailableAction(){model.settingsSection = .update;model.page = .settings;show()}
    @objc func settingsAction(){model.page = .settings;show()}
    @objc func voiceSettingsAction(){model.settingsSection = .dictation;model.page = .settings;show()}
    @objc func toolAction(_ sender:NSMenuItem){
        guard let action=sender.representedObject as? String else{return}
        switch action {
        case "mode:scroll":model.startCaptureMode("scroll")
        case "mode:gif":model.startCaptureMode("gif")
        case "clearDrawing":model.capture.clearAnnotations()
        case "page:screenshotHistory":model.capture.showRecentHistory()
        case "page:dictationHistory":model.historyFilter=nil;model.page = .history;show()
        case "page:voice":model.page = .voice;show()
        case "page:shortcuts":model.settingsSection = .shortcuts;model.page = .settings;show()
        case "enable:drawing":model.toggle("drawing",true);model.page = .drawing;show()
        default:model.perform(action)
        }
    }
    @objc func pauseSpeech(){model.voice.settings.wakeEnabled=false;model.voice.persist();model.voice.command("pause")}
    @objc func resetSpeech(){model.voice.reset()}
    @objc func quit(){NSApp.terminate(nil)}

    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{guard model.capture.prepareToQuit() else{return .terminateCancel};model.voice.command("pause");Task{@MainActor in await model.meetingAudio.finishBeforeQuit();await model.recording.finishBeforeQuit();NSApp.reply(toApplicationShouldTerminate:true)};return .terminateLater}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{
        // Re-activation must not raise the dashboard over an active editor. Floating
        // thumbnails count as visible windows, so check the editors themselves.
        if !model.capture.hasOpenEditor {show()}
        return true
    }
}
@main struct OpenToolkitMain {
    @MainActor static func main(){let app=NSApplication.shared;let delegate=AppDelegate();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}}
}

struct CrosshairColorPicker:View {
    @AppStorage("captureCrosshairColor") private var name="Cyan"
    var body:some View {
        HStack{Text("Capture crosshair colour");Spacer()
            ForEach(CaptureCrosshair.options,id:\.name){option in
                Button{name=option.name}label:{Circle().fill(Color(nsColor:option.color)).frame(width:20,height:20).overlay{Circle().strokeBorder(.white,lineWidth:name==option.name ? 2:0)}.padding(2)}.buttonStyle(.plain).help(option.name)
            }
        }
    }
}

/// The app's ⌘ mark drawn natively at small sizes (a shrunken app icon keeps its margins and looks off).
struct AppMark:View {
    var size:CGFloat
    var body:some View {
        ZStack{
            RoundedRectangle(cornerRadius:size*0.24,style:.continuous).fill(Color(red:0.11,green:0.11,blue:0.118))
            RoundedRectangle(cornerRadius:size*0.24,style:.continuous).strokeBorder(.white.opacity(0.14),lineWidth:1)
            Image(systemName:"command").font(.system(size:size*0.52,weight:.semibold)).foregroundStyle(.white)
        }.frame(width:size,height:size).accessibilityHidden(true)
    }
}
