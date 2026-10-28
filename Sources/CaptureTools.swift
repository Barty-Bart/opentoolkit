import AppKit
import SwiftUI
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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
    private var selectionWindows: [CaptureSelectionPanel] = []
    private var annotationWindows: [ToolOverlayWindow] = []
    private var liveSurfaces: [DrawingSurface] = []
    private var drawingOwner: NSRunningApplication?
    private var heldDrawingTool: String?
    /// Started from the Draw on Screen key or palette: tool-key releases don't end it.
    private var stickyDrawing = false
    /// Tool shortcuts are global hotkeys, so they exist only while drawing is on.
    var onDrawingActiveChanged: ((Bool) -> Void)?
    /// While a capture selection is on screen (the app registers a temporary Escape shortcut).
    var onSelectionActive: ((Bool) -> Void)?
    var isDrawingActive: Bool { heldDrawingTool != nil }
    /// Remembered screen-drawing colour (Annotation page swatches, palette and colour keys).
    private var annotationColor: NSColor { get { AnnotationColor.saved } set { AnnotationColor.save(newValue) } }
    private var palette: NSPanel?
    private var paletteController: DrawingToolbarController?
    private var previewPanels:[UUID:NSPanel]=[:]
    private var recentPanel:NSPanel?
    private var selectionMonitors:[Any]=[]
    private var selectionPoll:Timer?
    private var hiddenPinned:[NSPanel]=[]
    private var previewsHidden=false
    private var pinnedPreviews:[NSPanel]=[]
    private var editors: [CaptureEditorController] = []
    /// The app you were in when an editor opened; closing the last editor returns there.
    private var appBeforeEditing: NSRunningApplication?
    /// The display holding the thumbnail stack; it follows the pointer between displays.
    private var trayScreen: NSScreen?
    /// The within-display tidy slide takes 0.22 s; moving to another display takes about half a second longer.
    static let trayGlideDuration: TimeInterval = 0.72
    private var trayFollow: Timer?
    var hasOpenEditor: Bool { editors.contains { $0.window?.isVisible == true } }
    private var captureInFlight = false
    /// Usage-log kind of the capture in flight; full screen and area share the capture path.
    private var captureKind = "capture_area"
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
        cancel();captureKind="capture_full";finishSelection(screen.frame)
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
        captureKind = "capture_area"
        hideCapturePreviews()
        selectionGeneration += 1
        let generation = selectionGeneration
        report(fixedSize == nil ? "Drag an area to capture · Escape to cancel" : "Move the fixed frame, then click or drag to capture · Escape to cancel")
        let state = SelectionState(fixedSize: fixedSize)
        for screen in NSScreen.screens {
            let window = CaptureSelectionPanel(frame: screen.frame)
            let selector = RegionSelectionView(frame: window.contentView!.bounds, state: state)
            selector.onCancel = { [weak self] in self?.cancel() }
            selector.onComplete = { [weak self] global in
                guard let self, self.selectionGeneration == generation else { return }
                self.finishSelection(global)
            }
            window.contentView = selector
            // Shown without taking keyboard focus, so your app's text box keeps it and the
            // first click after the capture lands there (e.g. to drop the screenshot in).
            window.orderFrontRegardless()
            selectionWindows.append(window)
        }
        onSelectionActive?(true)
        // The real pointer becomes the coloured crosshair, so nothing trails behind it.
        // Push the coloured crosshair once and pop it when the selection closes. Setting the cursor
        // again on every move (0.3.9–0.3.14) could leave it stuck as a crosshair after the capture.
        CaptureCrosshair.begin()
        // Follow the pointer onto any display; that display's overlay takes Escape.
        let follow: () -> Void = { [weak self, weak state] in
            // Pointer events queued before the selection closed must not bring the crosshair back.
            guard let self, let state, !self.selectionWindows.isEmpty, self.selectionGeneration == generation else { return }
            let p = NSEvent.mouseLocation
            state.moved(to: p)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in Task { @MainActor in follow() } }) { selectionMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in follow(); return event }) { selectionMonitors.append(local) }
        // Backstop: poll the pointer so the crosshair always follows, even if no event reaches us.
        var last = NSEvent.mouseLocation
        selectionPoll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            Task { @MainActor in let p = NSEvent.mouseLocation; if p != last { last = p; follow() } }
        }
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
                        CaptureSound.play()
                        UsageLog.shared?.record(self.captureKind)
                        self.showTray()
                        self.report("Screenshot ready · drag the thumbnail into an app, or double-click to edit")
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
        let wasDrawing = heldDrawingTool != nil
        annotationWindows.removeAll(); liveSurfaces.removeAll();heldDrawingTool=nil;drawingOwner=nil;stickyDrawing=false
        palette?.orderOut(nil); palette?.close(); palette = nil; paletteController = nil
        if wasDrawing { onDrawingActiveChanged?(false) }
        if !captureInFlight {previewsHidden=false;showTray();report("Ready to capture") }
    }

    private func closeSelection() {
        selectionMonitors.forEach { NSEvent.removeMonitor($0) }; selectionMonitors = []
        selectionPoll?.invalidate(); selectionPoll = nil
        let hadSelection = !selectionWindows.isEmpty
        for window in selectionWindows { window.orderOut(nil); window.close() }
        selectionWindows.removeAll()
        // The crosshair was set directly as well as pushed, so restore the arrow explicitly.
        if hadSelection { CaptureCrosshair.end(); onSelectionActive?(false) }
    }

    func endDrawing() {
        liveSurfaces.forEach { $0.finishStroke() }
        annotationWindows.forEach { $0.ignoresMouseEvents = true }
        palette?.orderOut(nil)
        let wasDrawing = heldDrawingTool != nil
        heldDrawingTool = nil; stickyDrawing = false
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            drawingOwner?.activate(options: [])
        }
        if wasDrawing { onDrawingActiveChanged?(false) }
        report("Annotations stay visible · use Clear to erase")
    }

    func releaseDrawing(_ name: String) {
        guard !stickyDrawing, heldDrawingTool == name else { return }
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
                surface.onTextFinished={ [weak self] in DispatchQueue.main.async {if self?.heldDrawingTool == "text" && self?.stickyDrawing == false {self?.endDrawing()}} }
                surface.onActivity={ [weak controller,weak surface] in controller?.activeSurface=surface }
                window.contentView=surface
                annotationWindows.append(window);liveSurfaces.append(surface)
            }
            controller.surfaces=liveSurfaces;controller.activeSurface=liveSurfaces.first
            controller.onDone={ [weak self] in self?.endDrawing() }
            paletteController=controller
        }
        let wasDrawing = heldDrawingTool != nil
        heldDrawingTool=name
        if !wasDrawing { onDrawingActiveChanged?(true) }
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

    func annotateScreen() {
        guard !captureInFlight else { return }
        stickyDrawing = true; beginDrawing("pen",showPalette:true)
    }

    func openEditor(_ item: CaptureItem) {
        if let existing = editors.first(where: { $0.item.url == item.url }) { existing.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let image = NSImage(contentsOf: item.url) else { report("This capture is no longer available."); return }
        if editors.isEmpty, let front = NSWorkspace.shared.frontmostApplication, front != .current { appBeforeEditing = front }
        let editor = CaptureEditorController(item: item, image: image)
        editor.onStatus = { [weak self] text in self?.report(text) }
        editor.onSaved = { [weak self] in self?.keep(item); self?.showTray() }
        editor.onClose = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.editors.removeAll { $0 === editor }
            // Hand focus back before AppKit promotes the dashboard to key window.
            if self.editors.isEmpty, let previous = self.appBeforeEditing, !previous.isTerminated { previous.activate(options: []) }
            if self.editors.isEmpty { self.appBeforeEditing = nil }
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
        UsageLog.shared?.record("editor_export")
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
        panel.allowedContentTypes = [UTType(filenameExtension: item.url.pathExtension) ?? .png]
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
                UsageLog.shared?.record("editor_export")
                self.report("Screenshot saved")
            } catch { self.report("Save failed: \(error.localizedDescription)") }
        }
    }

    func isKept(_ item:CaptureItem)->Bool {index.kept(name:item.url.lastPathComponent)}
    func keep(_ item:CaptureItem){if index.keep(name:item.url.lastPathComponent){objectWillChange.send();report("Screenshot kept — it will not expire")}else{report("Could not update screenshot history; cleanup stays conservative")}}
    func setRetention(_ hours:Int){guard [0,1,24,168,720].contains(hours) else{return};retentionHours=hours;UserDefaults.standard.set(hours,forKey:"captureRetentionHours");cleanupExpired()}
    func cleanupExpired(now:Date = Date()){
        let trayBefore=trayItems.map(\.id)
        for item in captures where index.expired(name:item.url.lastPathComponent,date:item.date,hours:retentionHours,now:now){
            guard !editors.contains(where:{$0.item.url==item.url}),item.url.deletingLastPathComponent().standardizedFileURL==folder.standardizedFileURL else{continue}
            do{try FileManager.default.trashItem(at:item.url,resultingItemURL:nil);index.remove(name:item.url.lastPathComponent);captures.removeAll{$0.id==item.id};trayItems.removeAll{$0.id==item.id}}
            catch{report("Could not move an expired capture to Trash; it was retained")}
        }
        // Rebuilding unchanged previews every minute drops their hover controls.
        guard trayItems.map(\.id) != trayBefore else{return}
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
        hideRecentHistory()
        pinnedPreviews.forEach{$0.orderOut(nil)}
    }
    var onShowAllHistory:(()->Void)?
    private var recentOutsideMonitor:Any?
    /// CleanShot-style history: a glass bar slides down across the top of the screen.
    func showRecentHistory() {
        guard !captureInFlight,selectionWindows.isEmpty else{return}
        if recentPanel?.isVisible == true {hideRecentHistory();return}
        let screen=NSScreen.screens.first{NSMouseInRect(NSEvent.mouseLocation,$0.frame,false)} ?? NSScreen.main ?? NSScreen.screens.first
        let visible=screen?.visibleFrame ?? CGRect(x:0,y:0,width:1000,height:800)
        let height:CGFloat=176
        let host=NSHostingView(rootView:RecentCaptureStrip(coordinator:self,onClose:{[weak self] in self?.hideRecentHistory()},onShowAll:{[weak self] in self?.hideRecentHistory();self?.onShowAllHistory?()}))
        let panel=CaptureBarPanel(content:host);panel.onCancel={[weak self] in self?.hideRecentHistory()}
        let frame=CGRect(x:visible.minX+12,y:visible.maxY-height-8,width:visible.width-24,height:height)
        panel.setFrame(frame.offsetBy(dx:0,dy:height),display:false);panel.alphaValue=0
        panel.makeKeyAndOrderFront(nil);recentPanel=panel
        NSAnimationContext.runAnimationGroup{context in context.duration=0.18;panel.animator().setFrame(frame,display:true);panel.animator().alphaValue=1}
        // A click anywhere else closes it, like a menu.
        recentOutsideMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]){[weak self] _ in Task{@MainActor in self?.hideRecentHistory()}}
    }
    func hideRecentHistory(){
        if let monitor=recentOutsideMonitor {NSEvent.removeMonitor(monitor);recentOutsideMonitor=nil}
        recentPanel?.orderOut(nil);recentPanel=nil
    }
    private func showTray() {
        guard !captureInFlight,selectionWindows.isEmpty else{return}
        previewsHidden=false
        hiddenPinned.forEach{$0.orderFrontRegardless()};hiddenPinned=[]
        let pointerScreen=NSScreen.screens.first{NSMouseInRect(NSEvent.mouseLocation,$0.frame,false)}
        let movedScreen=trayScreen != nil && pointerScreen != nil && pointerScreen != trayScreen
        if let pointerScreen {trayScreen=pointerScreen}
        let visible=(trayScreen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x:0,y:0,width:1000,height:800)
        let count=max(1,Int((visible.height-36)/140))
        let visibleItems=Array(trayItems.prefix(count))
        let ids=Set(visibleItems.map(\.id))
        for (id,panel) in previewPanels where !ids.contains(id) {panel.orderOut(nil);previewPanels.removeValue(forKey:id)}
        for (i,item) in visibleItems.enumerated() {
            let panel=previewPanels[item.id] ?? NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true;panel.level = .floating;panel.hidesOnDeactivate=false
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            let interaction=CapturePreviewInteraction(panel:panel)
            let menu=previewMenu(item);menu.delegate=interaction;interaction.menu=menu
            let host=NSHostingView(rootView:CaptureTrayCard(coordinator:self,item:item,interaction:interaction,contextMenu:menu).padding(5).background(Color(red:0.10,green:0.12,blue:0.15),in:RoundedRectangle(cornerRadius:14)))
            // AppKit owns menu tracking, including clicks on the preview's padding
            // or action controls. SwiftUI contextMenu can get stuck on a panel
            // that deliberately never activates the app.
            host.menu=menu;panel.contentView=host
            let frame=CGRect(x:visible.minX+18,y:visible.minY+18+CGFloat(visibleItems.count-1-i)*140,width:200,height:128)
            // Slide existing previews into their new slot so a removed one reads as the stack tidying up.
            // Following the pointer to another display glides more slowly, so the stack is easy to track.
            if panel.isVisible && panel.frame != frame {NSAnimationContext.runAnimationGroup{context in context.duration=movedScreen ? Self.trayGlideDuration:0.22;context.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut);panel.animator().setFrame(frame,display:true)}}
            else {panel.setFrame(frame,display:true)}
            panel.orderFrontRegardless();previewPanels[item.id]=panel
        }
        followPointerWithTray()
    }

    /// Move the thumbnail stack to whichever display the pointer is on, as CleanShot does.
    /// Waits while a mouse button is down so a drag out of the stack is never interrupted.
    private func followPointerWithTray() {
        guard !previewPanels.isEmpty else {trayFollow?.invalidate();trayFollow=nil;return}
        guard trayFollow == nil else{return}
        trayFollow=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in
            Task{@MainActor in
                guard let self,!self.previewsHidden,NSEvent.pressedMouseButtons == 0,
                      let screen=NSScreen.screens.first(where:{NSMouseInRect(NSEvent.mouseLocation,$0.frame,false)}),
                      screen != self.trayScreen else{return}
                self.showTray()
            }
        }
    }

    private func previewMenu(_ item:CaptureItem)->NSMenu {
        let menu=NSMenu()
        func add(_ title:String,_ action:@escaping ()->Void){
            let handler=CapturePreviewMenuAction(action)
            let entry=NSMenuItem(title:title,action:#selector(CapturePreviewMenuAction.invokeAction),keyEquivalent:"")
            entry.target=handler;entry.representedObject=handler;menu.addItem(entry)
        }
        add("Edit"){[weak self] in self?.openEditor(item)}
        add("Copy"){[weak self] in self?.copy(item)}
        add("Keep"){[weak self] in self?.keep(item)}
        add("Save to…"){[weak self] in self?.saveAs(item)}
        add("Show in Finder"){[weak self] in self?.reveal(item)}
        add("Hide preview"){[weak self] in self?.dismiss(item)}
        return menu
    }

}

