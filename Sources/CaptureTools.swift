import AppKit
import SwiftUI
import Combine
import CoreGraphics
import ImageIO

/// Decode a small preview rather than a full Retina screenshot for every tray card.
func captureThumbnail(_ url: URL, maxPixels: Int = 280) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
          ] as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
}

/// Owns only this utility's captures. All image files remain in local application storage.
@MainActor
final class CaptureCoordinator: NSObject, ObservableObject {
    @Published var status = "Ready to capture"
    @Published var captures: [CaptureItem] = []
    @Published fileprivate var trayItems: [CaptureItem] = []
    var onStatus: ((String) -> Void)?
    private let folder: URL
    private let trayState: URL
    private let index: CaptureIndex
    private var cleanupTimer: Timer?
    @Published var retentionHours = UserDefaults.standard.object(forKey:"captureRetentionHours") as? Int ?? 24
    private var selectionWindows: [ToolOverlayWindow] = []
    private var annotationWindows: [ToolOverlayWindow] = []
    private var liveSurfaces: [DrawingSurface] = []
    private var drawingOwner: NSRunningApplication?
    private var heldDrawingTool: String?
    private var annotationColor = NSColor.systemOrange
    private var palette: NSPanel?
    private var paletteController: DrawingToolbarController?
    private var previewPanels:[UUID:NSPanel]=[:]
    private var recentPanel:NSPanel?
    private var hiddenPinned:[NSPanel]=[]
    private var previewsHidden=false
    private var pinnedPreviews:[NSPanel]=[]
    private var editors: [CaptureEditorController] = []
    private var captureInFlight = false
    private var captureProcess: Process?
    private var captureFailure: String?
    private var selectionGeneration = 0

    init(storage: URL) {
        folder = storage.appendingPathComponent("Captures", isDirectory: true)
        trayState = storage.appendingPathComponent("capture-tray.json")
        index = CaptureIndex(url:storage.appendingPathComponent("capture-history.sqlite"))
        super.init()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            captures = urls.filter { ["png","gif"].contains($0.pathExtension.lowercased()) }.map {
                CaptureItem(url: $0, date: (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast)
            }.sorted { $0.date > $1.date }
            for item in captures {_ = index.register(name:item.url.lastPathComponent,date:item.date,kept:true)}
            if let data = try? Data(contentsOf: trayState), let names = try? JSONDecoder().decode([String].self, from: data) {
                trayItems = names.compactMap { name in captures.first { $0.url.lastPathComponent == name } }
            }
        } catch { status = "Cannot open capture storage: \(error.localizedDescription)" }
        cleanupTimer=Timer.scheduledTimer(withTimeInterval:60,repeats:true){[weak self] _ in Task{@MainActor in self?.cleanupExpired()}}
        cleanupExpired()
        if !trayItems.isEmpty { DispatchQueue.main.async { [weak self] in self?.showTray() } }
    }

    private func report(_ message: String) { status = message; onStatus?(message) }

    private var optionsPanel:NSPanel?
    func captureFullScreen(){
        guard !captureInFlight else{return}
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {report("Enable Screen Recording permission for OpenToolkit.");return}
        guard let screen=NSScreen.screens.first(where:{NSMouseInRect(NSEvent.mouseLocation,$0.frame,false)}) ?? NSScreen.main else{return}
        cancel();finishSelection(screen.frame)
    }
    func importCapture(_ source:URL){
        do {
            let output=folder.appendingPathComponent("Capture-\(UUID().uuidString).\(source.pathExtension)")
            try FileManager.default.copyItem(at:source,to:output)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
            let item=CaptureItem(url:output);_ = index.register(name:output.lastPathComponent,date:item.date,kept:false)
            captures.insert(item,at:0);trayItems.insert(item,at:0);saveTrayState();showTray();report("Capture ready · drag it into an app or Save to…")
        }catch{report("Could not add capture to history: \(error.localizedDescription)")}
    }

