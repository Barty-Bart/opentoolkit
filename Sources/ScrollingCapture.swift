import AppKit
import SwiftUI

@MainActor final class ScrollingCapture:ObservableObject {
    let region:CGRect;let storage:URL
    var onSaved:((URL)->Void)?;var onStatus:((String)->Void)?
    @Published var status="Capture the first view, scroll down with overlap, then add another."
    @Published var busy=false
    @Published var count=0
    private var panel:NSPanel?
    private var frames:[CGImage]=[]
    private var process:Process?
    init(region:CGRect,storage:URL){self.region=region;self.storage=storage}
    func show(){
        let p=NSPanel(contentRect:NSRect(x:0,y:0,width:480,height:140),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false);p.title="Scrolling capture";p.level = .floating;p.isReleasedWhenClosed=false
        p.contentView=NSHostingView(rootView:ScrollCaptureControls(session:self));p.center();panel=p;p.orderFrontRegardless()
    }
    func add(){guard !busy,count<20 else{return};busy=true;panel?.orderOut(nil)
        do{try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}catch{status=error.localizedDescription;busy=false;panel?.orderFrontRegardless();return}
        let path=storage.appendingPathComponent(UUID().uuidString+".png")
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25){[weak self] in guard let self else{return}
            let p=Process();self.process=p;p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");p.arguments=["-x","-t","png","-R","\(Int(self.region.minX)),\(Int(top-self.region.maxY)),\(Int(self.region.width)),\(Int(self.region.height))",path.path];p.standardError=FileHandle.nullDevice
            p.terminationHandler={_ in DispatchQueue.main.async{[weak self] in guard let self else{return};defer{try? FileManager.default.removeItem(at:path);self.busy=false;self.panel?.orderFrontRegardless()}
                guard let image=NSImage(contentsOf:path)?.cgImage(forProposedRect:nil,context:nil,hints:nil) else{self.status="Capture failed. Check Screen Recording permission.";return}
                self.frames.append(image);self.count=self.frames.count;self.status="\(self.count) views. Scroll down, then Add view."
            }}
            do{try p.run()}catch{self.busy=false;self.status=error.localizedDescription;self.panel?.orderFrontRegardless()}
            DispatchQueue.main.asyncAfter(deadline:.now()+20){if p.isRunning{p.terminate()}}
        }
    }
    func undo(){guard !busy,!frames.isEmpty else{return};frames.removeLast();count=frames.count}
    func finish(){guard !busy,!frames.isEmpty else{return};do{let image=try Self.stitch(frames);let rep=NSBitmapImageRep(cgImage:image);guard let data=rep.representation(using:.png,properties:[:]) else{return};let path=storage.appendingPathComponent("Scrolling-"+UUID().uuidString+".png");try data.write(to:path);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path);onSaved?(path);panel?.close()}catch{status=error.localizedDescription}}
    func cancel(){process?.terminate();panel?.close();panel=nil;frames=[]}
    static func stitch(_ frames:[CGImage])throws->CGImage {
        guard let first=frames.first,frames.allSatisfy({$0.width==first.width && $0.height==first.height}) else{throw LibraryFailure(message:"Capture sizes must match.")}
        let width=first.width,height=first.height
        func gray(_ image:CGImage)->[UInt8]{var pixels=[UInt8](repeating:0,count:64*height);pixels.withUnsafeMutableBytes{raw in let c=CGContext(data:raw.baseAddress,width:64,height:height,bitsPerComponent:8,bytesPerRow:64,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0)!;c.draw(image,in:CGRect(x:0,y:0,width:64,height:height))};return pixels}
        var cuts=[0]
        for n in 1..<frames.count {let a=gray(frames[n-1]),b=gray(frames[n]);var best=Double.infinity;var overlap=0
            for size in stride(from:max(16,height/10),through:height-8,by:2){var error=0.0;var count=0
                for y in stride(from:0,to:size,by:max(1,size/40)){for x in stride(from:4,to:60,by:2){error+=abs(Double(a[(height-size+y)*64+x])-Double(b[y*64+x]));count+=1}}
                let score=error/Double(max(count,1));if score<best{best=score;overlap=size}
            }
            guard best<12 else{throw LibraryFailure(message:"No reliable overlap found. Undo the last view and capture with more overlap, excluding fixed headers.")};cuts.append(overlap)
        }
        let total=height*frames.count-cuts.reduce(0,+)
        guard total*width<80_000_000,let c=CGContext(data:nil,width:width,height:total,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw LibraryFailure(message:"Capture is too large. Finish a shorter section.")}
        var top=total
        for (n,image) in frames.enumerated(){let h=height-cuts[n];guard let cropped=image.cropping(to:CGRect(x:0,y:cuts[n],width:width,height:h)) else{continue};top-=h;c.draw(cropped,in:CGRect(x:0,y:top,width:width,height:h))}
        guard let result=c.makeImage() else{throw LibraryFailure(message:"Could not assemble the capture.")};return result
    }
}
struct ScrollCaptureControls:View {
    @ObservedObject var session:ScrollingCapture
    var body:some View {VStack(alignment:.leading,spacing:12){Text(session.status).font(.caption);HStack{Button("Add view"){session.add()}.disabled(session.busy);Button("Undo last"){session.undo()}.disabled(session.busy || session.count==0);Button("Finish"){session.finish()}.disabled(session.busy || session.count==0);Button("Cancel"){session.cancel()}}}.padding(18).frame(width:440)}
}
