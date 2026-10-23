import AppKit
import SwiftUI

@MainActor final class ScrollingCapture:ObservableObject {
    let region:CGRect;let storage:URL
    var onSaved:((URL)->Void)?;var onStatus:((String)->Void)?
    @Published var status="Press Start, then scroll slowly through the content. Press Done when you reach the end."
    @Published var busy=false
    @Published var count=0
    @Published var running=false
    private var panel:NSPanel?
    private var frames:[CGImage]=[]
    private var process:Process?
    private var timer:Timer?
    /// The panel stays visible beside the region; only overlapping layouts hide it per frame.
    private var hidePanelForCapture=false
    init(region:CGRect,storage:URL){self.region=region;self.storage=storage}
    func show(){
        let p=NSPanel(contentRect:NSRect(x:0,y:0,width:470,height:120),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false);p.title="Scrolling capture";p.level = .floating;p.isReleasedWhenClosed=false
        p.contentView=NSHostingView(rootView:ScrollCaptureControls(session:self))
        let visible=(NSScreen.screens.first{$0.frame.intersects(region)} ?? NSScreen.main)?.visibleFrame ?? .zero
        let size=p.frame.size
        if region.minY-visible.minY>=size.height+12 {p.setFrameOrigin(CGPoint(x:max(visible.minX,min(region.midX-size.width/2,visible.maxX-size.width)),y:region.minY-size.height-12))}
        else if visible.maxY-region.maxY>=size.height+12 {p.setFrameOrigin(CGPoint(x:max(visible.minX,min(region.midX-size.width/2,visible.maxX-size.width)),y:region.maxY+12))}
        else {p.center();hidePanelForCapture=true}
        panel=p;p.orderFrontRegardless()
    }
    /// Continuous capture: grab a view about three times a second while the user scrolls.
    func start(){
        guard !running else{return}
        running=true;status="Scroll slowly… capturing as you go."
        add()
        timer=Timer.scheduledTimer(withTimeInterval:0.35,repeats:true){[weak self] _ in Task{@MainActor in guard let self,self.running,!self.busy else{return};self.add()}}
    }
    func add(){guard !busy,count<60 else{if count>=60 {stopTimer();status="Reached 60 views. Press Done."};return};busy=true;if hidePanelForCapture {panel?.orderOut(nil)}
        do{try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}catch{status=error.localizedDescription;busy=false;panel?.orderFrontRegardless();return}
        let path=storage.appendingPathComponent(UUID().uuidString+".png")
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        DispatchQueue.main.asyncAfter(deadline:.now()+(hidePanelForCapture ? 0.25:0.02)){[weak self] in guard let self else{return}
            let p=Process();self.process=p;p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");p.arguments=["-x","-t","png","-R","\(Int(self.region.minX)),\(Int(top-self.region.maxY)),\(Int(self.region.width)),\(Int(self.region.height))",path.path];p.standardError=FileHandle.nullDevice
            p.terminationHandler={_ in DispatchQueue.main.async{[weak self] in guard let self else{return};defer{try? FileManager.default.removeItem(at:path);self.busy=false;self.panel?.orderFrontRegardless()}
                guard let image=NSImage(contentsOf:path)?.cgImage(forProposedRect:nil,context:nil,hints:nil) else{self.status="Capture failed. Check Screen Recording permission.";self.stopTimer();return}
                self.accept(image)
            }}
            do{try p.run()}catch{self.busy=false;self.status=error.localizedDescription;self.panel?.orderFrontRegardless()}
            DispatchQueue.main.asyncAfter(deadline:.now()+20){if p.isRunning{p.terminate()}}
        }
    }
    private func accept(_ image:CGImage){
        guard running,let last=frames.last else{frames.append(image);count=frames.count;if !running {status="\(count) views. Scroll down, then Add view."};return}
        // Unchanged view: the user hasn't scrolled yet. No overlap: scrolled too far between frames.
        if Self.difference(last,image)<1.5 {return}
        guard let match=Self.overlap(last,image),match.score<12 else{status="Too fast — scroll back up a little, then continue more slowly.";return}
        if match.size>=image.height-4 {return}
        frames.append(image);count=frames.count;status="\(count) views captured. Keep scrolling, or press Done."
    }
    private func stopTimer(){timer?.invalidate();timer=nil;running=false}
    func undo(){guard !busy,!frames.isEmpty else{return};frames.removeLast();count=frames.count}
    func finish(){stopTimer();guard !busy,!frames.isEmpty else{return};do{let image=try Self.stitch(frames);let rep=NSBitmapImageRep(cgImage:image);guard let data=rep.representation(using:.png,properties:[:]) else{return};let path=storage.appendingPathComponent("Scrolling-"+UUID().uuidString+".png");try data.write(to:path);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path);onSaved?(path);panel?.close()}catch{status=error.localizedDescription}}
    func cancel(){stopTimer();process?.terminate();panel?.close();panel=nil;frames=[]}
    nonisolated static func gray(_ image:CGImage)->[UInt8]{let height=image.height;var pixels=[UInt8](repeating:0,count:64*height);pixels.withUnsafeMutableBytes{raw in let c=CGContext(data:raw.baseAddress,width:64,height:height,bitsPerComponent:8,bytesPerRow:64,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0)!;c.draw(image,in:CGRect(x:0,y:0,width:64,height:height))};return pixels}
    /// Mean per-pixel change on a 64-column thumbnail; near zero means the view didn't move.
    nonisolated static func difference(_ a:CGImage,_ b:CGImage)->Double {
        guard a.width==b.width,a.height==b.height else{return .infinity}
        let x=gray(a),y=gray(b);var total=0.0;for i in stride(from:0,to:x.count,by:3){total+=abs(Double(x[i])-Double(y[i]))};return total/Double(max(x.count/3,1))
    }
    /// Best vertical overlap between the bottom of `a` and the top of `b` (lower score is better).
    nonisolated static func overlap(_ first:CGImage,_ second:CGImage)->(size:Int,score:Double)? {
        guard first.width==second.width,first.height==second.height else{return nil}
        let height=first.height,a=gray(first),b=gray(second);var best=Double.infinity;var overlap=0
        for size in stride(from:max(16,height/10),through:height-8,by:2){var error=0.0;var count=0
            for y in stride(from:0,to:size,by:max(1,size/40)){for x in stride(from:4,to:60,by:2){error+=abs(Double(a[(height-size+y)*64+x])-Double(b[y*64+x]));count+=1}}
            let score=error/Double(max(count,1));if score<best{best=score;overlap=size}
        }
        return (overlap,best)
    }
    static func stitch(_ frames:[CGImage])throws->CGImage {
        guard let first=frames.first,frames.allSatisfy({$0.width==first.width && $0.height==first.height}) else{throw LibraryFailure(message:"Capture sizes must match.")}
        let width=first.width,height=first.height
        var cuts=[0]
        for n in 1..<frames.count {
            guard let match=overlap(frames[n-1],frames[n]),match.score<12 else{throw LibraryFailure(message:"No reliable overlap found. Undo the last view and capture with more overlap, excluding fixed headers.")};cuts.append(match.size)
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
    var body:some View {VStack(alignment:.leading,spacing:12){
        Text(session.status).font(.callout).fixedSize(horizontal:false,vertical:true)
        HStack{
            if session.running {Button("Done"){session.finish()}.buttonStyle(.borderedProminent).disabled(session.count==0)}
            else {Button("Start"){session.start()}.buttonStyle(.borderedProminent).disabled(session.busy)
                Button("Add one view"){session.add()}.disabled(session.busy)
                Button("Finish"){session.finish()}.disabled(session.busy || session.count==0)}
            Button("Undo last"){session.undo()}.disabled(session.busy || session.count==0)
            Spacer()
            Button("Cancel"){session.cancel()}
        }
    }.padding(16).frame(width:470)}
}
