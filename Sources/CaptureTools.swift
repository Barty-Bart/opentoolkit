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

struct CaptureItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let date: Date
    init(url: URL, date: Date = Date(), id: UUID = UUID()) {
        self.id = id; self.url = url; self.date = date
    }
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
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {report("Enable Screen Recording permission for Pico.");return}
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
            report("Allow Pico in System Settings → Privacy & Security → Screen Recording, then try again.")
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

private enum DrawingTool: Int, CaseIterable { case pen, arrow, rectangle, ellipse, text, crop, line, eraser
    var title: String { ["Pen", "Arrow", "Box", "Oval", "Text", "Crop", "Line", "Eraser"][rawValue] }
}

private struct DrawingMark {
    let tool: DrawingTool
    var points: [CGPoint]
    let color: NSColor
    let width: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 24
}

@MainActor
private final class DrawingSurface: NSView, NSTextFieldDelegate {
    var image: NSImage?
    var tool: DrawingTool = .pen
    var color = NSColor.systemRed
    var strokeWidth: CGFloat = 4
    var textSize: CGFloat = 24
    var combineHorizontal = false
    var onStatus: ((String)->Void)?
    private var cropAnchor: CGPoint?
    private var cropRect: CGRect?
    private var cropMoveOrigin:CGPoint?
    private var cropMoveRect:CGRect?
    var hasPendingCrop:Bool {cropRect != nil}
    private var editedImage = false
    private struct Snapshot {let image:NSImage?;let marks:[DrawingMark];let edited:Bool}
    private var undoStates:[Snapshot]=[]
    private var redoStates:[Snapshot]=[]
    var onEscape: (() -> Void)?
    var onActivity: (() -> Void)?
    var onChange: (() -> Void)?
    var onTextFinished: (() -> Void)?
    var hasTextEntry:Bool {entry != nil}
    private var marks: [DrawingMark] = []
    private var redoMarks: [DrawingMark] = []
    private var current: DrawingMark?
    private var entry: NSTextField?
    private var entryPoint: CGPoint?
    override var acceptsFirstResponder: Bool { true }
    var hasChanges: Bool { editedImage || !marks.isEmpty || current != nil || entry != nil }

    init(frame: CGRect, image: NSImage?) {
        self.image = image; super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var canvasSize: CGSize { image?.size ?? bounds.size }
    private var canvasRect: CGRect {
        guard let image else { return bounds }
        let inset = bounds.insetBy(dx: 20, dy: 20)
        let scale = min(1, min(inset.width / max(image.size.width, 1), inset.height / max(image.size.height, 1)))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil), r = canvasRect, s = canvasSize
        return CGPoint(x: min(s.width, max(0, (p.x - r.minX) * s.width / max(r.width, 1))), y: min(s.height, max(0, (p.y - r.minY) * s.height / max(r.height, 1))))
    }
    private var effectiveWidth: CGFloat { strokeWidth * canvasSize.width / max(canvasRect.width, 1) }

