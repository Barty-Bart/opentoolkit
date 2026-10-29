import AppKit
import SwiftUI

@MainActor final class ScrollingCapture:ObservableObject {
    let region:CGRect;let storage:URL
    var onSaved:((URL)->Void)?;var onStatus:((String)->Void)?
    @Published var status="Auto-scroll scrolls and captures by itself; press Stop or Escape whenever you like. Or press Start and scroll yourself."
    @Published var busy=false
    @Published var count=0
    @Published var running=false
    @Published var automatic=false
    private var panel:NSPanel?
    private var frames:[CGImage]=[]
    private var shifts:[Int]=[]
    private var process:Process?
    private var timer:Timer?
    private var escape:Any?
    private var still=0
    /// The panel stays visible beside the region; only overlapping layouts hide it per frame.
    private var hidePanelForCapture=false
    private enum Outcome {case added,unchanged,lost}
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
        escape=NSEvent.addGlobalMonitorForEvents(matching:.keyDown){[weak self] event in guard event.keyCode==53 else{return};Task{@MainActor in guard let self,self.running else{return};self.finish()}}
    }
    /// Continuous capture: grab a view about three times a second while the user scrolls.
    func start(){
        guard !running else{return}
        running=true;status="Scroll slowly… capturing as you go."
        add()
        timer=Timer.scheduledTimer(withTimeInterval:0.35,repeats:true){[weak self] _ in Task{@MainActor in guard let self,self.running,!self.automatic,!self.busy else{return};self.add()}}
    }
    /// Scrolls the area under the pointer by itself and captures each step until Stop, Escape or the end of the page.
    func startAutomatic(){
        guard !running else{return}
        guard CGPreflightPostEventAccess() else{_=CGRequestPostEventAccess();status="Auto-scroll needs Accessibility permission for OpenToolkit. Allow it in System Settings, then try again.";return}
        running=true;automatic=true;still=0;status="Scrolling… press Stop or Escape to finish."
        let point=scrollPoint;CGWarpMouseCursorPosition(globalPoint(point));CGAssociateMouseAndMouseCursorPosition(1)
        add{[weak self] _ in self?.scheduleStep()}
    }
    /// Inside the area and clear of the panel, so the scroll reaches the captured app.
    private var scrollPoint:CGPoint {
        let centre=CGPoint(x:region.midX,y:region.midY)
        if let frame=panel?.frame,frame.contains(centre) {return CGPoint(x:region.midX,y:min(region.maxY-20,frame.maxY+40))}
        return centre
    }
    private func globalPoint(_ point:CGPoint)->CGPoint {CGPoint(x:point.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-point.y)}
    private func scheduleStep(){DispatchQueue.main.asyncAfter(deadline:.now()+0.05){[weak self] in self?.step()}}
    private func step(){
        guard running,automatic else{return}
        let pointer=NSEvent.mouseLocation
        // Moving the pointer away (for example to Stop) pauses scrolling instead of scrolling something else.
        if !region.contains(pointer) || panel?.frame.contains(pointer)==true {status="Paused. Move the pointer back over the area to continue, or press Stop.";DispatchQueue.main.asyncAfter(deadline:.now()+0.3){[weak self] in self?.step()};return}
        status="Scrolling… \(count) views. Press Stop or Escape to finish."
        let amount=Int32(max(40,region.height*0.45))
        if let event=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-amount,wheel2:0,wheel3:0){event.setIntegerValueField(.scrollWheelEventIsContinuous,value:1);event.location=globalPoint(pointer);event.post(tap:.cghidEventTap)}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4){[weak self] in guard let self,self.running,self.automatic else{return}
            self.add{[weak self] outcome in guard let self,self.running,self.automatic else{return}
                switch outcome {
                case .added:self.still=0;self.scheduleStep()
                case .unchanged:self.still+=1;if self.still>=2 {self.status="Reached the end.";self.finish()} else {self.scheduleStep()}
                case .lost:
                    // Too far to match: scroll back a little and try again.
                    if let back=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:amount/2,wheel2:0,wheel3:0){back.setIntegerValueField(.scrollWheelEventIsContinuous,value:1);back.location=self.globalPoint(self.scrollPoint);back.post(tap:.cghidEventTap)}
                    self.still+=1;if self.still>=4 {self.status="Couldn't follow the page here. Press Stop to keep what was captured.";self.automatic=false} else {DispatchQueue.main.asyncAfter(deadline:.now()+0.4){[weak self] in self?.add{_ in self?.scheduleStep()}}}
                }
            }
        }
    }
    func add(){add(then:nil)}
    private func add(then:((Outcome)->Void)?){guard !busy,count<80 else{if count>=80 {status="Reached 80 views. Press Done.";if running {finish()}};return};busy=true;if hidePanelForCapture {panel?.orderOut(nil)}
        do{try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}catch{status=error.localizedDescription;busy=false;panel?.orderFrontRegardless();return}
        let path=storage.appendingPathComponent(UUID().uuidString+".png")
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        DispatchQueue.main.asyncAfter(deadline:.now()+(hidePanelForCapture ? 0.25:0.02)){[weak self] in guard let self else{return}
            let p=Process();self.process=p;p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");p.arguments=["-x","-t","png","-R","\(Int(self.region.minX)),\(Int(top-self.region.maxY)),\(Int(self.region.width)),\(Int(self.region.height))",path.path];p.standardError=FileHandle.nullDevice
            p.terminationHandler={_ in DispatchQueue.main.async{[weak self] in guard let self else{return};defer{try? FileManager.default.removeItem(at:path);self.busy=false;if self.panel != nil {self.panel?.orderFrontRegardless()}}
                guard let image=NSImage(contentsOf:path)?.cgImage(forProposedRect:nil,context:nil,hints:nil) else{self.status="Capture failed. Check Screen Recording permission.";self.stopTimer();return}
                let outcome=self.accept(image);DispatchQueue.main.async{then?(outcome)}
            }}
            do{try p.run()}catch{self.busy=false;self.status=error.localizedDescription;self.panel?.orderFrontRegardless()}
            DispatchQueue.main.asyncAfter(deadline:.now()+20){if p.isRunning{p.terminate()}}
        }
    }
    private func accept(_ image:CGImage)->Outcome{
        guard let last=frames.last else{frames=[image];shifts=[0];count=1;return .added}
        guard let match=Self.match(last,image) else{return .lost}
        // Unchanged view: nothing scrolled yet, or the end of the page.
        if match.rows==0 || match.top>=image.height {return .unchanged}
        guard match.score<Self.reliable else{if !automatic {status="Too fast — scroll back up a little, then continue more slowly."};return .lost}
        frames.append(image);shifts.append(match.rows);count=frames.count;if !automatic {status="\(count) views captured. Keep scrolling, or press Done."};return .added
    }
    private func stopTimer(){timer?.invalidate();timer=nil;running=false;automatic=false}
    func undo(){guard !busy,!frames.isEmpty else{return};frames.removeLast();shifts.removeLast();count=frames.count}
    func finish(){
        stopTimer();guard !frames.isEmpty else{return}
        // A capture may still be in flight; finish once it lands.
        if busy {DispatchQueue.main.asyncAfter(deadline:.now()+0.1){[weak self] in self?.finish()};return}
        do{let image=try Self.stitch(frames,shifts:shifts);let rep=NSBitmapImageRep(cgImage:image);guard let data=rep.representation(using:.png,properties:[:]) else{return};let path=storage.appendingPathComponent("Scrolling-"+UUID().uuidString+".png");try data.write(to:path);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path);onSaved?(path);close()}catch{status=error.localizedDescription}
    }
    func cancel(){stopTimer();process?.terminate();frames=[];shifts=[];close()}
    private func close(){if let escape {NSEvent.removeMonitor(escape)};escape=nil;panel?.close();panel=nil}
    /// Grayscale copy `columns` wide and full height, for comparing views row by row.
    nonisolated static func gray(_ image:CGImage,columns:Int=128)->[UInt8]{let height=image.height;var pixels=[UInt8](repeating:0,count:columns*height);pixels.withUnsafeMutableBytes{raw in let c=CGContext(data:raw.baseAddress,width:columns,height:height,bitsPerComponent:8,bytesPerRow:columns,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0)!;c.interpolationQuality = .medium;c.draw(image,in:CGRect(x:0,y:0,width:columns,height:height))};return pixels}
    /// Mean change between row `ra` of `a` and row `rb` of `b`; rows count from the top.
    nonisolated static func rowDifference(_ a:[UInt8],_ ra:Int,_ b:[UInt8],_ rb:Int,columns:Int=128)->Double {
        var total=0;let x=ra*columns,y=rb*columns;for i in 0..<columns{total+=abs(Int(a[x+i])-Int(b[y+i]))};return Double(total)/Double(columns)
    }
    /// Mean per-pixel change; near zero means the view didn't move.
    nonisolated static func difference(_ a:CGImage,_ b:CGImage)->Double {
        guard a.width==b.width,a.height==b.height else{return .infinity}
        let x=gray(a),y=gray(b);var total=0;for i in 0..<x.count{total+=abs(Int(x[i])-Int(y[i]))};return Double(total)/Double(max(x.count,1))
    }
    /// Rows at the top and bottom that stay put between two views: toolbars, sticky headers, chat boxes.
    nonisolated static func fixedBands(_ a:[UInt8],_ b:[UInt8],height:Int)->(top:Int,bottom:Int){
        var top=0;while top<height && rowDifference(a,top,b,top)<2.5 {top+=1}
        if top==height {return (height,0)}
        var bottom=0;while bottom<height-top && rowDifference(a,height-1-bottom,b,height-1-bottom)<2.5 {bottom+=1}
        return (top,bottom)
    }
    /// How many rows the content between the fixed bands moved up from `a` to `b` (lower score is better).
    nonisolated static func shift(_ a:[UInt8],_ b:[UInt8],height:Int,top:Int,bottom:Int)->(rows:Int,score:Double)? {
        let band=height-top-bottom,least=max(16,band/8);guard band-least>=1 else{return nil}
        var coarse:[(rows:Int,score:Double)]=[]
        for d in 1...(band-least){let n=band-d,step=max(1,n/160);var total=0.0,count=0
            for y in stride(from:0,to:n,by:step){total+=rowDifference(a,top+d+y,b,top+y);count+=1}
            coarse.append((d,total/Double(count)))}
        var best:(rows:Int,score:Double)?
        for candidate in coarse.sorted(by:{$0.score<$1.score}).prefix(12){let n=band-candidate.rows
            // Ignore the worst rows so a translucent header or a hover highlight can't hide a true match.
            let errors=(0..<n).map{rowDifference(a,top+candidate.rows+$0,b,top+$0)}.sorted();let kept=errors.prefix(max(1,n*85/100))
            let score=kept.reduce(0,+)/Double(kept.count);if score<(best?.score ?? .infinity){best=(candidate.rows,score)}}
        return best
    }
    /// One view's fit against the view before it.
    nonisolated static func match(_ first:CGImage,_ second:CGImage)->(rows:Int,score:Double,top:Int,bottom:Int)? {
        guard first.width==second.width,first.height==second.height else{return nil}
        let a=gray(first),b=gray(second),bands=fixedBands(a,b,height:first.height)
        if bands.top>=first.height {return (0,0,first.height,0)}
        guard let moved=shift(a,b,height:first.height,top:bands.top,bottom:bands.bottom) else{return nil}
        return (moved.rows,moved.score,bands.top,bands.bottom)
    }
    nonisolated static let reliable=4.0
    /// Joins views: fixed bars once, then each view's newly revealed rows. `shifts[n]` is how far view n moved from view n-1.
    nonisolated static func stitch(_ frames:[CGImage],shifts given:[Int]?=nil)throws->CGImage {
        guard let first=frames.first,frames.allSatisfy({$0.width==first.width && $0.height==first.height}) else{throw LibraryFailure(message:"Capture sizes must match.")}
        let width=first.width,height=first.height
        var shifts=[0],top=height,bottom=height
        for n in 1..<max(frames.count,1) {
            let a=gray(frames[n-1]),b=gray(frames[n]),bands=fixedBands(a,b,height:height);top=min(top,bands.top);bottom=min(bottom,bands.bottom)
            if let given,given.count==frames.count {shifts.append(given[n]);continue}
            guard let moved=shift(a,b,height:height,top:bands.top,bottom:bands.bottom),moved.score<reliable else{throw LibraryFailure(message:"No reliable overlap found. Undo the last view and capture with more overlap.")};shifts.append(moved.rows)
        }
        if frames.count==1 {top=0;bottom=0}
        if top+bottom>=height {top=0;bottom=0}
        let total=height+shifts.reduce(0,+)
        guard total*width<120_000_000,let c=CGContext(data:nil,width:width,height:total,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw LibraryFailure(message:"Capture is too large. Finish a shorter section.")}
        var y=total
        func place(_ image:CGImage,from:Int,rows:Int){guard rows>0,let part=image.cropping(to:CGRect(x:0,y:from,width:width,height:rows)) else{return};y-=rows;c.draw(part,in:CGRect(x:0,y:y,width:width,height:rows))}
        place(first,from:0,rows:height-bottom)
        for n in 1..<max(frames.count,1) {place(frames[n],from:height-bottom-shifts[n],rows:shifts[n])}
        place(frames[frames.count-1],from:height-bottom,rows:bottom)
        guard let result=c.makeImage() else{throw LibraryFailure(message:"Could not assemble the capture.")};return result
    }
}
struct ScrollCaptureControls:View {
    @ObservedObject var session:ScrollingCapture
    var body:some View {VStack(alignment:.leading,spacing:12){
        Text(session.status).font(.callout).fixedSize(horizontal:false,vertical:true)
        HStack{
            if session.running {Button(session.automatic ? "Stop":"Done"){session.finish()}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(session.count==0)
                Button("Undo last"){session.undo()}.disabled(session.busy || session.count<2)}
            else if session.count>0 {Button("Save"){session.finish()}.buttonStyle(.borderedProminent).disabled(session.busy)
                Button("Undo last"){session.undo()}.disabled(session.busy)}
            else {Button("Auto-scroll"){session.startAutomatic()}.buttonStyle(.borderedProminent).disabled(session.busy)
                Button("Scroll myself"){session.start()}.disabled(session.busy)}
            Spacer()
            Button("Cancel"){session.cancel()}
        }
    }.padding(16).frame(width:470)}
}