    func captureRegion(fixedSize: CGSize? = nil) {
        guard !captureInFlight else { report("Finishing the previous capture…"); return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            report("Allow OpenToolkit in System Settings → Privacy & Security → Screen Recording, then try again.")
            return
        }
        cancel()
        hideCapturePreviews()
        selectionGeneration += 1
        let generation = selectionGeneration
        report(fixedSize == nil ? "Drag an area to capture · Escape to cancel" : "Move the fixed frame, then click or drag to capture · Escape to cancel")
        for screen in NSScreen.screens {
            let window = ToolOverlayWindow(frame: screen.frame)
            let selector = RegionSelectionView(frame: window.contentView!.bounds, fixedSize: fixedSize)
            selector.onCancel = { [weak self] in self?.cancel() }
            selector.onComplete = { [weak self, weak window] rect in
                guard let self, let window, self.selectionGeneration == generation else { return }
                let global = window.convertToScreen(rect)
                self.finishSelection(global)
            }
            window.contentView = selector
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(selector)
            selectionWindows.append(window)
        }
        if let current = selectionWindows.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) { current.makeKeyAndOrderFront(nil) }
        NSCursor.crosshair.push()
    }

    private func finishSelection(_ rect: CGRect) {
        guard rect.width >= 3, rect.height >= 3 else { cancel(); return }
        selectionGeneration += 1
        let generation = selectionGeneration
        closeSelection()
        captureInFlight = true
        captureFailure = nil
        hideCapturePreviews()
        report("Capturing…")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let output = folder.appendingPathComponent("Capture-\(stamp)-\(UUID().uuidString.prefix(6)).png")
        // screencapture's global origin is at the primary display's top-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let region = "\(Int(rect.minX.rounded())),\(Int((primaryTop - rect.maxY).rounded())),\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            guard self.selectionGeneration == generation else {
                self.captureInFlight = false; self.showTray(); return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-t", "png", "-R", region, output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] task in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.captureInFlight = false
                    self.captureProcess = nil
                    if task.terminationStatus == 0, let image = NSImage(contentsOf: output), image.isValid {
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                        let item = CaptureItem(url: output)
                        _ = self.index.register(name:item.url.lastPathComponent,date:item.date,kept:false)
                        self.captures.insert(item, at: 0)
                        self.trayItems.insert(item, at: 0)
                        self.saveTrayState()
                        self.showTray()
                        self.report("Screenshot ready · drag it into an app, or click to annotate")
                    } else {
                        try? FileManager.default.removeItem(at: output)
                        self.showTray()
                        self.report(self.captureFailure ?? "Capture failed. Check Screen Recording permission in System Settings.")
                    }
                    self.captureFailure = nil
                }
            }
            do {
                self.captureProcess = process
                try process.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak process] in
                    guard let self, let process, self.captureProcess === process, process.isRunning else { return }
                    self.captureFailure = "Screen capture timed out. Try again after checking Screen Recording permission."
                    process.terminate()
                }
            }
            catch { self.captureInFlight = false; self.captureProcess = nil; self.showTray(); self.report("Cannot start screen capture: \(error.localizedDescription)") }
        }
    }

    func cancel() {
        selectionGeneration += 1
        if let captureProcess, captureProcess.isRunning {
            captureFailure = "Screen capture cancelled"
            captureProcess.terminate()
        }
        closeSelection()
        for window in annotationWindows { window.orderOut(nil); window.close() }
        annotationWindows.removeAll(); liveSurfaces.removeAll();heldDrawingTool=nil;drawingOwner=nil
        palette?.orderOut(nil); palette?.close(); palette = nil; paletteController = nil
        if !captureInFlight {previewsHidden=false;showTray();report("Ready to capture") }
    }

    private func closeSelection() {
        if !selectionWindows.isEmpty { NSCursor.pop() }
        for window in selectionWindows { window.orderOut(nil); window.close() }
        selectionWindows.removeAll()
    }

    func endDrawing() {
        liveSurfaces.forEach { $0.finishStroke() }
        annotationWindows.forEach { $0.ignoresMouseEvents = true }
        palette?.orderOut(nil)
        heldDrawingTool = nil
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            drawingOwner?.activate(options: [])
        }
        report("Annotations stay visible · use Clear to erase")
    }

    func releaseDrawing(_ name: String) {
        guard heldDrawingTool == name else { return }
        if name == "text",liveSurfaces.contains(where:{$0.hasTextEntry}) {return}
        endDrawing()
    }

    func clearAnnotations() {
        liveSurfaces.forEach { $0.clear() }
        endDrawing()
        report("Screen annotations cleared")
    }

    func annotationAction(_ name: String) {
        if name == "clear" { clearAnnotations(); return }
        if name == "undo" { (paletteController?.activeSurface ?? liveSurfaces.first)?.undo(); return }
        let colors: [String:NSColor] = ["blue":.systemBlue,"pink":.systemPink,"orange":.systemOrange,"yellow":.systemYellow,"green":.systemGreen]
        if let color = colors[name] { annotationColor=color;liveSurfaces.forEach{$0.color=color};return }
        beginDrawing(name)
    }

    func beginDrawing(_ name: String, showPalette: Bool = false) {
        guard !captureInFlight else { return }
        let tools: [String:DrawingTool] = ["pen":.pen,"line":.line,"arrow":.arrow,"rectangle":.rectangle,"ellipse":.ellipse,"text":.text,"eraser":.eraser]
        guard let tool=tools[name] else { return }
        if heldDrawingTool == nil { drawingOwner=NSWorkspace.shared.frontmostApplication }
        closeSelection()
        if annotationWindows.isEmpty {
            let controller=DrawingToolbarController()
            for screen in NSScreen.screens {
                let window=ToolOverlayWindow(frame:screen.frame)
                let surface=DrawingSurface(frame:window.contentView!.bounds,image:nil)
                surface.onEscape={ [weak self] in self?.endDrawing() }
                surface.onTextFinished={ [weak self] in DispatchQueue.main.async {if self?.heldDrawingTool == "text" {self?.endDrawing()}} }
                surface.onActivity={ [weak controller,weak surface] in controller?.activeSurface=surface }
                window.contentView=surface
                annotationWindows.append(window);liveSurfaces.append(surface)
            }
            controller.surfaces=liveSurfaces;controller.activeSurface=liveSurfaces.first
            controller.onDone={ [weak self] in self?.endDrawing() }
            paletteController=controller
        }
        heldDrawingTool=name
        let width=UserDefaults.standard.object(forKey:"annotationWidth") as? Double ?? 4
        let textSize=UserDefaults.standard.object(forKey:"annotationTextSize") as? Double ?? 24
        for (window,surface) in zip(annotationWindows,liveSurfaces) {
            surface.tool=tool;surface.color=annotationColor;surface.strokeWidth=width;surface.textSize=textSize
            window.ignoresMouseEvents=false;window.orderFrontRegardless()
            if NSMouseInRect(NSEvent.mouseLocation,window.frame,false) {window.makeKey();window.makeFirstResponder(surface);paletteController?.activeSurface=surface}
        }
        if showPalette, let controller=paletteController {
            if palette == nil {
                let frame=(NSScreen.main?.visibleFrame ?? .zero)
                let panel=NSPanel(contentRect:CGRect(x:frame.midX-430,y:frame.maxY-130,width:860,height:88),styleMask:[.titled,.utilityWindow,.nonactivatingPanel],backing:.buffered,defer:false)
                panel.title="Screen drawing · Done leaves marks visible"
                panel.level=NSWindow.Level(rawValue:NSWindow.Level.screenSaver.rawValue+3)
                panel.isFloatingPanel=true;panel.hidesOnDeactivate=false
                panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
                panel.contentView=controller.makeToolbar(live:true);palette=panel
            }
            palette?.orderFrontRegardless()
        }
        report("Drawing · release the shortcut to return to your app")
    }

    func annotateScreen() { beginDrawing("pen",showPalette:true) }

    func openEditor(_ item: CaptureItem) {
        if let existing = editors.first(where: { $0.item.url == item.url }) { existing.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let image = NSImage(contentsOf: item.url) else { report("This capture is no longer available."); return }
        let editor = CaptureEditorController(item: item, image: image)
        editor.onStatus = { [weak self] text in self?.report(text) }
        editor.onSaved = { [weak self] in self?.keep(item); self?.showTray() }
        editor.onClose = { [weak self, weak editor] in
            guard let editor else { return }
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reveal(_ item: CaptureItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    /// Ask about unsaved editor annotations before the application exits.
    /// The application delegate should return .terminateCancel if this returns false.
    func prepareToQuit() -> Bool {
        for editor in Array(editors) {
            guard let window = editor.window else { continue }
            guard editor.windowShouldClose(window) else { return false }
            editor.close()
        }
        return true
    }

    func copy(_ item: CaptureItem) {
        guard let image = NSImage(contentsOf: item.url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        report("Screenshot copied")
    }

    func restorePreview(_ item:CaptureItem) {
        trayItems.removeAll{$0.id==item.id};trayItems.insert(item,at:0)
        trayItems=Array(trayItems.prefix(10));saveTrayState();showTray()
    }
    func pinPreview(_ item:CaptureItem) {
        guard let image=NSImage(contentsOf:item.url) else{return}
        keep(item)
        let scale=min(1,420/max(image.size.width,image.size.height))
        let size=CGSize(width:max(180,image.size.width*scale),height:max(100,image.size.height*scale))
        let panel=NSPanel(contentRect:CGRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.utilityWindow,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title="Pinned screenshot";panel.level = .floating;panel.hidesOnDeactivate=false
        panel.isReleasedWhenClosed=false;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView=NSHostingView(rootView:CaptureDragPreview(url:item.url,onOpen:{[weak self] in self?.openEditor(item)}))
        panel.center();panel.orderFrontRegardless()
        pinnedPreviews.removeAll{!$0.isVisible};pinnedPreviews.append(panel)
    }

    fileprivate func dismiss(_ item: CaptureItem) {
        trayItems.removeAll { $0.id == item.id }
        saveTrayState(); showTray()
    }

    func saveAs(_ item: CaptureItem) {
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.allowedContentTypes = [.png]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let target = panel.url else { return }
            do {
                let data = try Data(contentsOf: item.url)
                try data.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                _ = self.index.keep(name:item.url.lastPathComponent,exported:target.path)
                self.objectWillChange.send()
                self.dismiss(item)
                self.report("Screenshot saved")
            } catch { self.report("Save failed: \(error.localizedDescription)") }
        }
    }

    func isKept(_ item:CaptureItem)->Bool {index.kept(name:item.url.lastPathComponent)}
    func keep(_ item:CaptureItem){if index.keep(name:item.url.lastPathComponent){objectWillChange.send();report("Screenshot kept — it will not expire")}else{report("Could not update screenshot history; cleanup stays conservative")}}
    func setRetention(_ hours:Int){guard [0,1,24,168,720].contains(hours) else{return};retentionHours=hours;UserDefaults.standard.set(hours,forKey:"captureRetentionHours");cleanupExpired()}
    func cleanupExpired(now:Date = Date()){
        for item in captures where index.expired(name:item.url.lastPathComponent,date:item.date,hours:retentionHours,now:now){
            guard !editors.contains(where:{$0.item.url==item.url}),item.url.deletingLastPathComponent().standardizedFileURL==folder.standardizedFileURL else{continue}
            do{try FileManager.default.trashItem(at:item.url,resultingItemURL:nil);index.remove(name:item.url.lastPathComponent);captures.removeAll{$0.id==item.id};trayItems.removeAll{$0.id==item.id}}
            catch{report("Could not move an expired capture to Trash; it was retained")}
        }
        saveTrayState();showTray()
    }

    private func saveTrayState() {
        do {
            try JSONEncoder().encode(trayItems.map { $0.url.lastPathComponent }).write(to: trayState, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trayState.path)
        }
        catch { report("Could not save the tray state: \(error.localizedDescription)") }
    }

    private func hideCapturePreviews() {
        if !previewsHidden {hiddenPinned=pinnedPreviews.filter{$0.isVisible}}
        previewsHidden=true
        previewPanels.values.forEach{$0.orderOut(nil)}
        recentPanel?.orderOut(nil)
        pinnedPreviews.forEach{$0.orderOut(nil)}
    }
    func showRecentHistory() {
        guard !captureInFlight,selectionWindows.isEmpty else{return}
        let visible=(NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x:0,y:0,width:1000,height:800)
        let panel=recentPanel ?? NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true;panel.level = .floating;panel.hidesOnDeactivate=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView=NSHostingView(rootView:RecentCaptureStrip(coordinator:self,onClose:{[weak panel] in panel?.orderOut(nil)}))
        let width=min(visible.width-36,max(360,CGFloat(min(captures.count,10))*166+36))
        panel.setFrame(CGRect(x:visible.midX-width/2,y:visible.maxY-180,width:width,height:164),display:true)
        panel.orderFrontRegardless();recentPanel=panel
    }
    private func showTray() {
        guard !captureInFlight,selectionWindows.isEmpty else{return}
        previewsHidden=false
        hiddenPinned.forEach{$0.orderFrontRegardless()};hiddenPinned=[]
        let visible=(NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x:0,y:0,width:1000,height:800)
        let count=max(1,Int((visible.height-36)/140))
        let visibleItems=Array(trayItems.prefix(count))
        let ids=Set(visibleItems.map(\.id))
        for (id,panel) in previewPanels where !ids.contains(id) {panel.orderOut(nil);previewPanels.removeValue(forKey:id)}
        for (i,item) in visibleItems.enumerated() {
            let panel=previewPanels[item.id] ?? NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true;panel.level = .floating;panel.hidesOnDeactivate=false
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            panel.contentView=NSHostingView(rootView:CaptureTrayCard(coordinator:self,item:item).padding(5).background(Color(red:0.10,green:0.12,blue:0.15),in:RoundedRectangle(cornerRadius:14)))
            panel.setFrame(CGRect(x:visible.minX+18,y:visible.minY+18+CGFloat(i)*140,width:200,height:128),display:true)
            panel.orderFrontRegardless();previewPanels[item.id]=panel
        }
    }

}

private struct RecentCaptureStrip:View {
    @ObservedObject var coordinator:CaptureCoordinator
    let onClose:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {Text("Recent screenshots").font(.headline);Text("Latest 10 · drag into an editor or app").font(.caption).foregroundStyle(.secondary);Spacer();Button(action:onClose){Image(systemName:"xmark")}.buttonStyle(.plain).help("Hide history strip")}
            if coordinator.captures.isEmpty {Text("Your screenshots will appear here.").foregroundStyle(.secondary)}
            ScrollView(.horizontal,showsIndicators:true) {
                HStack(spacing:12) {ForEach(Array(coordinator.captures.prefix(10))){item in
                    CaptureDragPreview(url:item.url,onClick:{coordinator.openEditor(item)},onOpen:{coordinator.openEditor(item)}).frame(width:154,height:98).background(.black.opacity(0.2),in:RoundedRectangle(cornerRadius:8)).contextMenu{Button("Edit"){coordinator.openEditor(item)};Button("Show floating preview"){coordinator.restorePreview(item)};Button("Save as…"){coordinator.saveAs(item)}}}}
            }
        }.padding(14).background(Color(red:0.10,green:0.12,blue:0.15),in:RoundedRectangle(cornerRadius:14)).preferredColorScheme(.dark)
    }
}
private struct CaptureTrayCard:View {
    @ObservedObject var coordinator:CaptureCoordinator
    let item:CaptureItem
    @State private var hovering=false
    @State private var selected=false
    var body:some View {
        ZStack(alignment:.bottom){
            CaptureDragPreview(url:item.url,onClick:{selected.toggle()},onOpen:{coordinator.openEditor(item)})
                .frame(width:190,height:118).background(Color.black.opacity(0.2))
            if hovering || selected {
                Color.black.opacity(0.48).allowsHitTesting(false)
                VStack {
                    HStack {
                        corner("xmark",help:"Dismiss preview; keep in History"){coordinator.dismiss(item)}
                        Spacer()
                        corner("pin.fill",help:"Pin screenshot on screen"){coordinator.pinPreview(item)}
                    }
                    Spacer()
                    VStack(spacing:5) {
                        Button{coordinator.copy(item)}label:{Text("Copy").font(.system(size:11,weight:.semibold)).foregroundStyle(.black).frame(width:48,height:22).background(.white.opacity(0.9),in:Capsule())}
                        Button{coordinator.saveAs(item)}label:{Text("Save").font(.system(size:11,weight:.semibold)).foregroundStyle(.black).frame(width:48,height:22).background(.white.opacity(0.9),in:Capsule())}
                    }.buttonStyle(.plain)
                    Spacer()
                    HStack {
                        corner("pencil",help:"Edit screenshot"){coordinator.openEditor(item)}
                        Spacer()
                        corner("folder",help:"Show local image in Finder"){coordinator.reveal(item)}
                    }
                }.padding(7)
            }
        }.frame(width:190,height:118).clipShape(RoundedRectangle(cornerRadius:10)).onHover{hovering=$0}
        .help("Double-click to open · drag to another app · click for actions")
        .contextMenu{Button("Edit"){coordinator.openEditor(item)};Button("Copy"){coordinator.copy(item)};Button("Keep"){coordinator.keep(item)};Button("Save to…"){coordinator.saveAs(item)};Button("Show in Finder"){coordinator.reveal(item)};Button("Hide preview"){coordinator.dismiss(item)}}
    }
    private func corner(_ symbol:String,help:String,action:@escaping()->Void)->some View {
        Button(action:action){Image(systemName:symbol).font(.system(size:9,weight:.bold)).foregroundStyle(.black.opacity(0.8)).frame(width:19,height:19).background(.white.opacity(0.85),in:Circle())}.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

}

private final class ToolOverlayWindow: NSWindow {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear
        hasShadow = false; acceptsMouseMovedEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RegionSelectionView: NSView {
    let fixedSize: CGSize?
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var anchor: CGPoint?
    private var selection: CGRect?
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, fixedSize: CGSize?) { self.fixedSize = fixedSize; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(bounds.maxX, max(0, p.x)), y: min(bounds.maxY, max(0, p.y)))
    }
    private func fixedRect(at p: CGPoint) -> CGRect {
        let width = min(bounds.width, max(10, fixedSize?.width ?? 640))
        let height = min(bounds.height, max(10, fixedSize?.height ?? 360))
        return CGRect(x: min(bounds.width - width, max(0, p.x - width / 2)), y: min(bounds.height - height, max(0, p.y - height / 2)), width: width, height: height)
    }
    override func mouseMoved(with event: NSEvent) {
        if fixedSize != nil, anchor == nil { selection = fixedRect(at: point(event)); needsDisplay = true }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); anchor = point(event)
        selection = fixedSize == nil ? CGRect(origin: anchor!, size: .zero) : fixedRect(at: anchor!)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = point(event)
        selection = fixedSize == nil ? CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y)) : fixedRect(at: p)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { if let selection { onComplete?(selection) } }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.36).setFill(); bounds.fill()
        if let selection, selection.width > 0, selection.height > 0 {
            NSColor.clear.setFill(); selection.fill(using: .copy)
            NSColor.white.setStroke(); let outline = NSBezierPath(rect: selection); outline.lineWidth = 1.5; outline.stroke()
            let label = "\(Int(selection.width)) × \(Int(selection.height)) pt"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.7)]
            (label as NSString).draw(at: CGPoint(x: selection.minX + 5, y: max(5, selection.minY - 23)), withAttributes: attrs)
        }
        let hint = fixedSize == nil ? "Drag to select an area • Escape cancels" : "Move the frame • Click or drag to capture • Escape cancels"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white]
        let size = (hint as NSString).size(withAttributes: attrs)
        (hint as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 64), withAttributes: attrs)
    }
}

