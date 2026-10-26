import SwiftUI

struct AnnotationSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage("annotationWidth") private var width=4.0
    @AppStorage("annotationTextSize") private var textSize=24.0
    static let defaults=["pen":"ctrl+S","line":"ctrl+Q","arrow":"ctrl+A","rectangle":"ctrl+R","ellipse":"ctrl+E","text":"ctrl+`","eraser":"ctrl+D","undo":"ctrl+U","clear":"ctrl+X","blue":"ctrl+B","pink":"ctrl+P","orange":"ctrl+O","yellow":"ctrl+Y","green":"ctrl+G"]
    var body: some View {
        VStack(spacing:18) {
            ToolCard(title:"Draw on screen",subtitle:"Press \(shortcutLabel(model.keys["drawing"] ?? "D",model.modifiers("drawing"))) to start drawing and again to stop, or hold it to draw only while it’s held. Your marks stay on screen until you clear them. Escape also stops drawing.",accent:.orange) {
                Toggle("Enable screen drawing",isOn:Binding(get:{model.enabled("drawing")},set:{model.toggle("drawing",$0)}))
                HStack {Button("Start drawing"){if !model.capture.isDrawingActive {model.perform("drawing")}};Button("Clear screen"){model.capture.clearAnnotations()}}
                HStack(spacing:18) {
                    HStack(spacing:6){Text("Line");Picker("Line width",selection:$width){ForEach([1.0,2,4,6,8,12,16],id:\.self){Text("\(Int($0)) pt").tag($0)}}.labelsHidden().frame(width:80)}
                    HStack(spacing:6){Text("Text");Picker("Text size",selection:$textSize){ForEach([16.0,20,24,32,36,48,64],id:\.self){Text("\(Int($0)) pt").tag($0)}}.labelsHidden().frame(width:80)}
                    Spacer()
                }
                AnnotationColorRow()
            }
            Text("Tool keys used while drawing are in Settings › Shortcuts.").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}
/// Tool keys while drawing (Settings › Shortcuts).
struct DrawingToolShortcutRows:View {
    @ObservedObject var model:AppModel
    @State private var issue=""
    private let actions=["pen","line","arrow","rectangle","ellipse","text","eraser","undo","clear","blue","pink","orange","yellow","green"]
    var body:some View {
        VStack(alignment:.leading,spacing:6){
            ForEach(actions,id:\.self){name in
                HStack {
                    Text(name.capitalized).frame(width:100,alignment:.leading)
                    Picker("Modifier",selection:Binding(get:{parts(name).0},set:{update(name,$0,parts(name).1)})) {
                        Text("Control ⌃").tag("ctrl");Text("Command ⌘").tag("cmd");Text("Option ⌥").tag("alt")
                    }.labelsHidden().frame(width:150)
                    Picker("Key",selection:Binding(get:{parts(name).1},set:{update(name,parts(name).0,$0)})) {
                        ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ`").map(String.init),id:\.self){Text($0).tag($0)}
                    }.labelsHidden().frame(width:85)
                    if let clash=Self.clash(parts(name)) {Label(clash,systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).help("While you're drawing, this replaces that shortcut in every app.")}
                }
            }
            Text("These keys only work while you're drawing on screen.").font(.caption).foregroundStyle(.secondary)
            Button("Reset drawing keys to the defaults"){for (name,chord) in AnnotationSettings.defaults where actions.contains(name) {model.annotationKeys[name]=chord};UserDefaults.standard.set(model.annotationKeys,forKey:"annotationKeys");model.registerDrawingTools()}
            if !issue.isEmpty {Label(issue,systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)}
        }
    }
    /// Everyday ⌘ shortcuts a drawing key would take over while drawing.
    static let everyday=["A":"Select All","C":"Copy","D":"Duplicate/Bookmark","F":"Find","G":"Find Next","N":"New","O":"Open","P":"Print","Q":"Quit","S":"Save","T":"New Tab","V":"Paste","W":"Close","X":"Cut","Z":"Undo"]
    static func clash(_ chord:(String,String))->String? {chord.0=="cmd" ? everyday[chord.1].map{"Clashes with ⌘\(chord.1) \($0)"}:nil}
    private func parts(_ name:String)->(String,String) {let parts=(model.annotationKeys[name] ?? AnnotationSettings.defaults[name]!).split(separator:"+").map(String.init);return (parts.first ?? "ctrl",parts.last ?? "S")}
    private func update(_ name:String,_ modifier:String,_ key:String) {
        let chord=modifier+"+"+key
        if let other=model.annotationKeys.first(where:{$0.key != name && $0.value==chord})?.key {issue="That key is already the “\(other.capitalized)” drawing key.";return}
        issue="";model.annotationKeys[name]=chord;model.registerHotkeys()
    }
}

/// Default screen-drawing colour; the palette and colour keys update it too.
struct AnnotationColorRow:View {
    @State private var selected=AnnotationColor.saved
    var body:some View {
        HStack(spacing:6){
            Text("Colour").padding(.trailing,6)
            ForEach(AnnotationColor.swatches,id:\.name){swatch in
                Button{AnnotationColor.save(swatch.color);selected=swatch.color}label:{
                    Circle().fill(Color(nsColor:swatch.color)).frame(width:20,height:20)
                        .overlay{Circle().strokeBorder(.white.opacity(swatch.name=="Black" ? 0.5:0),lineWidth:1)}
                        .overlay{Circle().strokeBorder(.white,lineWidth:selected.isClose(to:swatch.color) ? 2:0).padding(-3)}
                }.buttonStyle(.plain).help(swatch.name)
            }
            ColorPicker("Custom colour",selection:Binding(get:{Color(nsColor:selected)},set:{let c=NSColor($0);AnnotationColor.save(c);selected=c}),supportsOpacity:false).labelsHidden().help("Custom colour")
            Spacer()
        }
    }
}
extension NSColor {
    func isClose(to other:NSColor)->Bool {
        guard let a=usingColorSpace(.sRGB),let b=other.usingColorSpace(.sRGB) else{return false}
        return abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent)<0.02
    }
}
