import AppKit
import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// CleanShot-style floating glass capture bar (⇧⌘5). Clicking a mode starts it at once.
struct CaptureOptionsView:View {
    @ObservedObject var model:AppModel
    let close:()->Void
    private let modes:[(id:String,title:String,symbol:String)]=[("area","Area","viewfinder"),("full","Full Screen","display"),("scroll","Scrolling","arrow.up.and.down.text.horizontal"),("video","Video","record.circle"),("gif","GIF","photo.stack")]
    var body:some View {
        VStack(spacing:10){
            HStack(spacing:4){
                ForEach(modes,id:\.id){mode in
                    Button{close();model.startCaptureMode(mode.id)}label:{
                        VStack(spacing:5){Image(systemName:mode.symbol).font(.system(size:20,weight:.regular));Text(mode.title).font(.system(size:10,weight:.medium))}
                            .frame(width:68,height:52).contentShape(Rectangle())
                    }.buttonStyle(GlassButtonStyle()).disabled(mode.id != "full" && model.fixedFrame && model.size==nil)
                    .help(mode.id=="area" ? "Select an area (same as ⇧⌘4)":"Start \(mode.title.lowercased()) capture")
                }
                Divider().frame(height:40).padding(.horizontal,6)
                Toggle(isOn:$model.fixedFrame){VStack(spacing:5){Image(systemName:"lock.rectangle").font(.system(size:18));Text("Fixed size").font(.system(size:10,weight:.medium))}.frame(width:64,height:52)}
                    .toggleStyle(GlassToggleStyle()).help("Lock the frame to exact dimensions")
                Toggle(isOn:$model.includeMic){VStack(spacing:5){Image(systemName:model.includeMic ? "mic.fill":"mic.slash").font(.system(size:18));Text("Mic").font(.system(size:10,weight:.medium))}.frame(width:52,height:52)}
                    .toggleStyle(GlassToggleStyle()).help("Include your microphone in video recordings")
                CursorEffectsMenu()
                Divider().frame(height:40).padding(.horizontal,6)
                Button(action:close){Image(systemName:"xmark").font(.system(size:13,weight:.semibold)).frame(width:30,height:30)}.buttonStyle(GlassButtonStyle()).help("Close (Escape)")
            }
            if model.fixedFrame {
                HStack(spacing:8){
                    TextField("Width",text:$model.frameWidth).frame(width:64);Text("×").foregroundStyle(.secondary);TextField("Height",text:$model.frameHeight).frame(width:64);Text("pt").foregroundStyle(.secondary)
                    ForEach([("16:9","1280","720"),("Square","720","720"),("Vertical","720","1280")],id:\.0){preset in Button(preset.0){model.frameWidth=preset.1;model.frameHeight=preset.2}.controlSize(.small)}
                    if model.size==nil {Text("32–16,384").font(.caption).foregroundStyle(.orange)}
                }.textFieldStyle(.roundedBorder).font(.callout)
            }
        }
        .padding(.horizontal,14).padding(.vertical,10)
        .foregroundStyle(.white)
    }
}
private struct GlassButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        configuration.label.background(RoundedRectangle(cornerRadius:10).fill(.white.opacity(configuration.isPressed ? 0.25:0.001)))
            .modifier(GlassHover())
    }
}
private struct GlassToggleStyle:ToggleStyle {
    func makeBody(configuration:Configuration)->some View {
        Button{configuration.isOn.toggle()}label:{configuration.label}.buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius:10).fill(configuration.isOn ? Color.accentColor.opacity(0.55):.white.opacity(0.001)))
            .modifier(GlassHover())
    }
}
private struct GlassHover:ViewModifier {
    @State private var hovering=false
    func body(content:Content)->some View {content.overlay(RoundedRectangle(cornerRadius:10).fill(.white.opacity(hovering ? 0.12:0)).allowsHitTesting(false)).onHover{hovering=$0}}
}
/// Borderless, nonactivating glass panel: the user's app stays active; Escape closes it.
final class CaptureBarPanel:NSPanel {
    var onCancel:(()->Void)?
    init(content:NSView){
        super.init(contentRect:NSRect(x:0,y:0,width:520,height:76),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        isOpaque=false;backgroundColor = .clear;hasShadow=true;level = .floating;isReleasedWhenClosed=false
        collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];isMovableByWindowBackground=true;appearance=NSAppearance(named:.darkAqua)
        let glass=NSVisualEffectView();glass.material = .hudWindow;glass.blendingMode = .behindWindow;glass.state = .active
        glass.wantsLayer=true;glass.layer?.cornerRadius=18;glass.layer?.masksToBounds=true
        content.translatesAutoresizingMaskIntoConstraints=false;glass.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:glass.leadingAnchor),content.trailingAnchor.constraint(equalTo:glass.trailingAnchor),content.topAnchor.constraint(equalTo:glass.topAnchor),content.bottomAnchor.constraint(equalTo:glass.bottomAnchor)])
        contentView=glass
    }
    override var canBecomeKey:Bool {true}
    override func cancelOperation(_ sender:Any?){onCancel?()}
}

enum GIFExport {
    static func convert(_ source:URL)throws->URL {
        let asset=AVURLAsset(url:source)
        let duration=min(30,CMTimeGetSeconds(asset.duration))
        guard duration.isFinite,duration>0 else{throw NSError(domain:"GIF",code:1,userInfo:[NSLocalizedDescriptionKey:"Recording has no video frames."])}
        let output=source.deletingPathExtension().appendingPathExtension("gif")
        let count=max(1,Int(ceil(duration*10)))
        guard let destination=CGImageDestinationCreateWithURL(output as CFURL,UTType.gif.identifier as CFString,count,nil) else{throw CocoaError(.fileWriteUnknown)}
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:960,height:960)
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter=CMTime(seconds:0.1,preferredTimescale:600)
        for i in 0..<count {
            try autoreleasepool {
                let frame=try generator.copyCGImage(at:CMTime(seconds:Double(i)/10,preferredTimescale:600),actualTime:nil)
                CGImageDestinationAddImage(destination,frame,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.1,kCGImagePropertyGIFUnclampedDelayTime:0.1]] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else{throw CocoaError(.fileWriteUnknown)}
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        return output
    }
}