private final class CapturePreviewMenuAction:NSObject {
    private let action:()->Void
    init(_ action:@escaping ()->Void){self.action=action}
    @objc func invokeAction(){action()}
}

/// Mouse-only monitors require no new permission and never swallow the click.
/// They clear temporary thumbnail controls when the user returns to another app.
private final class CapturePreviewInteraction:NSObject,ObservableObject,NSMenuDelegate {
    @Published var hovering=false
    weak var menu:NSMenu?
    private weak var panel:NSPanel?
    private var menuTracking=false
    private var outsideMonitor:Any?
    private var localMonitor:Any?
    init(panel:NSPanel){
        self.panel=panel;super.init()
        let clicks:NSEvent.EventTypeMask=[.leftMouseDown,.rightMouseDown,.otherMouseDown]
        outsideMonitor=NSEvent.addGlobalMonitorForEvents(matching:clicks){[weak self] _ in self?.dismissActions()}
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:clicks){[weak self] event in
            // While the native menu tracks, let AppKit deliver menu-item clicks
            // and dismiss clicks itself. A global click explicitly cancels it.
            if let self,!self.menuTracking,event.window !== self.panel {self.dismissActions()}
            return event
        }
    }
    deinit {
        menu?.cancelTracking()
        if let outsideMonitor {NSEvent.removeMonitor(outsideMonitor)}
        if let localMonitor {NSEvent.removeMonitor(localMonitor)}
    }
    func dismissActions(){menu?.cancelTracking();hovering=false}
    func menuWillOpen(_ menu:NSMenu){menuTracking=true;hovering=false}
    func menuDidClose(_ menu:NSMenu){menuTracking=false;hovering=false}
}