    override func mouseDown(with event: NSEvent) {
        commitText(); onActivity?(); window?.makeFirstResponder(self)
        guard canvasRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        let p = canvasPoint(event)
        if tool == .crop, image != nil {
            if let r=cropRect {
                let corners=[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)]
                let tolerance=12*canvasSize.width/max(canvasRect.width,1)
                if let n=corners.firstIndex(where:{hypot($0.x-p.x,$0.y-p.y)<tolerance}) {cropAnchor=corners[(n+2)%4];return}
                if r.contains(p) {cropMoveOrigin=p;cropMoveRect=r;return}
            }
            cropAnchor=p;cropRect=nil;return
        }
        if tool == .text { beginText(at: p); return }
        if tool == .eraser {erase(at:p);return}
        current = DrawingMark(tool: tool, points: [p, p], color: color, width: effectiveWidth)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if tool == .eraser {erase(at:canvasPoint(event));return}
        if let origin=cropMoveOrigin,let original=cropMoveRect {
            let p=canvasPoint(event)
            cropRect=CGRect(x:max(0,min(canvasSize.width-original.width,original.minX+p.x-origin.x)),y:max(0,min(canvasSize.height-original.height,original.minY+p.y-origin.y)),width:original.width,height:original.height)
            needsDisplay=true;return
        }
        if let anchor=cropAnchor {let p=canvasPoint(event);cropRect=CGRect(x:min(anchor.x,p.x),y:min(anchor.y,p.y),width:abs(p.x-anchor.x),height:abs(p.y-anchor.y));needsDisplay=true;return}
        guard var mark = current else { return }
        let p = canvasPoint(event)
        if mark.tool == .pen { mark.points.append(p) } else { mark.points[1] = p }
        current = mark; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if cropAnchor != nil || cropMoveOrigin != nil {cropAnchor=nil;cropMoveOrigin=nil;cropMoveRect=nil;needsDisplay=true;onStatus?("Adjust the crop by dragging its corners or centre. Return or Apply Crop confirms; Escape cancels.");return}
        guard let mark = current else { return }
        remember();marks.append(mark); current = nil; redoMarks.removeAll(); needsDisplay = true; onChange?()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36,hasPendingCrop {applyCrop();return}
        if event.keyCode == 53 {if hasPendingCrop || cropAnchor != nil {cancelCrop()}else{onEscape?()};return}
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }; return
        }
        let shortcuts: [String: DrawingTool] = ["p": .pen, "a": .arrow, "r": .rectangle, "o": .ellipse, "t": .text,"c": .crop]
        if let key = event.charactersIgnoringModifiers, let next = shortcuts[key] { tool = next; return }
        super.keyDown(with: event)
    }

    func finishStroke() {
        commitText()
        if let current {remember();marks.append(current);self.current=nil;needsDisplay=true;onChange?()}
    }
    private func erase(at point:CGPoint) {
        // Distance to a segment avoids erasing the empty interior of boxes and ovals.
        func distance(_ p:CGPoint,_ a:CGPoint,_ b:CGPoint)->CGFloat {
            let dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
            let t=length == 0 ? 0 : max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/length))
            return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)
        }
        guard let index=marks.lastIndex(where:{mark in
            guard let a=mark.points.first,let b=mark.points.last else{return false}
            let radius=max(8,mark.width+4)
            if mark.tool == .text {let size=(mark.text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:mark.fontSize,weight:.semibold)]);return CGRect(origin:a,size:size).insetBy(dx:-radius,dy:-radius).contains(point)}
            var points=mark.points
            if mark.tool == .rectangle {points=[a,CGPoint(x:b.x,y:a.y),b,CGPoint(x:a.x,y:b.y),a]}
            if mark.tool == .ellipse {let cx=(a.x+b.x)/2,cy=(a.y+b.y)/2;points=(0...64).map{let t=CGFloat($0)*2 * .pi/64;return CGPoint(x:cx+abs(b.x-a.x)/2*cos(t),y:cy+abs(b.y-a.y)/2*sin(t))}}
            return zip(points,points.dropFirst()).contains{distance(point,$0.0,$0.1)<=radius}
        }) else{return}
        remember();marks.remove(at:index);needsDisplay=true;onChange?()
    }
    private var snapshot:Snapshot {Snapshot(image:image,marks:marks,edited:editedImage)}
    private func remember(){undoStates.append(snapshot);if undoStates.count>20{undoStates.removeFirst()};redoStates=[]}
    private func restore(_ state:Snapshot){image=state.image;marks=state.marks;editedImage=state.edited;current=nil;needsDisplay=true;onChange?()}
    func undo(){commitText();if let state=undoStates.popLast(){redoStates.append(snapshot);restore(state)}}
    func redo(){if let state=redoStates.popLast(){undoStates.append(snapshot);restore(state)}}
    func clear(){commitText();remember();marks=[];current=nil;needsDisplay=true;onChange?()}
    func applyCrop(){guard let rect=cropRect else{return};cancelCrop();crop(to:rect)}
    func cancelCrop(){cropAnchor=nil;cropRect=nil;cropMoveOrigin=nil;cropMoveRect=nil;needsDisplay=true}
    func crop(to rect:CGRect){
        guard let image else{return}
        let clipped=rect.intersection(CGRect(origin:.zero,size:image.size))
        guard clipped.width>=8,clipped.height>=8 else{return}
        do{
            guard let flattened=NSImage(data:try renderedPNG()),let cg=flattened.cgImage(forProposedRect:nil,context:nil,hints:nil) else{return}
            let sx=CGFloat(cg.width)/image.size.width,sy=CGFloat(cg.height)/image.size.height
            let pixels=CGRect(x:clipped.minX*sx,y:(image.size.height-clipped.maxY)*sy,width:clipped.width*sx,height:clipped.height*sy).integral
            guard let cropped=cg.cropping(to:pixels) else{return}
            remember();self.image=NSImage(cgImage:cropped,size:clipped.size);marks=[];editedImage=true;needsDisplay=true;onChange?();onStatus?("Cropped. Command-Z undoes this change.")
        }catch{onStatus?("Crop failed; the image was kept unchanged.")}
    }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation { image == nil ? []:.copy }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        guard let urls=sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] else{return false}
        return combine(urls.compactMap{NSImage(contentsOf:$0)})
    }
    @discardableResult func combine(_ images:[NSImage])->Bool {
        guard !images.isEmpty,image != nil else{return false}
        do{
            guard let base=NSImage(data:try renderedPNG()) else{return false}
            let all=[base]+images
            let dimensions=all.compactMap{$0.cgImage(forProposedRect:nil,context:nil,hints:nil)}
            guard dimensions.count==all.count else{return false}
            let gap=16
            let width=combineHorizontal ? dimensions.reduce(0){$0+$1.width}+gap*(all.count-1):dimensions.map(\.width).max()!
            let height=combineHorizontal ? dimensions.map(\.height).max()!:dimensions.reduce(0){$0+$1.height}+gap*(all.count-1)
            guard width>0,height>0,width<=16000,height<=16000,width*height<=64000000,let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context=NSGraphicsContext(bitmapImageRep:bitmap) else{onStatus?("Combined image is too large; use fewer or smaller images.");return false}
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
            var offset=0
            for (n,img) in all.enumerated(){let cg=dimensions[n];let point=combineHorizontal ? CGPoint(x:offset,y:height-cg.height):CGPoint(x:0,y:height-offset-cg.height);img.draw(in:CGRect(origin:point,size:CGSize(width:cg.width,height:cg.height)));offset+=(combineHorizontal ? cg.width:cg.height)+gap}
            context.flushGraphics();NSGraphicsContext.restoreGraphicsState()
            guard let data=bitmap.representation(using:.png,properties:[:]),let result=NSImage(data:data) else{return false}
            remember();image=result;marks=[];editedImage=true;needsDisplay=true;onChange?();onStatus?("Images combined. Save or Export to keep the result; Command-Z undoes it.");return true
        }catch{onStatus?("Could not combine those images.");return false}
    }

    private func beginText(at point: CGPoint) {
        let r = canvasRect, s = canvasSize
        let p = CGPoint(x: r.minX + point.x * r.width / s.width, y: r.minY + point.y * r.height / s.height)
        let field = NSTextField(frame: CGRect(x: min(p.x, bounds.maxX - 240), y: max(0, p.y - 12), width: 240, height: 30))
        field.placeholderString = "Type a label, then Return"
        field.font = .systemFont(ofSize: min(32,textSize), weight: .semibold)
        field.textColor = color; field.backgroundColor = .white; field.isBordered = true
        field.delegate = self; field.target = self; field.action = #selector(commitText)
        entryPoint = point; entry = field; addSubview(field); window?.makeFirstResponder(field)
    }
    @objc private func commitText() {
        guard let entry else { return }
        let value = entry.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let point = entryPoint ?? .zero
        self.entry = nil; self.entryPoint = nil; entry.removeFromSuperview()
        onTextFinished?()
        if !value.isEmpty { remember();marks.append(DrawingMark(tool: .text, points: [point], color: color, width: effectiveWidth, text: value,fontSize:textSize * canvasSize.width / max(canvasRect.width,1))); redoMarks.removeAll(); onChange?() }
        needsDisplay = true
    }
    func controlTextDidEndEditing(_ obj: Notification) { commitText() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { entry?.removeFromSuperview(); entry = nil; entryPoint = nil; window?.makeFirstResponder(self);onTextFinished?();return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitText(); window?.makeFirstResponder(self); return true }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        if image != nil { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
        else { NSColor.black.withAlphaComponent(0.008).setFill(); bounds.fill() }
        let rect = canvasRect, size = canvasSize
        image?.draw(in: rect)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        (transform as NSAffineTransform).concat()
        let scale = NSAffineTransform(); scale.scaleX(by: rect.width / max(size.width, 1), yBy: rect.height / max(size.height, 1)); scale.concat()
        for mark in marks { drawMark(mark) }
        if let current { drawMark(current) }
        if let cropRect {
            let shade=NSBezierPath(rect:CGRect(origin:.zero,size:size));shade.appendRect(cropRect);shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill();shade.fill()
            NSColor.systemCyan.setStroke();let outline=NSBezierPath(rect:cropRect);let unit=size.width/max(rect.width,1);outline.lineWidth=2*unit;outline.stroke()
            NSColor.white.setFill()
            for p in [CGPoint(x:cropRect.minX,y:cropRect.minY),CGPoint(x:cropRect.maxX,y:cropRect.minY),CGPoint(x:cropRect.maxX,y:cropRect.maxY),CGPoint(x:cropRect.minX,y:cropRect.maxY)] {NSBezierPath(ovalIn:CGRect(x:p.x-4*unit,y:p.y-4*unit,width:8*unit,height:8*unit)).fill()}
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMark(_ mark: DrawingMark) {
        guard let a = mark.points.first else { return }
        let b = mark.points.last ?? a
        mark.color.setStroke(); mark.color.setFill()
        let path = NSBezierPath(); path.lineWidth = mark.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch mark.tool {
        case .pen:
            path.move(to: a); for p in mark.points.dropFirst() { path.line(to: p) }; path.stroke()
        case .arrow:
            path.move(to: a); path.line(to: b); path.stroke()
            let angle = atan2(b.y - a.y, b.x - a.x), head = max(14, mark.width * 4)
            let tip = NSBezierPath(); tip.move(to: b)
            tip.line(to: CGPoint(x: b.x - head * cos(angle - .pi / 6), y: b.y - head * sin(angle - .pi / 6)))
            tip.line(to: CGPoint(x: b.x - head * cos(angle + .pi / 6), y: b.y - head * sin(angle + .pi / 6)))
            tip.close(); tip.fill()
        case .rectangle, .ellipse:
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            let shape = mark.tool == .rectangle ? NSBezierPath(rect: r) : NSBezierPath(ovalIn: r)
            shape.lineWidth = mark.width; shape.stroke()
        case .crop, .eraser:break
        case .line:path.move(to:a);path.line(to:b);path.stroke()
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: mark.fontSize, weight: .semibold), .foregroundColor: mark.color]
            (mark.text as NSString).draw(at: a, withAttributes: attrs)
        }
    }

    func renderedPNG() throws -> Data {
        guard !hasPendingCrop else {throw NSError(domain:"CaptureTools",code:3,userInfo:[NSLocalizedDescriptionKey:"Apply or cancel the crop before saving, copying or exporting."])}
        commitText()
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "CaptureTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot render this screenshot"])
        }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let pixelSize = CGSize(width: cg.width, height: cg.height)
        image.draw(in: CGRect(origin: .zero, size: pixelSize))
        let scale = NSAffineTransform(); scale.scaleX(by: pixelSize.width / image.size.width, yBy: pixelSize.height / image.size.height); scale.concat()
        for mark in marks { drawMark(mark) }
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "CaptureTools", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode this screenshot"]) }
        return data
    }

    func flattenSavedImage(_ image: NSImage) { self.image = image; marks.removeAll(); redoMarks.removeAll();undoStates=[];redoStates=[];editedImage=false;needsDisplay = true }
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
        displayedTools=live ? DrawingTool.allCases.filter{$0 != .crop}:DrawingTool.allCases
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

