import AppKit
import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct CaptureOptionsView:View {
    @ObservedObject var model:AppModel
    let close:()->Void
    @State private var mode="area"
    var body:some View {VStack(alignment:.leading,spacing:18){
        HStack{Text("Capture").font(.title2.bold());Spacer();Button("Close",action:close)}
        Picker("Mode",selection:$mode){Text("Screenshot").tag("area");Text("Full screen").tag("full");Text("Scrolling").tag("scroll");Text("Video").tag("video");Text("GIF").tag("gif")}.pickerStyle(.segmented)
        if mode != "full" {Toggle("Lock frame dimensions",isOn:$model.fixedFrame)
            if model.fixedFrame {HStack{TextField("Width",text:$model.frameWidth);Text("×");TextField("Height",text:$model.frameHeight);Text("points")}.textFieldStyle(.roundedBorder)
                HStack{Button("16:9"){model.frameWidth="1280";model.frameHeight="720"};Button("Square"){model.frameWidth="720";model.frameHeight="720"};Button("Vertical"){model.frameWidth="720";model.frameHeight="1280"}}
            }
        }
        if mode=="video" {Toggle("Include microphone",isOn:$model.includeMic)}
        if mode=="gif" {Text("Silent animated GIF · 10 fps · up to 30 seconds · maximum width 960 px").font(.caption).foregroundStyle(.secondary)}
        if mode=="scroll" {Text("Select the scrolling content. Capture the first view, scroll down with some overlap, then Add view. Matching overlap is removed automatically.").font(.callout).foregroundStyle(.secondary)}
        HStack{Text("⌘⇧4 always selects a free-form screenshot.").font(.caption).foregroundStyle(.secondary);Spacer();Button("Start"){close();model.startCaptureMode(mode)}.buttonStyle(.borderedProminent).disabled(mode != "full" && model.fixedFrame && model.size==nil)}
        Text("Change these shortcuts in Settings → Keyboard shortcuts.").font(.caption).foregroundStyle(.secondary)
    }.padding(22).frame(width:600).background(.regularMaterial)}
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
