import SwiftUI

struct AnnotationSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage("annotationWidth") private var width=4.0
    @AppStorage("annotationTextSize") private var textSize=24.0
    static let defaults=["pen":"ctrl+S","line":"ctrl+Q","arrow":"ctrl+A","rectangle":"ctrl+R","ellipse":"ctrl+E","text":"ctrl+`","eraser":"ctrl+D","undo":"ctrl+U","clear":"ctrl+X","blue":"ctrl+B","pink":"ctrl+P","orange":"ctrl+O","yellow":"ctrl+Y","green":"ctrl+G"]
    private let actions=["pen","line","arrow","rectangle","ellipse","text","eraser","undo","clear","blue","pink","orange","yellow","green"]
    var body: some View {
        VStack(spacing:18) {
            ToolCard(title:"Hold to draw. Release to keep working.",subtitle:"Hold a tool’s shortcut while you drag. Release the keys to use your apps; your marks stay on screen. Clear erases the marks. Escape also leaves drawing mode.",accent:.orange) {
                Toggle("Enable screen drawing",isOn:Binding(get:{model.enabled("drawing")},set:{model.toggle("drawing",$0)}))
                HStack {Button("Open drawing palette"){model.perform("drawing")};Button("Clear screen"){model.capture.clearAnnotations()}}
                HStack {Text("Line width");Slider(value:$width,in:1...16,step:1);Text("\(Int(width))").monospacedDigit()}
                HStack {Text("Text size");Slider(value:$textSize,in:12...64,step:1);Text("\(Int(textSize))").monospacedDigit()}
            }
            ToolCard(title:"Drawing shortcuts",subtitle:"Tool shortcuts are held; Undo, Clear and colours take one press. Shortcuts apply only while this module is enabled. Quit other drawing apps to avoid conflicts.",accent:.orange) {
                ForEach(actions,id:\.self){name in
                    HStack {
                        Text(name.capitalized).frame(width:100,alignment:.leading)
                        Picker("Modifier",selection:Binding(get:{parts(name).0},set:{update(name,$0,parts(name).1)})) {
                            Text("Control ⌃").tag("ctrl");Text("Command ⌘").tag("cmd");Text("Option ⌥").tag("alt")
                        }.labelsHidden().frame(width:150)
                        Picker("Key",selection:Binding(get:{parts(name).1},set:{update(name,parts(name).0,$0)})) {
                            ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ`").map(String.init),id:\.self){Text($0).tag($0)}
                        }.labelsHidden().frame(width:85)
                    }
                }
            }
        }
    }
    private func parts(_ name:String)->(String,String) {let parts=(model.annotationKeys[name] ?? Self.defaults[name]!).split(separator:"+").map(String.init);return (parts.first ?? "ctrl",parts.last ?? "S")}
    private func update(_ name:String,_ modifier:String,_ key:String) {
        let chord=modifier+"+"+key
        guard !model.annotationKeys.contains(where:{$0.key != name && $0.value==chord}) else{model.notice="That drawing shortcut is already assigned.";return}
        model.annotationKeys[name]=chord;model.registerHotkeys()
    }
}