@MainActor
private final class DrawingToolbarController: NSObject {
    var surfaces: [DrawingSurface] = []
    weak var activeSurface: DrawingSurface?
    var onDone: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onCopy: (() -> Void)?
    private var displayedTools:[DrawingTool]=[]
    private let colors: [(String, NSColor)] = [("Red", .systemRed), ("Gold", .systemYellow), ("Blue", .systemBlue), ("Green", .systemGreen), ("Purple", .systemPurple), ("White", .white), ("Black", .black)]

    func makeToolbar(live: Bool) -> NSView {
        displayedTools=live ? [.pen,.arrow,.rectangle,.ellipse,.text,.line,.eraser]:DrawingTool.allCases
        let tools = NSSegmentedControl(labels: displayedTools.map(\.title), trackingMode: .selectOne, target: self, action: #selector(changeTool(_:)))
        tools.selectedSegment = 0; tools.toolTip = "Pen · Arrow · Rectangle · Ellipse · Text"
        let color = NSPopUpButton(); for value in colors { color.addItem(withTitle: value.0) }
        color.target = self; color.action = #selector(changeColor(_:)); color.toolTip = "Stroke color"
        let width = NSSlider(value: 4, minValue: 1, maxValue: 16, target: self, action: #selector(changeWidth(_:)))
        width.toolTip = "Stroke thickness"; width.widthAnchor.constraint(equalToConstant: 65).isActive = true
        func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded
            if !live,title == "Done" {b.keyEquivalent="s";b.keyEquivalentModifierMask=[.command];b.toolTip="Save edits and close"}
            if title == "Save as…" {b.keyEquivalent="s";b.keyEquivalentModifierMask=[.command,.shift];b.toolTip="Export to Desktop or another folder"}
            return b }
        let custom=NSColorWell();custom.color = .systemRed;custom.target=self;custom.action=#selector(customColor(_:));custom.toolTip="Custom colour";custom.widthAnchor.constraint(equalToConstant:40).isActive=true
        let textSize=NSPopUpButton();[12,16,20,24,32,48,64].forEach{textSize.addItem(withTitle:String($0))};textSize.selectItem(withTitle:"24");textSize.target=self;textSize.action=#selector(changeTextSize(_:));textSize.toolTip="Text size"
        var views: [NSView] = [tools, color,custom,width,textSize, button("Undo", #selector(undo)), button("Clear", #selector(clear))]
        if live { views.append(button("Done", #selector(done))) }
        else { views += [button("Apply Crop", #selector(applyCrop)),button("Cancel Crop", #selector(cancelCrop)),button("Copy", #selector(copyImage)), button("Save", #selector(save)), button("Save as…", #selector(saveAs)),button("Done", #selector(done))] }
        if !live {let layout=NSPopUpButton();layout.addItems(withTitles:["Stack vertically","Join horizontally"]);layout.target=self;layout.action=#selector(combineDirection(_:));layout.toolTip="Drop images onto the canvas to combine";views.append(layout)}
        let row = NSStackView(views: Array(views.prefix(5))); row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        let second=NSStackView(views:Array(views.dropFirst(5)));second.orientation = .horizontal;second.spacing=8
        let stack=NSStackView(views:[row,second]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=8
        let container = NSView(); stack.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:12),stack.trailingAnchor.constraint(lessThanOrEqualTo:container.trailingAnchor,constant:-12),stack.centerYAnchor.constraint(equalTo:container.centerYAnchor)])
        return container
    }
    @objc private func changeTool(_ sender: NSSegmentedControl) { guard displayedTools.indices.contains(sender.selectedSegment) else { return }; surfaces.forEach { $0.tool = displayedTools[sender.selectedSegment] } }
    @objc private func changeColor(_ sender: NSPopUpButton) { let color = colors[max(0, sender.indexOfSelectedItem)].1; surfaces.forEach { $0.color = color } }
    @objc private func customColor(_ sender:NSColorWell){surfaces.forEach{$0.color=sender.color}}
    @objc private func changeTextSize(_ sender:NSPopUpButton){if let value=Double(sender.titleOfSelectedItem ?? "24"){surfaces.forEach{$0.textSize=CGFloat(value)}}}
    @objc private func combineDirection(_ sender:NSPopUpButton){surfaces.forEach{$0.combineHorizontal=sender.indexOfSelectedItem==1}}
    @objc private func changeWidth(_ sender: NSSlider) { surfaces.forEach { $0.strokeWidth = CGFloat(sender.doubleValue) } }
    @objc private func undo() { activeSurface?.undo() }
    @objc private func clear() { surfaces.forEach { $0.clear() } }
    @objc private func done() { onDone?() }
    @objc private func applyCrop(){activeSurface?.applyCrop()}
    @objc private func cancelCrop(){activeSurface?.cancelCrop()}
    @objc private func save() { onSave?() }
    @objc private func saveAs() { onSaveAs?() }
    @objc private func copyImage() { onCopy?() }
}