private struct RecentCaptureStrip:View {
    @ObservedObject var coordinator:CaptureCoordinator
    let onClose:()->Void
    let onShowAll:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("Recent screenshots").font(.headline)
                Text("Click to bring one back · drag into any app").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show all…",action:onShowAll).controlSize(.small)
                Button(action:onClose){Image(systemName:"xmark").font(.system(size:12,weight:.semibold))}.buttonStyle(.plain).help("Close (Escape)")
            }
            if coordinator.captures.isEmpty {Spacer();Text("Your screenshots will appear here.").foregroundStyle(.secondary).frame(maxWidth:.infinity);Spacer()}
            else {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:12) {ForEach(Array(coordinator.captures.prefix(12))){item in
                        VStack(spacing:4){
                            CaptureDragPreview(url:item.url,onClick:{coordinator.restorePreview(item);onClose()},onOpen:{coordinator.openEditor(item);onClose()},onDropped:onClose)
                                .frame(width:170,height:106).background(.black.opacity(0.25),in:RoundedRectangle(cornerRadius:8))
                                .contextMenu{Button("Edit"){coordinator.openEditor(item);onClose()};Button("Bring back to screen"){coordinator.restorePreview(item);onClose()};Button("Save as…"){coordinator.saveAs(item);onClose()}}
                            Text(item.date,style:.relative).font(.system(size:10)).foregroundStyle(.secondary)
                        }
                    }}.padding(.vertical,2)
                }
            }
        }.padding(.horizontal,16).padding(.vertical,12).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}
