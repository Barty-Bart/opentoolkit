import AppKit

/// Standalone editor verification; no speech worker, user database, or capture permissions.
@main @MainActor struct CaptureEditorTests {
    static var editor: CaptureEditorController?
    static func fixture(_ width:Int = 160,_ height:Int = 120) -> NSImage {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        NSColor.white.setFill();NSRect(x:0,y:0,width:width,height:height).fill()
        NSColor.systemBlue.setFill();NSRect(x:0,y:0,width:width/2,height:height/2).fill()
        context.flushGraphics();NSGraphicsContext.restoreGraphicsState()
        return NSImage(data:bitmap.representation(using:.png,properties:[:])!)!
    }
    static func main() throws {
        _ = NSApplication.shared
        #if EDITOR_PREVIEW
        try preview()
        #else
        if CommandLine.arguments.contains("--preview") { try preview();return }
        try verify()
        #endif
    }
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
        surface.addAnnotation(DrawingMark(tool:.redact,points:[CGPoint(x:40,y:30),CGPoint(x:120,y:90)],color:.red,width:4))
        let redacted=try pixels().colorAt(x:80,y:60)!.usingColorSpace(.deviceRGB)!
        check(redacted.redComponent<0.01 && redacted.greenComponent<0.01 && redacted.blueComponent<0.01 && redacted.alphaComponent>0.99,"Redaction must be opaque black in exported pixels")
        surface.undo();check(try surface.renderedPNG()==original,"Undo restores original pixels")
        surface.redo();check(try surface.renderedPNG() != original,"Redo restores annotation")
        surface.crop(to:CGRect(x:20,y:20,width:80,height:60))
        let cropped=try pixels();check(cropped.pixelsWide==80 && cropped.pixelsHigh==60,"Crop dimensions are correct")
        surface.undo();check(try pixels().pixelsWide==160,"Crop undo restores full image")
        surface.clear();check(try surface.renderedPNG()==original,"Clear removes annotations")
        surface.addAnnotation(DrawingMark(tool:.highlighter,points:[CGPoint(x:10,y:85),CGPoint(x:150,y:85)],color:.yellow,width:20))
        let highlighted=try pixels().colorAt(x:80,y:35)!.usingColorSpace(.deviceRGB)!
        check(highlighted.redComponent>0.9 && highlighted.blueComponent<0.9 && highlighted.blueComponent>0.4,"Highlight preserves content with translucency")
        surface.undo()
        check(surface.combine([fixture(40,30)]),"Vertical combination succeeds")
        let vertical=try pixels();check(vertical.pixelsWide==160 && vertical.pixelsHigh==166,"Vertical combination keeps pixels and gap")
        surface.undo();surface.combineHorizontal=true
        check(surface.combine([fixture(40,30)]),"Horizontal combination succeeds")
        let horizontal=try pixels();check(horizontal.pixelsWide==216 && horizontal.pixelsHigh==120,"Horizontal combination keeps pixels and gap")
        surface.undo()
        surface.addAnnotation(DrawingMark(tool:.filledRectangle,points:[CGPoint(x:40,y:30),CGPoint(x:120,y:90)],color:.red,width:4))
        let filled=try pixels().colorAt(x:80,y:60)!.usingColorSpace(.deviceRGB)!
        check(filled.redComponent>0.9 && filled.blueComponent<0.1,"Filled shape exports with its selected color")
        surface.flattenSavedImage(NSImage(data:try surface.renderedPNG())!)
        check(!surface.hasChanges,"Saving resets dirty state")
        print("Screenshot renderer: \(count) checks passed")
    }
    static func preview() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("OpenToolkit-Editor-Preview",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let size=NSSize(width:1280,height:800)
        let image=NSImage(size:size)
        image.lockFocus()
        NSColor(calibratedRed:0.93,green:0.96,blue:0.99,alpha:1).setFill();NSRect(origin:.zero,size:size).fill()
        ("A clearer way to capture your work" as NSString).draw(at:NSPoint(x:70,y:680),withAttributes:[.font:NSFont.systemFont(ofSize:42,weight:.bold),.foregroundColor:NSColor.labelColor])
        ("Synthetic screenshot • editor preview" as NSString).draw(at:NSPoint(x:72,y:640),withAttributes:[.font:NSFont.systemFont(ofSize:22),.foregroundColor:NSColor.secondaryLabelColor])
        for (index,color) in [NSColor.systemBlue,.systemTeal,.systemOrange].enumerated() {
            let x=CGFloat(70+index*390);color.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect:NSRect(x:x,y:210,width:350,height:350),xRadius:26,yRadius:26).fill()
            (["Capture","Annotate","Share"][index] as NSString).draw(at:NSPoint(x:x+32,y:480),withAttributes:[.font:NSFont.systemFont(ofSize:32,weight:.bold),.foregroundColor:NSColor.white])
            ("Your ideas, made visible." as NSString).draw(at:NSPoint(x:x+32,y:434),withAttributes:[.font:NSFont.systemFont(ofSize:21),.foregroundColor:NSColor.white])
        }
        image.unlockFocus()
        let url=directory.appendingPathComponent("Synthetic-screenshot.png")
        let surface=DrawingSurface(frame:NSRect(origin:.zero,size:size),image:image)
        try surface.renderedPNG().write(to:url)
        editor=CaptureEditorController(item:CaptureItem(url:url),image:image)
        let bar=NSMenu();let appItem=NSMenuItem();let appMenu=NSMenu();appItem.submenu=appMenu;bar.addItem(appItem)
        appMenu.addItem(withTitle:"Quit Editor Preview",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();let editMenu=NSMenu(title:"Edit");editItem.submenu=editMenu;bar.addItem(editItem)
        for (title,selector,key) in [("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {editMenu.addItem(withTitle:title,action:NSSelectorFromString(selector),keyEquivalent:key)}
        NSApplication.shared.mainMenu=bar
        NSApplication.shared.setActivationPolicy(.regular)
        editor?.showWindow(nil);NSApplication.shared.activate(ignoringOtherApps:true)
        NSApplication.shared.run()
    }
}