@MainActor
private final class CaptureEditorController: NSWindowController, NSWindowDelegate {
    let item: CaptureItem
    private let surface: DrawingSurface
    private let toolbarController = DrawingToolbarController()
    private let statusLabel = NSTextField(labelWithString: "Double-click a tray thumbnail to open. Crop: drag, adjust, then Apply Crop. Drop images here to combine. Save updates this capture; Export saves a copy.")
    var onStatus: ((String) -> Void)?
    var onSaved: (() -> Void)?
    var onClose: (() -> Void)?

    init(item: CaptureItem, image: NSImage) {
        self.item = item
        surface = DrawingSurface(frame: CGRect(x: 0, y: 0, width: 1000, height: 680), image: image)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Annotate screenshot — Pico"
        window.minSize = CGSize(width: 800, height: 480); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window); window.delegate = self
        toolbarController.surfaces = [surface]; toolbarController.activeSurface = surface
        toolbarController.onSave = { [weak self] in self?.save() }
        toolbarController.onDone = { [weak self] in guard let self,self.save() else{return};self.close() }
        toolbarController.onSaveAs = { [weak self] in self?.export() }
        toolbarController.onCopy = { [weak self] in self?.copy() }
        surface.onEscape = { [weak self] in self?.window?.performClose(nil) }
        surface.onStatus = { [weak self] in self?.report($0) }
        surface.onChange = { [weak self] in self?.window?.isDocumentEdited = self?.surface.hasChanges ?? false }
        let toolbar = toolbarController.makeToolbar(live: false)
        let container = NSView()
        [toolbar, surface, statusLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; container.addSubview($0) }
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor), toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor), toolbar.heightAnchor.constraint(equalToConstant: 88),
            surface.topAnchor.constraint(equalTo: toolbar.bottomAnchor), surface.leadingAnchor.constraint(equalTo: container.leadingAnchor), surface.trailingAnchor.constraint(equalTo: container.trailingAnchor), surface.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16), statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16), statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        window.contentView = container; window.makeFirstResponder(surface)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func report(_ text: String) { statusLabel.stringValue = text; onStatus?(text) }
    @discardableResult private func save() -> Bool {
        do {
            let data = try surface.renderedPNG()
            try data.write(to: item.url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: item.url.path)
            if let image = NSImage(data: data) { surface.flattenSavedImage(image) }
            window?.isDocumentEdited = false; report("Edits saved to the local screenshot"); onSaved?(); return true
        } catch { report("Save failed: \(error.localizedDescription)"); return false }
    }
    private func export() {
        let panel = NSSavePanel();panel.directoryURL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"); panel.nameFieldStringValue = item.url.lastPathComponent; panel.allowedContentTypes = [.png]
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let target = panel.url else { return }
            do {
                try self.surface.renderedPNG().write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                self.onSaved?()
                self.report("Annotated screenshot exported")
            }
            catch { self.report("Export failed: \(error.localizedDescription)") }
        }
    }
    private func copy() {
        do {
            let data = try surface.renderedPNG()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png)
            if let image = NSImage(data: data), let tiff = image.tiffRepresentation { NSPasteboard.general.setData(tiff, forType: .tiff) }
            report("Annotated screenshot copied")
        } catch { report("Copy failed: \(error.localizedDescription)") }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard surface.hasChanges else { return true }
        let alert = NSAlert(); alert.messageText = "Save the screenshot annotations?"; alert.informativeText = "Your original screenshot is already stored locally."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard edits"); alert.addButton(withTitle: "Keep editing")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { return save() }
        return response == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