private struct CaptureTrayCard:View {
    @ObservedObject var coordinator:CaptureCoordinator
    let item:CaptureItem
    @ObservedObject var interaction:CapturePreviewInteraction
    let contextMenu:NSMenu
    var body:some View {
        ZStack(alignment:.bottom){
            // Like CleanShot: a click opens the editor, a drag drops the file into another app.
            CaptureDragPreview(url:item.url,onOpen:{coordinator.openEditor(item)},onDropped:{coordinator.dismiss(item)},contextMenu:contextMenu)
                .frame(width:190,height:118).background(Color.black.opacity(0.2))
            if interaction.hovering {
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
                        corner("folder",help:"Show in Finder"){coordinator.reveal(item)}
                    }
                }.padding(7)
            }
        }.frame(width:190,height:118).clipShape(RoundedRectangle(cornerRadius:10)).onHover{interaction.hovering=$0}
        .help("Double-click to open · drag to another app · hover for actions · right-click for menu")
    }
    private func corner(_ symbol:String,help:String,action:@escaping()->Void)->some View {
        Button(action:action){Image(systemName:symbol).font(.system(size:9,weight:.bold)).foregroundStyle(.black.opacity(0.8)).frame(width:19,height:19).background(.white.opacity(0.85),in:Circle())}.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

}

