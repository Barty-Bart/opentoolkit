import AppKit
import SwiftUI
import Carbon

struct ShortcutRecorder:NSViewRepresentable {
    let key:String
    let modifiers:UInt32
    let changed:(String,UInt32)->Void
    func makeNSView(context:Context)->ShortcutButton {let button=ShortcutButton();button.bezelStyle = .rounded;button.target=button;button.action=#selector(ShortcutButton.begin);return button}
    func updateNSView(_ button:ShortcutButton,context:Context){button.changed=changed;button.savedTitle=key.isEmpty ? "Record shortcut":shortcutLabel(key,modifiers);if !button.listening {button.title=button.savedTitle};button.setAccessibilityLabel("Record shortcut, currently \(button.savedTitle)")}
}
func shortcutLabel(_ key:String,_ flags:UInt32)->String {
    var result=""
    if flags & UInt32(controlKey) != 0 {result += "⌃"}
    if flags & UInt32(optionKey) != 0 {result += "⌥"}
    if flags & UInt32(shiftKey) != 0 {result += "⇧"}
    if flags & UInt32(cmdKey) != 0 {result += "⌘"}
    return result+key
}
final class ShortcutButton:NSButton {
    var changed:((String,UInt32)->Void)?
    var listening=false
    var savedTitle="Record shortcut"
    override var acceptsFirstResponder:Bool {true}
    @objc func begin(){listening=true;title="Press shortcut…";window?.makeFirstResponder(self)}
    override func resignFirstResponder()->Bool {listening=false;title=savedTitle;return super.resignFirstResponder()}
    override func performKeyEquivalent(with event:NSEvent)->Bool {if listening {keyDown(with:event);return true};return super.performKeyEquivalent(with:event)}
    override func keyDown(with event:NSEvent){
        guard listening else {super.keyDown(with:event);return}
        if event.keyCode==53 {listening=false;title=savedTitle;return}
        let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command,.option,.control]).isEmpty,let key=Hotkeys.codes.first(where:{$0.value==UInt32(event.keyCode)})?.key else {title="Use ⌘, ⌥ or ⌃ + key";return}
        var value:UInt32=0
        if flags.contains(.command){value |= UInt32(cmdKey)}
        if flags.contains(.option){value |= UInt32(optionKey)}
        if flags.contains(.control){value |= UInt32(controlKey)}
        if flags.contains(.shift){value |= UInt32(shiftKey)}
        listening=false;changed?(key,value);title=savedTitle
    }
}
/// Every OpenToolkit shortcut in one place, grouped by tool.
struct ShortcutsView:View {
    @ObservedObject var model:AppModel
    @State private var showDrawingTools=false
    var body:some View {ToolCard(title:"Shortcuts",subtitle:"Click a shortcut and press the new combination (include ⌘, ⌥ or ⌃). Escape cancels; ✕ removes it. Problems appear under the shortcut."){
        group("Screenshots",module:"screenshots"){row("screenshots");row("fullScreenshot");row("captureOptions")}
        group("Recording",module:"recording"){row("recording")}
        group("Drawing",module:"drawing"){
            row("drawing",detail:"Tap to start or stop drawing; hold to draw only while held.")
            DisclosureGroup(isExpanded:$showDrawingTools){DrawingToolShortcutRows(model:model).padding(.top,6)} label:{Text("Tool keys while drawing").font(.callout)}
        }
        group("Dictation",module:nil){
            fixed("Dictate","Hold to talk; tap to keep listening, tap again to finish.","Fn")
            HStack{VStack(alignment:.leading,spacing:2){Text("Paste last transcript");Text("Double-tap to paste into the text box. Triple-tap opens history.").font(.caption).foregroundStyle(.secondary)};Spacer()
                Picker("Double-tap key",selection:Binding(get:{model.voice.settings.recoveryKey ?? "shift"},set:{model.voice.settings.recoveryKey=$0;model.voice.persist()})){Text("⇧ Shift ×2").tag("shift");Text("⌘ Command ×2").tag("command");Text("⌥ Option ×2").tag("option");Text("Off").tag("off")}.labelsHidden().frame(width:150);clearColumn}
            row("voice");row("recover")
            HStack{VStack(alignment:.leading,spacing:2){Text("Hey Toolkit");Text("Say the wake phrase, wait for the cue, then a command.").font(.caption).foregroundStyle(.secondary)};Spacer();Button("Customize…"){model.settingsSection = .dictation;model.page = .settings}.frame(width:150,alignment:.center);clearColumn}
        }
        group("Notes",module:"organizer"){row("notes");row("reminders")}
    }}
    private func group<Content:View>(_ title:String,module:String?,@ViewBuilder content:()->Content)->some View {
        let off=module.map{!model.enabled($0)} ?? !model.voice.settings.dictationEnabled
        return VStack(alignment:.leading,spacing:10){
            HStack{Text(title.uppercased()).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary);if off {Text("· turned off").font(.caption).foregroundStyle(.secondary)}}
            content()
        }.padding(.vertical,6).opacity(off ? 0.5:1)
    }
    private func fixed(_ title:String,_ detail:String,_ keys:String)->some View {
        HStack{VStack(alignment:.leading,spacing:2){Text(title);Text(detail).font(.caption).foregroundStyle(.secondary)};Spacer()
            Text(keys).font(.system(.body,design:.rounded).weight(.medium)).frame(width:150,height:24).background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:6)).help("Fixed key")
            clearColumn}
    }
    private func row(_ action:String,detail:String?=nil)->some View {
        let key=model.keys[action] ?? ""
        return VStack(alignment:.leading,spacing:4){
            HStack{
                VStack(alignment:.leading,spacing:2){Text(AppModel.shortcutTitles[action] ?? action);if let detail {Text(detail).font(.caption).foregroundStyle(.secondary)}}
                Spacer()
                ShortcutRecorder(key:key,modifiers:model.modifiers(action)){key,flags in model.setShortcut(action,key,flags)}.frame(width:150,height:28)
                Button{model.clearShortcut(action)}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this shortcut").disabled(key.isEmpty).opacity(key.isEmpty ? 0.3:1).frame(width:16)
            }
            if let issue=model.shortcutIssues[action] {Label(issue,systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)}
            if !key.isEmpty,let tool=model.annotationKeys.first(where:{chordFlags($0.value)==model.modifiers(action) && $0.value.hasSuffix("+"+key)})?.key {
                Label("Also the “\(tool.capitalized)” drawing key; while drawing, the drawing key wins.",systemImage:"info.circle").font(.caption).foregroundStyle(.secondary)
            }
            if !key.isEmpty,let name=MacScreenshotShortcuts.enabledConflict(key:key,modifiers:model.modifiers(action)) {
                HStack{Label("macOS still uses this for “\(name)”. Turn that off so OpenToolkit gets it.",systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
                    Button("Open Keyboard Settings"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)}.controlSize(.small)}
            }
        }
    }
    /// Keeps fixed rows aligned with the recorders' ✕ column.
    private var clearColumn:some View {Color.clear.frame(width:16,height:1)}
    private func chordFlags(_ chord:String)->UInt32 {let m=chord.split(separator:"+").first.map(String.init) ?? "ctrl";return m=="cmd" ? UInt32(cmdKey):m=="alt" ? UInt32(optionKey):UInt32(controlKey)}
}
/// Reads (never changes) macOS's own screenshot shortcuts, which default to on.
enum MacScreenshotShortcuts {
    static let symbolic:[(id:String,key:String,flags:UInt32,name:String)]=[
        ("28","3",UInt32(cmdKey|shiftKey),"Save picture of screen"),("29","3",UInt32(cmdKey|shiftKey|controlKey),"Copy picture of screen"),
        ("30","4",UInt32(cmdKey|shiftKey),"Save picture of selected area"),("31","4",UInt32(cmdKey|shiftKey|controlKey),"Copy picture of selected area"),
        ("184","5",UInt32(cmdKey|shiftKey),"Screenshot and recording options")]
    static func enabledConflict(key:String,modifiers:UInt32)->String? {
        guard let match=symbolic.first(where:{$0.key==key && $0.flags==modifiers}) else{return nil}
        let all=CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,"com.apple.symbolichotkeys" as CFString) as? [String:Any]
        let entry=all?[match.id] as? [String:Any]
        let enabled=(entry?["enabled"] as? NSNumber)?.boolValue ?? true
        return enabled ? match.name:nil
    }
}
