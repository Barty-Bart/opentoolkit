import AppKit

/// Standalone editor verification; no speech worker, user database, or capture permissions.
@main @MainActor struct CaptureEditorTests {
    static var editor: CaptureEditorController?
    static func fixture(_ width:Int = 160,_ height:Int = 120,_ accent:NSColor = .systemBlue) -> NSImage {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        NSColor.white.setFill();NSRect(x:0,y:0,width:width,height:height).fill()
        accent.setFill();NSRect(x:0,y:0,width:width/2,height:height/2).fill()
        context.flushGraphics();NSGraphicsContext.restoreGraphicsState()
        return NSImage(data:bitmap.representation(using:.png,properties:[:])!)!
    }
    /// A synthetic document screenshot with three lines of large text for the smart highlighter.
    static func textFixture(_ size:NSSize = NSSize(width:900,height:360)) -> NSImage {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width),pixelsHigh:Int(size.height),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        NSColor.white.setFill();NSRect(origin:.zero,size:size).fill()
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:36,weight:.medium),.foregroundColor:NSColor.black]
        for (n,line) in ["Quarterly report draft","Highlight this whole line","Third line of sample text"].enumerated() {
            (line as NSString).draw(at:NSPoint(x:40,y:size.height-90-CGFloat(n)*90),withAttributes:attrs)
        }
        context.flushGraphics();NSGraphicsContext.restoreGraphicsState()
        return NSImage(data:bitmap.representation(using:.png,properties:[:])!)!
    }
    static func main() throws {
        _ = NSApplication.shared
        #if EDITOR_PREVIEW
        try preview()
        #else
        if CommandLine.arguments.contains("--preview") { try preview();return }
        if let index=CommandLine.arguments.firstIndex(of:"--snapshots"),CommandLine.arguments.count>index+1 { try snapshots(URL(fileURLWithPath:CommandLine.arguments[index+1]));return }
        try verify()
        #endif
    }
    static func color(_ bitmap:NSBitmapImageRep,_ x:Int,_ y:Int) -> NSColor { bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)! }
    static func verify() throws {
        var count=0
        func check(_ value:Bool,_ message:String){precondition(value,message);count+=1}
        let surface=DrawingSurface(frame:NSRect(x:0,y:0,width:640,height:480),image:fixture())
        func pixels() throws -> NSBitmapImageRep { NSBitmapImageRep(data:try surface.renderedPNG())! }
        let original=try surface.renderedPNG()
        for zoom:CGFloat in [0.25,1,2] {
            surface.zoomScale=zoom
            let bitmap=try pixels();check(bitmap.pixelsWide==160 && bitmap.pixelsHigh==120,"Zoom must not resample export")
        }
        surface.zoomScale=nil
        // A Retina capture (2 px per point) must keep its point size after export.
        let retinaSource=fixture(320,240);retinaSource.size=NSSize(width:160,height:120)
        let retina=NSBitmapImageRep(data:try DrawingSurface(frame:NSRect(x:0,y:0,width:640,height:480),image:retinaSource).renderedPNG())!
        check(retina.pixelsWide==320 && retina.size==NSSize(width:160,height:120),"Retina export keeps pixels and point size")
        surface.addAnnotation(DrawingMark(tool:.redact,points:[CGPoint(x:40,y:30),CGPoint(x:120,y:90)],color:.red,width:4))
        let redacted=color(try pixels(),80,60)
        check(redacted.redComponent<0.01 && redacted.greenComponent<0.01 && redacted.blueComponent<0.01 && redacted.alphaComponent>0.99,"Redaction must be opaque black in exported pixels")
        surface.undo();check(try surface.renderedPNG()==original,"Undo restores original pixels")
        surface.redo();check(try surface.renderedPNG() != original,"Redo restores annotation")
        surface.crop(to:CGRect(x:20,y:20,width:80,height:60))
        let cropped=try pixels();check(cropped.pixelsWide==80 && cropped.pixelsHigh==60,"Crop dimensions are correct")
        surface.undo();check(try pixels().pixelsWide==160,"Crop undo restores full image")
        surface.clear();check(try surface.renderedPNG()==original,"Clear removes annotations")
        surface.addAnnotation(DrawingMark(tool:.highlighter,points:[CGPoint(x:10,y:85),CGPoint(x:150,y:85)],color:.yellow,width:20))
        let highlighted=color(try pixels(),80,35)
        check(highlighted.redComponent>0.9 && highlighted.blueComponent<0.9 && highlighted.blueComponent>0.4,"Highlight preserves content with translucency")
        surface.undo()
        check(surface.combine([fixture(40,30)]),"Vertical combination succeeds")
        let vertical=try pixels();check(vertical.pixelsWide==160 && vertical.pixelsHigh==166,"Vertical combination keeps pixels and gap")
        surface.undo();surface.combineHorizontal=true
        check(surface.combine([fixture(40,30)]),"Horizontal combination succeeds")
        let horizontal=try pixels();check(horizontal.pixelsWide==216 && horizontal.pixelsHigh==120,"Horizontal combination keeps pixels and gap")
        surface.undo()
        surface.addAnnotation(DrawingMark(tool:.filledRectangle,points:[CGPoint(x:40,y:30),CGPoint(x:120,y:90)],color:.red,width:4))
        let filled=color(try pixels(),80,60)
        check(filled.redComponent>0.9 && filled.blueComponent<0.1,"Filled shape exports with its selected color")
        surface.flattenSavedImage(NSImage(data:try surface.renderedPNG())!)
        check(!surface.hasChanges,"Saving resets dirty state")
        count+=try verifyCanvas()
        count+=try verifyLayers()
        count+=verifyTextSnap()
        count+=verifyZoom()
        print("Screenshot editor: \(count) checks passed")
    }

    /// The canvas fits the capture, can grow or shrink independently, and fills new room with the edge colour.
    static func verifyCanvas() throws -> Int {
        var count=0
        func check(_ value:Bool,_ message:String){precondition(value,message);count+=1}
        let surface=DrawingSurface(frame:NSRect(x:0,y:0,width:640,height:480),image:fixture())
        check(surface.canvas==CGRect(x:0,y:0,width:160,height:120),"Canvas starts at the image size")
        check(CanvasGeometry.fitScale(canvas:CGSize(width:2000,height:1000),viewport:CGSize(width:1112,height:612))==0.5,"Fit leaves working room around a large canvas")
        check(CanvasGeometry.fitScale(canvas:CGSize(width:160,height:120),viewport:CGSize(width:1000,height:700))==1,"Fit never enlarges a small capture")
        surface.zoomScale=1
        check(surface.documentViewSize(viewport:CGSize(width:300,height:200))==CGSize(width:300,height:232),"Scroll area includes the working margin when needed")
        surface.zoomScale=nil
        surface.padCanvas(40)
        var bitmap=NSBitmapImageRep(data:try surface.renderedPNG())!
        check(bitmap.pixelsWide==240 && bitmap.pixelsHigh==200,"Growing the canvas adds room to the export")
        let corner=color(bitmap,2,2)
        check(corner.alphaComponent>0.99 && corner.redComponent>0.99 && corner.blueComponent>0.99,"New room matches the white edge of the capture")
        check(color(bitmap,60,150).blueComponent>0.9 && color(bitmap,60,150).redComponent<0.3,"The capture keeps its place inside the grown canvas")
        surface.canvasBackground = .clear
        bitmap=NSBitmapImageRep(data:try surface.renderedPNG())!
        check(color(bitmap,2,2).alphaComponent<0.01,"Transparent background leaves the room clear")
        surface.canvasBackground = .auto
        surface.setCanvas(CGRect(x:0,y:0,width:80,height:60))
        bitmap=NSBitmapImageRep(data:try surface.renderedPNG())!
        check(bitmap.pixelsWide==80 && bitmap.pixelsHigh==60,"Shrinking the canvas trims the export")
        check(color(bitmap,10,50).blueComponent>0.9,"A shrunk canvas keeps the bottom-left of the capture")
        check(surface.layers[0].frame.size==CGSize(width:160,height:120),"Shrinking the canvas never crops the image itself")
        surface.undo();check(surface.canvas.width==240,"Undo restores the canvas size")
        // A crop on a padded lone capture keeps the room around it.
        surface.crop(to:CGRect(x:20,y:20,width:80,height:60))
        check(surface.canvas==CGRect(x:-20,y:-20,width:160,height:140),"Cropping the image keeps the canvas room")
        surface.undo()
        surface.fitCanvasToImages();check(surface.canvas==CGRect(x:0,y:0,width:160,height:120),"Fit canvas to images removes the room")
        let resized=CanvasGeometry.resize(CGRect(x:0,y:0,width:100,height:100),h:1,v:0,to:CGPoint(x:163,y:40),snapTo:[CGRect(x:0,y:0,width:160,height:50)],tolerance:6)
        check(resized==CGRect(x:0,y:0,width:160,height:100),"Dragged canvas edge snaps to a nearby image edge")
        let tiny=CanvasGeometry.resize(CGRect(x:0,y:0,width:100,height:100),h:-1,v:-1,to:CGPoint(x:400,y:400),snapTo:[],tolerance:6)
        check(tiny.width==CanvasGeometry.minimumSide && tiny.height==CanvasGeometry.minimumSide,"The canvas cannot be dragged inside out")
        return count
    }

    /// Added images stay separate layers that can be moved, reordered and removed.
    static func verifyLayers() throws -> Int {
        var count=0
        func check(_ value:Bool,_ message:String){precondition(value,message);count+=1}
        let surface=DrawingSurface(frame:NSRect(x:0,y:0,width:640,height:480),image:fixture())
        surface.addAnnotation(DrawingMark(tool:.arrow,points:[CGPoint(x:10,y:10),CGPoint(x:60,y:60)],color:.red,width:4))
        check(surface.combine([fixture(40,30,.systemGreen)]),"Adding an image succeeds")
        check(surface.layers.count==2 && surface.marks.count==1,"Added image is a layer and annotations survive")
        check(surface.layers[1].frame==CGRect(x:0,y:-46,width:40,height:30),"New layer is placed below the capture")
        check(surface.selectedLayer==1 && surface.tool == .select,"The new image is selected, ready to drag")
        surface.moveLayer(1,by:100,96)
        check(surface.layers[1].frame.origin==CGPoint(x:100,y:50),"Layer moves freely")
        check(surface.canvas==CGRect(x:0,y:-46,width:160,height:166),"Moving inside the canvas keeps its size")
        var bitmap=NSBitmapImageRep(data:try surface.renderedPNG())!
        let moved=color(bitmap,105,64)
        check(moved.greenComponent>0.6 && moved.redComponent<0.5,"Moved layer renders at its new place over the capture")
        surface.moveLayer(1,by:60,0)
        check(surface.canvas.maxX==200,"Moving an image past the edge grows the canvas")
        surface.growsCanvasForMovedImages=false
        surface.moveLayer(1,by:40,0)
        check(surface.canvas.maxX==200,"With auto-grow off the canvas stays put")
        surface.undo();surface.undo()
        surface.selectLayer(0);surface.arrangeSelectedLayer(toFront:true)
        check(surface.layers[1].frame.size==CGSize(width:160,height:120),"Bring to front reorders layers")
        bitmap=NSBitmapImageRep(data:try surface.renderedPNG())!
        check(color(bitmap,105,64).redComponent>0.9,"The capture now covers the smaller image")
        surface.undo()
        surface.selectLayer(1);surface.deleteSelection()
        check(surface.layers.count==1,"Delete removes the selected image")
        surface.selectLayer(0);surface.deleteSelection()
        check(surface.layers.count==1,"The last image cannot be deleted")
        surface.undo();check(surface.layers.count==2,"Undo restores a deleted image")
        // Moved layers land on the export pixel grid so Retina images stay sharp.
        check(CanvasGeometry.aligned(CGRect(x:10.3,y:4.74,width:5,height:5),scale:2).origin==CGPoint(x:10.5,y:4.5),"Layer positions snap to whole pixels")
        return count
    }

    /// Strokes over text snap to word and line boxes; other strokes stay freehand.
    static func verifyTextSnap() -> Int {
        var count=0
        func check(_ value:Bool,_ message:String){precondition(value,message);count+=1}
        func words(_ y:CGFloat,_ xs:[(CGFloat,CGFloat)]) -> TextLine { TextLine(frame:CGRect(x:xs[0].0,y:y,width:xs.last!.1-xs[0].0,height:20),words:xs.map{CGRect(x:$0.0,y:y,width:$0.1-$0.0,height:20)}) }
        let lines=[words(200,[(10,60),(70,120),(130,200)]),words(170,[(10,80),(90,150)]),words(140,[(10,50),(60,110),(120,190)])]
        let one=TextSnap.highlightRects(for:[CGPoint(x:75,y:210),CGPoint(x:125,y:208)],lines:lines)
        check(one?.count==1,"A stroke along one line gives one band")
        check(one.map{$0[0].minX<70 && $0[0].maxX>120 && $0[0].maxX<130}==true,"The band covers exactly the words the stroke crossed")
        check(one.map{$0[0].minY<200 && $0[0].maxY>220}==true,"The band covers the full line height")
        let span=TextSnap.highlightRects(for:[CGPoint(x:80,y:210),CGPoint(x:40,y:150)],lines:lines)
        check(span?.count==3,"A stroke down three lines gives three bands")
        check(span.map{$0[0].minX>60 && $0[0].maxX>200 && $0[1].minX<10 && $0[1].maxX>150 && $0[2].minX<10 && $0[2].maxX<60}==true,"Multi-line bands follow reading order like a text selection")
        let reversed=TextSnap.highlightRects(for:[CGPoint(x:40,y:150),CGPoint(x:80,y:210)],lines:lines)
        check(reversed==span,"Dragging upward selects the same text")
        check(TextSnap.highlightRects(for:[CGPoint(x:300,y:400),CGPoint(x:400,y:420)],lines:lines)==nil,"A stroke away from text stays freehand")
        check(TextSnap.highlightRects(for:[CGPoint(x:20,y:210),CGPoint(x:300,y:50)],lines:lines)==nil,"A stroke that ends off text stays freehand")
        check(TextSnap.highlightRects(for:[CGPoint(x:20,y:210)],lines:[])==nil,"No text detected means freehand")
        // On-device Vision recognition on a synthetic screenshot, mapped into a moved layer.
        let image=textFixture()
        let found=TextSnap.recognizeLines(in:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
        check(found.count==3,"Vision finds the three synthetic lines (found \(found.count))")
        let mapped=found.map{$0.mapped(into:CGRect(x:100,y:50,width:900,height:360))}.sorted{$0.frame.midY>$1.frame.midY}
        check(mapped[1].words.count==4,"Word boxes are found for the second line (found \(mapped[1].words.count))")
        check(abs(mapped[1].frame.minX-140)<8,"Line boxes map into document points")
        let surface=DrawingSurface(frame:NSRect(x:0,y:0,width:1000,height:500),image:image)
        surface.setTextLines(found,forLayer:0)
        let start=CGPoint(x:mapped[1].words[0].minX-100+4,y:mapped[1].frame.midY-50),end=CGPoint(x:mapped[1].words[3].maxX-100-4,y:mapped[1].frame.midY-50)
        let bands=TextSnap.highlightRects(for:[start,end],lines:surface.documentTextLines)
        check(bands?.count==1 && bands.map{$0[0].width>mapped[1].frame.width-4}==true,"Dragging across a recognised line highlights the whole line")
        return count
    }

    /// Zoom maps document and view points consistently, so pinching keeps the content under the fingers.
    static func verifyZoom() -> Int {
        var count=0
        func check(_ value:Bool,_ message:String){precondition(value,message);count+=1}
        let surface=DrawingSurface(frame:NSRect(x:0,y:0,width:800,height:600),image:fixture())
        surface.zoomScale=2;surface.setFrameSize(surface.documentViewSize(viewport:CGSize(width:800,height:600)))
        let p=CGPoint(x:37,y:91)
        let back=surface.documentPoint(surface.viewPoint(p))
        check(abs(back.x-p.x)<0.001 && abs(back.y-p.y)<0.001,"View and document mapping round-trips")
        check(abs(surface.viewRect(surface.canvas).width-320)<0.001,"200% shows the canvas at twice its size")
        surface.zoomScale=8;check(surface.documentViewSize(viewport:CGSize(width:800,height:600))==CGSize(width:1392,height:1072),"Zooming in enlarges the scroll area for two-finger panning")
        return count
    }

    static func syntheticScreenshot() -> NSImage {
        let size=NSSize(width:1280,height:800)
        let image=NSImage(size:size)
        image.lockFocus()
        NSColor(calibratedRed:0.93,green:0.96,blue:0.99,alpha:1).setFill();NSRect(origin:.zero,size:size).fill()
        ("A clearer way to capture your work" as NSString).draw(at:NSPoint(x:70,y:680),withAttributes:[.font:NSFont.systemFont(ofSize:42,weight:.bold),.foregroundColor:NSColor.black])
        ("Synthetic screenshot for the editor preview, with lines of text to highlight." as NSString).draw(at:NSPoint(x:72,y:630),withAttributes:[.font:NSFont.systemFont(ofSize:24),.foregroundColor:NSColor.darkGray])
        for (index,color) in [NSColor.systemBlue,.systemTeal,.systemOrange].enumerated() {
            let x=CGFloat(70+index*390);color.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect:NSRect(x:x,y:170,width:350,height:390),xRadius:26,yRadius:26).fill()
            (["Capture","Annotate","Share"][index] as NSString).draw(at:NSPoint(x:x+32,y:480),withAttributes:[.font:NSFont.systemFont(ofSize:32,weight:.bold),.foregroundColor:NSColor.white])
            ("Your ideas, made visible." as NSString).draw(at:NSPoint(x:x+32,y:434),withAttributes:[.font:NSFont.systemFont(ofSize:21),.foregroundColor:NSColor.white])
        }
        image.unlockFocus()
        return image
    }
    static func makeEditor() throws -> CaptureEditorController {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("OpenToolkit-Editor-Preview",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let image=syntheticScreenshot()
        let url=directory.appendingPathComponent("Synthetic-screenshot.png")
        try DrawingSurface(frame:NSRect(origin:.zero,size:image.size),image:image).renderedPNG().write(to:url)
        return CaptureEditorController(item:CaptureItem(url:url),image:image)
    }
    static func preview() throws {
        editor=try makeEditor()
        let bar=NSMenu();let appItem=NSMenuItem();let appMenu=NSMenu();appItem.submenu=appMenu;bar.addItem(appItem)
        appMenu.addItem(withTitle:"Quit Editor Preview",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();let editMenu=NSMenu(title:"Edit");editItem.submenu=editMenu;bar.addItem(editItem)
        for (title,selector,key) in [("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {editMenu.addItem(withTitle:title,action:NSSelectorFromString(selector),keyEquivalent:key)}
        NSApplication.shared.mainMenu=bar
        NSApplication.shared.setActivationPolicy(.regular)
        editor?.showWindow(nil);NSApplication.shared.activate(ignoringOtherApps:true)
        NSApplication.shared.run()
    }

    /// View caching cannot draw title-bar toolbars, so the tool strip, names, keys and tooltips are drawn here for review.
    static func saveToolGuide(_ folder:URL) {
        let strip=NSSegmentedControl();strip.segmentCount=EditorToolInfo.all.count;strip.segmentStyle = .rounded;strip.trackingMode = .selectOne
        for (n,info) in EditorToolInfo.all.enumerated() {strip.setImage(NSImage(systemSymbolName:info.symbol,accessibilityDescription:info.name),forSegment:n);strip.setWidth(28,forSegment:n)}
        strip.selectedSegment=EditorToolInfo.all.firstIndex{$0.tool == .highlighter}!
        let current=NSTextField(labelWithString:"Highlighter  H");current.font = .systemFont(ofSize:12,weight:.semibold);current.textColor = .secondaryLabelColor
        var rows:[NSView]=[NSStackView(views:[strip,current])]
        for info in EditorToolInfo.all {
            let icon=NSImageView(image:NSImage(systemSymbolName:info.symbol,accessibilityDescription:info.name)!);icon.contentTintColor = .labelColor
            let text=NSTextField(labelWithString:info.tooltip.replacingOccurrences(of:"\n",with:" — "));text.font = .systemFont(ofSize:12)
            rows.append(NSStackView(views:[icon,text]))
        }
        let stack=NSStackView(views:rows);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=8;stack.edgeInsets=NSEdgeInsets(top:16,left:16,bottom:16,right:16)
        let window=NSWindow(contentRect:NSRect(x:60,y:60,width:900,height:540),styleMask:[.borderless],backing:.buffered,defer:false)
        let background=GuideBackground();stack.translatesAutoresizingMaskIntoConstraints=false;background.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:background.leadingAnchor),stack.topAnchor.constraint(equalTo:background.topAnchor)])
        window.appearance=NSAppearance(named:.darkAqua);window.contentView=background;window.orderFrontRegardless()
        RunLoop.main.run(until:Date().addingTimeInterval(0.3))
        guard let rep=background.bitmapImageRepForCachingDisplay(in:background.bounds) else{return}
        background.cacheDisplay(in:background.bounds,to:rep)
        try? rep.representation(using:.png,properties:[:])?.write(to:folder.appendingPathComponent("00-tool-guide.png"))
        window.orderOut(nil);print("saved 00-tool-guide.png")
    }
    /// Drives the real editor with synthetic mouse events and saves window images for review.
    static func snapshots(_ folder:URL) throws {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let editor=try makeEditor();self.editor=editor
        guard let window=editor.window else{return}
        window.setFrame(NSRect(x:80,y:80,width:1180,height:780),display:true)
        window.orderFrontRegardless()
        let surface=editor.surface
        func settle(_ seconds:Double = 0.4){RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
        func save(_ name:String){
            settle()
            guard let frame=window.contentView?.superview else{return}
            frame.layoutSubtreeIfNeeded();frame.display()
            guard let rep=frame.bitmapImageRepForCachingDisplay(in:frame.bounds) else{return}
            frame.cacheDisplay(in:frame.bounds,to:rep)
            try? rep.representation(using:.png,properties:[:])?.write(to:folder.appendingPathComponent(name+".png"))
            print("saved \(name).png")
        }
        func mouse(_ type:NSEvent.EventType,_ document:CGPoint,_ flags:NSEvent.ModifierFlags=[])->NSEvent {
            let point=surface.convert(surface.viewPoint(document),to:nil)
            return NSEvent.mouseEvent(with:type,location:point,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        func drag(_ from:CGPoint,_ to:CGPoint,_ flags:NSEvent.ModifierFlags=[],steps:Int=12){
            surface.mouseDown(with:mouse(.leftMouseDown,from,flags))
            for n in 1...steps {let t=CGFloat(n)/CGFloat(steps);surface.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:from.x+(to.x-from.x)*t,y:from.y+(to.y-from.y)*t+(flags.contains(.option) ? sin(t * .pi)*14:0)),flags))}
            surface.mouseUp(with:mouse(.leftMouseUp,to,flags))
        }
        saveToolGuide(folder)
        save("01-open-fit")
        // Grow the canvas by dragging its right and bottom edges, as a user would.
        drag(CGPoint(x:1280,y:400),CGPoint(x:1700,y:400))
        drag(CGPoint(x:640,y:0),CGPoint(x:640,y:-220))
        save("02-canvas-grown")
        // A second image arrives as a layer and is dragged into the new room.
        surface.combineHorizontal=true
        _ = surface.combine([textFixture(NSSize(width:420,height:300))])
        settle()
        let second=surface.layers[1].frame
        drag(CGPoint(x:second.midX,y:second.midY),CGPoint(x:1490,y:200))
        save("03-second-image-moved")
        // Smart highlight across one line of the capture, then across the second image, and one freehand stroke.
        let deadline=Date().addingTimeInterval(20)
        while surface.isDetectingText && Date()<deadline {settle(0.2)}
        surface.tool = .highlighter;surface.color = .systemYellow
        let lines=surface.documentTextLines.sorted{$0.frame.midY>$1.frame.midY}
        print("text lines detected: \(lines.count)")
        if let title=lines.first(where:{$0.frame.minY>600 && $0.frame.minY<700}) {drag(CGPoint(x:title.words[0].midX,y:title.frame.midY),CGPoint(x:title.words[min(3,title.words.count-1)].midX,y:title.frame.midY))}
        let onSecond=lines.filter{surface.layers[1].frame.contains(CGPoint(x:$0.frame.midX,y:$0.frame.midY))}
        if onSecond.count>=2 {drag(CGPoint(x:onSecond[0].words[1].midX,y:onSecond[0].frame.midY),CGPoint(x:onSecond[1].words[1].midX,y:onSecond[1].frame.midY))}
        drag(CGPoint(x:120,y:110),CGPoint(x:520,y:110),[.option])
        surface.tool = .arrow;surface.color = .systemRed
        drag(CGPoint(x:1500,y:-150),CGPoint(x:1300,y:30))
        surface.tool = .select
        save("04-smart-highlight")
        editor.zoom(to:2,anchor:window.contentView!.convert(NSPoint(x:400,y:420),to:nil))
        save("05-zoom-200")
        editor.zoom(to:nil)
        surface.tool = .highlighter
        save("06-highlighter-selected")
        try surface.renderedPNG().write(to:folder.appendingPathComponent("07-exported.png"))
        print("saved 07-exported.png")
    }
}

private final class GuideBackground:NSView {
    override func draw(_ dirtyRect:NSRect){NSColor(white:0.15,alpha:1).setFill();bounds.fill()}
}