/// Capture must not activate the app and raise its dashboard or an existing editor.
/// A nonactivating panel can receive Escape while the user's app stays active.
private final class CaptureSelectionPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear
        hasShadow = false; acceptsMouseMovedEvents = true; hidesOnDeactivate = false
        // The overlay is fully transparent; without this AppKit passes clicks to the app below.
        ignoresMouseEvents = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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

/// One selection shared by every display's overlay, in global screen coordinates, so the
/// crosshair follows the pointer onto any monitor and a drag can span monitors.
@MainActor
fileprivate final class SelectionState {
    let fixedSize: CGSize?
    var pointer: CGPoint? = NSEvent.mouseLocation
    var anchor: CGPoint?
    var selection: CGRect?
    var views: [RegionSelectionView] = []
    init(fixedSize: CGSize?) { self.fixedSize = fixedSize }
    func refresh() { views.forEach { $0.needsDisplay = true } }
    private func fixedRect(at p: CGPoint) -> CGRect {
        let screen = (NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main)?.frame ?? .zero
        let width = min(screen.width, max(10, fixedSize?.width ?? 640)), height = min(screen.height, max(10, fixedSize?.height ?? 360))
        return CGRect(x: min(screen.maxX - width, max(screen.minX, p.x - width / 2)), y: min(screen.maxY - height, max(screen.minY, p.y - height / 2)), width: width, height: height)
    }
    func moved(to p: CGPoint) { pointer = p; if fixedSize != nil, anchor == nil { selection = fixedRect(at: p) }; refresh() }
    func began(at p: CGPoint) { anchor = p; pointer = p; selection = fixedSize == nil ? CGRect(origin: p, size: .zero) : fixedRect(at: p); refresh() }
    func dragged(to p: CGPoint) {
        guard let anchor else { return }
        pointer = p
        selection = fixedSize == nil ? CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y)) : fixedRect(at: p)
        refresh()
    }
}

