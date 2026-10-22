import AppKit
import SwiftUI
import Carbon

struct ShortcutRecorder:NSViewRepresentable {
    let key:String
    let modifiers:UInt32
    let changed:(String,UInt32)->Void
    func makeNSView(context:Context)->ShortcutButton {let button=ShortcutButton();button.bezelStyle = .rounded;button.target=button;button.action=#selector(ShortcutButton.begin);return button}
    func updateNSView(_ button:ShortcutButton,context:Context){button.changed=changed;button.savedTitle=shortcutLabel(key,modifiers);if !button.listening {button.title=button.savedTitle};button.setAccessibilityLabel("Record shortcut, currently \(button.savedTitle)")}
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
struct ShortcutSettings:View {
    @ObservedObject var model:AppModel
    var body:some View {ToolCard(title:"Keyboard shortcuts",subtitle:"Click a shortcut, then press your preferred combination. Escape cancels. Include Command, Option or Control. For ⌘⇧3/4/5, disable matching shortcuts in macOS Keyboard → Keyboard Shortcuts → Screenshots and in other capture apps."){
        ForEach(["screenshots","fullScreenshot","captureOptions","drawing","recording","notes","reminders","voice","recover"],id:\.self){action in
            HStack{Text(["screenshots":"Capture area","fullScreenshot":"Capture full screen","captureOptions":"Screenshot & recording options"][action] ?? action.capitalized);Spacer();ShortcutRecorder(key:model.keys[action] ?? "S",modifiers:model.modifiers(action)){key,flags in model.setShortcut(action,key,flags)}.frame(width:180,height:28)}.padding(.vertical,6)
            if action != "recover" {Divider().opacity(0.35)}
        }
    }}
}