@MainActor
fileprivate final class RegionSelectionView: NSView {
    let state: SelectionState
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    private var tracking: NSTrackingArea?
    init(frame: CGRect, state: SelectionState) { self.state = state; super.init(frame: frame); state.views.append(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // Without this, a display's overlay never hears the pointer arrive while another app is active.
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { guard window?.isVisible == true else { return }; CaptureCrosshair.reassert(); state.moved(to: NSEvent.mouseLocation) }
    // The overlay never becomes key, so it must take the very first click itself.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// This display's frame in global coordinates; drawing converts global points into it.
    private var screenFrame: CGRect { window?.frame ?? .zero }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY) }
    // Global pointer positions keep working when a drag leaves this display.
    override func mouseMoved(with event: NSEvent) { CaptureCrosshair.reassert(); state.moved(to: NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) { state.began(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { state.dragged(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { if let selection = state.selection { onComplete?(selection) } }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) } }
    /// Coordinates beside the pointer. The crosshair itself is the system cursor
    /// (`CaptureCrosshair.cursor()`), so it never lags behind the pointer.
    private func drawCrosshair(at p: CGPoint) {
        let x = p.x.rounded() + 0.5, y = p.y.rounded() + 0.5
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let global = CGPoint(x: screenFrame.minX + p.x, y: screenFrame.minY + p.y)
        let label = "\(Int(global.x)), \(Int(primaryTop - global.y))"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.65)]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: CGPoint(x: min(x + 14, bounds.maxX - size.width - 4), y: max(4, y - size.height - 14)), withAttributes: attrs)
    }
    override func draw(_ dirtyRect: NSRect) {
        // Keep the screen at its normal brightness. Only the selection outline,
        // the small crosshair and compact help labels are drawn over the underlying app.
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        let pointerHere = state.pointer.map { NSMouseInRect($0, screenFrame, false) } ?? false
        if state.fixedSize == nil, state.anchor == nil, pointerHere, let p = state.pointer { drawCrosshair(at: local(p)) }
        if let global = state.selection, global.width > 0, global.height > 0 {
            let selection = global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            let outline = NSBezierPath(rect: selection)
            NSColor.black.withAlphaComponent(0.75).setStroke(); outline.lineWidth = 3; outline.stroke()
            NSColor.white.setStroke(); outline.lineWidth = 1; outline.stroke()
            // The size label sits once, on the display holding the selection's bottom-left corner.
            if NSMouseInRect(CGPoint(x: global.minX + 1, y: global.minY + 1), screenFrame, false) {
                let label = "\(Int(global.width)) × \(Int(global.height)) pt"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.7)]
                (label as NSString).draw(at: CGPoint(x: selection.minX + 5, y: max(5, selection.minY - 23)), withAttributes: attrs)
            }
        }
        guard pointerHere || state.pointer == nil else { return }
        let hint = state.fixedSize == nil ? "Drag to select an area • You can drag across displays • Escape cancels" : "Move the frame • Click or drag to capture • Escape cancels"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = (hint as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 54)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -12, dy: -7), xRadius: 9, yRadius: 9).fill()
        (hint as NSString).draw(at: origin, withAttributes: attrs)
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
    @objc private func changeColor(_ sender: NSPopUpButton) { let color = colors[max(0, sender.indexOfSelectedItem)].1; AnnotationColor.save(color); surfaces.forEach { $0.color = color } }
    @objc private func customColor(_ sender:NSColorWell){AnnotationColor.save(sender.color);surfaces.forEach{$0.color=sender.color}}
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

/// Colour of the drawn capture crosshair (Screenshots › Settings).
enum CaptureCrosshair {
    static let options: [(name: String, color: NSColor)] = [("Cyan", .systemTeal), ("Yellow", .systemYellow), ("Pink", .systemPink), ("Green", .systemGreen), ("Orange", .systemOrange), ("White", .white)]
    static var color: NSColor {
        let name = UserDefaults.standard.string(forKey: "captureCrosshairColor") ?? "Cyan"
        return options.first { $0.name == name }?.color ?? .systemTeal
    }
    /// A small crosshair cursor in the chosen colour with a dark outline, hot spot at its centre.
    static func cursor(color: NSColor = color) -> NSCursor {
        let size: CGFloat = 25, c = size / 2, arm: CGFloat = 11, gap: CGFloat = 3
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let mark = NSBezierPath()
            for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
                mark.move(to: CGPoint(x: c + dx * gap, y: c + dy * gap)); mark.line(to: CGPoint(x: c + dx * arm, y: c + dy * arm))
            }
            mark.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.6).setStroke(); mark.lineWidth = 4; mark.stroke()
            color.setStroke(); mark.lineWidth = 2; mark.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: c, y: c))
    }

    /// The crosshair while a selection is on screen, nil otherwise.
    private static var active: NSCursor?
    /// Show the crosshair for a selection. The overlay never takes focus (0.3.18), and macOS
    /// ignores cursor changes from an app that isn't in front, so the pointer stayed an arrow.
    /// Allow this app to set the cursor from the background first.
    static func begin() {
        allowCursorInBackground()
        let cursor = cursor(); active = cursor; cursor.push()
    }
    static func end() { guard active != nil else { return }; active = nil; NSCursor.pop() }
    /// The app in front may set its own cursor again; the overlay puts the crosshair back on move.
    static func reassert() { if let active, NSCursor.current !== active { active.set() } }

    private static var backgroundCursorAllowed = false
    private static func allowCursorInBackground() {
        guard !backgroundCursorAllowed else { return }
        backgroundCursorAllowed = true
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let handle = dlopen(nil, RTLD_NOW)
        guard let connection = dlsym(handle, "_CGSDefaultConnection"), let setProperty = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(connection, to: DefaultConnection.self)()
        _ = unsafeBitCast(setProperty, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

enum AnnotationColor {
    static let swatches: [(name: String, color: NSColor)] = [("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow), ("Green", .systemGreen), ("Blue", .systemBlue), ("Pink", .systemPink), ("Purple", .systemPurple), ("White", .white), ("Black", .black)]
    static var saved: NSColor {
        let parts = (UserDefaults.standard.string(forKey: "annotationColor") ?? "").split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return .systemOrange }
        return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
    }
    static func save(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        UserDefaults.standard.set([c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { String(format: "%.4f", $0) }.joined(separator: ","), forKey: "annotationColor")
    }
}

/// macOS's own screenshot shutter sound, on by default (Screenshots › Settings).
enum CaptureSound {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "captureSound") as? Bool ?? true }
    private static let sound = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)
    static func play() { guard enabled else { return }; sound?.stop(); sound?.play() }
}
