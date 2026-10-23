import AppKit
import UniformTypeIdentifiers

/// A drag exports the current rendering, including unsaved annotations, as a private PNG.
@MainActor
final class CaptureExportHandle: NSView, NSDraggingSource {
    var render: (() throws -> Data)?
    var onStatus: ((String) -> Void)?
    private var dragging = false
    override var intrinsicContentSize: NSSize { NSSize(width: 116, height: 28) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ rect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        let text = "⠿  Drag image  ⠿" as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) { dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let render else { return }
        do {
            let data = try render()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OpenToolkit-Editor-Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Only remove this editor's expired temporary exports, never saved user files.
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                if file.lastPathComponent.hasPrefix("Edited-"), let date = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate, Date().timeIntervalSince(date) > 86400 { try? FileManager.default.removeItem(at: file) }
            }
            let url = folder.appendingPathComponent("Edited-\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: NSImage(data: data))
            dragging = true
            beginDraggingSession(with: [item], event: event, source: self)
            onStatus?("Dragging the edited PNG. Your original capture stays in history.")
        } catch { onStatus?(error.localizedDescription) }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

@MainActor
final class CaptureEditorController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let item: CaptureItem
    let surface: DrawingSurface
    private let scroll = NSScrollView()
    private let toolPicker = NSSegmentedControl()
    private let zoomPicker = NSPopUpButton()
    private let cropActions = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pinButton = NSButton()
    private var viewportObserver: NSObjectProtocol?
    private let editorTools: [(DrawingTool, String)] = [(.select,"cursorarrow"),(.crop,"crop"),(.pen,"pencil.tip"),(.line,"line.diagonal"),(.arrow,"arrow.up.right"),(.rectangle,"rectangle"),(.filledRectangle,"rectangle.fill"),(.ellipse,"circle"),(.text,"textformat"),(.highlighter,"highlighter"),(.number,"1.circle"),(.redact,"rectangle.inset.filled"),(.eraser,"eraser")]
    var onStatus: ((String) -> Void)?
    var onSaved: (() -> Void)?
    var onClose: (() -> Void)?

    init(item: CaptureItem, image: NSImage) {
        self.item = item
        surface = DrawingSurface(frame: NSRect(x: 0, y: 0, width: 1000, height: 650), image: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Screenshot — OpenToolkit"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 820, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        surface.tool = .select
        surface.onEscape = { [weak self] in self?.window?.performClose(nil) }
        surface.onStatus = { [weak self] in self?.report($0) }
        surface.onChange = { [weak self] in self?.changed() }
        surface.onToolChange = { [weak self] in self?.syncTools() }
        let toolbar = NSToolbar(identifier: "OpenToolkit.CaptureEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        makeContent(window)
        window.makeFirstResponder(surface)
        syncTools()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) } }

    private func iconButton(_ symbol: String, _ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: selector)
        button.bezelStyle = .texturedRounded
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }
    private func makeContent(_ window: NSWindow) {
        let container = NSView()
        window.contentView = container
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = surface
        scroll.contentView.postsBoundsChangedNotifications = true
        viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutCanvas() }
        }
        let footer = NSVisualEffectView()
        footer.material = .headerView; footer.blendingMode = .withinWindow; footer.state = .active
        zoomPicker.addItems(withTitles: ["Fit", "25%", "50%", "75%", "100%", "150%", "200%"])
        zoomPicker.target = self; zoomPicker.action = #selector(changeZoom)
        zoomPicker.toolTip = "Canvas zoom — exported image keeps its original resolution"
        let drag = CaptureExportHandle()
        drag.render = { [weak self] in guard let self else { throw CocoaError(.fileReadUnknown) }; return try self.surface.renderedPNG() }
        drag.onStatus = { [weak self] in self?.report($0) }
        drag.setAccessibilityLabel("Drag edited image into another app")
        let share = iconButton("square.and.arrow.up", "Share edited screenshot", #selector(shareImage(_:)))
        let copy = iconButton("doc.on.doc", "Copy edited screenshot", #selector(copyImage))
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Keep editor on top")
        pinButton.bezelStyle = .texturedRounded; pinButton.setButtonType(.toggle)
        pinButton.target = self; pinButton.action = #selector(togglePin)
        pinButton.toolTip = "Keep editor on top"; pinButton.setAccessibilityLabel("Keep editor on top")
        let more = iconButton("ellipsis.circle", "More image actions", #selector(moreActions(_:)))
        let right = NSStackView(views: [share,pinButton,copy,more]); right.spacing = 6
        let apply = NSButton(title: "Apply crop", target: self, action: #selector(applyCrop))
        apply.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCrop))
        cancel.bezelStyle = .rounded
        cropActions.addArrangedSubview(apply);cropActions.addArrangedSubview(cancel);cropActions.spacing=6;cropActions.isHidden=true
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        for view in [scroll,footer] { view.translatesAutoresizingMaskIntoConstraints=false;container.addSubview(view) }
        for view in [zoomPicker,drag,right,cropActions,statusLabel] { view.translatesAutoresizingMaskIntoConstraints=false;footer.addSubview(view) }
        let guide = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),scroll.leadingAnchor.constraint(equalTo:container.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:container.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:footer.topAnchor),
            footer.heightAnchor.constraint(equalToConstant:50),footer.leadingAnchor.constraint(equalTo:container.leadingAnchor),footer.trailingAnchor.constraint(equalTo:container.trailingAnchor),footer.bottomAnchor.constraint(equalTo:container.bottomAnchor),
            zoomPicker.leadingAnchor.constraint(equalTo:footer.leadingAnchor,constant:12),zoomPicker.centerYAnchor.constraint(equalTo:footer.centerYAnchor),zoomPicker.widthAnchor.constraint(equalToConstant:84),
            drag.centerXAnchor.constraint(equalTo:footer.centerXAnchor),drag.centerYAnchor.constraint(equalTo:footer.centerYAnchor),drag.widthAnchor.constraint(equalToConstant:116),drag.heightAnchor.constraint(equalToConstant:28),
            right.trailingAnchor.constraint(equalTo:footer.trailingAnchor,constant:-12),right.centerYAnchor.constraint(equalTo:footer.centerYAnchor),
            cropActions.leadingAnchor.constraint(equalTo:zoomPicker.trailingAnchor,constant:12),cropActions.centerYAnchor.constraint(equalTo:footer.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo:zoomPicker.trailingAnchor,constant:12),statusLabel.trailingAnchor.constraint(lessThanOrEqualTo:drag.leadingAnchor,constant:-16),statusLabel.centerYAnchor.constraint(equalTo:footer.centerYAnchor)
        ])
        container.layoutSubtreeIfNeeded();layoutCanvas()
    }
    func windowDidResize(_ notification: Notification) { layoutCanvas() }
    private func layoutCanvas() {
        let viewport=scroll.contentView.bounds.size
        let size=surface.image?.size ?? viewport
        let factor=surface.zoomScale
        let desired=NSSize(width:max(viewport.width,factor.map{size.width*$0+40} ?? 0),height:max(viewport.height,factor.map{size.height*$0+40} ?? 0))
        if surface.frame.size != desired {surface.setFrameSize(desired)}
        surface.needsDisplay=true
    }
    private func changed() { window?.isDocumentEdited=surface.hasChanges;cropActions.isHidden = !surface.hasPendingCrop;statusLabel.isHidden=surface.hasPendingCrop;layoutCanvas() }
    private func syncTools() { toolPicker.selectedSegment=editorTools.firstIndex(where:{$0.0==surface.tool}) ?? 0 }
    private func report(_ text: String) { statusLabel.stringValue=text;statusLabel.toolTip=text;onStatus?(text) }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ["tools","color","width","textSize","undo","redo"].map{NSToolbarItem.Identifier($0)} + [.flexibleSpace] + ["saveAs","done"].map{NSToolbarItem.Identifier($0)} }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item=NSToolbarItem(itemIdentifier:id)
        switch id.rawValue {
        case "tools":
            toolPicker.segmentCount=editorTools.count;toolPicker.trackingMode = .selectOne;toolPicker.segmentStyle = .rounded
            for (index,entry) in editorTools.enumerated() {toolPicker.setImage(NSImage(systemSymbolName:entry.1,accessibilityDescription:entry.0.title),forSegment:index);toolPicker.setWidth(27,forSegment:index);toolPicker.setToolTip(entry.0.title,forSegment:index)}
            toolPicker.target=self;toolPicker.action=#selector(changeTool);toolPicker.selectedSegment=0;item.view=toolPicker;item.label="Editing tools"
        case "color":
            let well=NSColorWell();well.color=surface.color;well.colorWellStyle = .minimal;well.target=self;well.action=#selector(changeColor(_:));well.frame=NSRect(x:0,y:0,width:32,height:28);item.view=well;item.label="Color";item.toolTip="Annotation color"
        case "width":
            let control=NSPopUpButton();control.addItems(withTitles:["2 pt","4 pt","6 pt","10 pt","16 pt"]);control.selectItem(at:1);control.target=self;control.action=#selector(changeWidth(_:));item.view=control;item.label="Stroke width"
        case "textSize":
            let control=NSPopUpButton();control.addItems(withTitles:["12","16","20","24","32","48","64"]);control.selectItem(withTitle:"24");control.target=self;control.action=#selector(changeTextSize(_:));item.view=control;item.label="Text size"
        case "undo": item.view=iconButton("arrow.uturn.backward","Undo (⌘Z)",#selector(undoEdit));item.label="Undo"
        case "redo": item.view=iconButton("arrow.uturn.forward","Redo (⇧⌘Z)",#selector(redoEdit));item.label="Redo"
        case "saveAs":
            let button=NSButton(title:"Save as…",target:self,action:#selector(exportImage));button.bezelStyle = .rounded;button.keyEquivalent="s";button.keyEquivalentModifierMask=[.command,.shift];item.view=button;item.label="Save as…"
        case "done":
            let button=NSButton(title:"Done",target:self,action:#selector(done));button.bezelStyle = .rounded;button.bezelColor = .controlAccentColor;button.keyEquivalent="s";button.keyEquivalentModifierMask=[.command];item.view=button;item.label="Done";item.toolTip="Save edits in screenshot history and close"
        default:return nil
        }
        if let view=item.view {view.setAccessibilityLabel(item.label)}
        return item
    }
    @objc private func changeTool() { let index=toolPicker.selectedSegment;guard editorTools.indices.contains(index) else{return};surface.finishStroke();surface.tool=editorTools[index].0;window?.makeFirstResponder(surface) }
    @objc private func changeColor(_ sender:NSColorWell) { surface.changeSelectedColor(sender.color) }
    @objc private func changeWidth(_ sender:NSPopUpButton) { surface.changeSelectedWidth([2,4,6,10,16][sender.indexOfSelectedItem]) }
    @objc private func changeTextSize(_ sender:NSPopUpButton) { surface.textSize=CGFloat(Double(sender.titleOfSelectedItem ?? "24") ?? 24) }
    @objc private func changeZoom() { let scales:[CGFloat?]=[nil,0.25,0.5,0.75,1,1.5,2];surface.zoomScale=scales[zoomPicker.indexOfSelectedItem];layoutCanvas() }
    @objc private func applyCrop() {surface.applyCrop()}
    @objc private func cancelCrop() {surface.cancelCrop()}
    @objc private func undoEdit() {surface.undo()}
    @objc private func redoEdit() {surface.redo()}
    @objc private func done() {if !surface.hasChanges || save(){close()}}
    @objc private func togglePin() {window?.level=pinButton.state == .on ? .floating:.normal}
    @objc private func addImages() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.image];panel.allowsMultipleSelection=true
        guard let window else{return}
        panel.beginSheetModal(for:window){[weak self] response in guard response == .OK,let self else{return};_ = self.surface.combine(panel.urls.compactMap{NSImage(contentsOf:$0)})}
    }
    @objc private func moreActions(_ sender:NSButton) {
        let menu=NSMenu()
        for (title,selector) in [("Add images…",#selector(addImages)),("Stack vertically",#selector(stackVertically)),("Join horizontally",#selector(joinHorizontally)),("Delete selected annotation",#selector(deleteSelected)),("Clear annotations",#selector(clearAnnotations))] {
            let item=NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target=self;menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)
    }
    @objc private func stackVertically(){surface.combineHorizontal=false;report("Drop images to stack vertically.")}
    @objc private func joinHorizontally(){surface.combineHorizontal=true;report("Drop images to join horizontally.")}
    @objc private func deleteSelected(){surface.deleteSelection()}
    @objc private func clearAnnotations(){surface.clear()}
    @objc private func shareImage(_ sender:NSButton) {
        do {if let image=NSImage(data:try surface.renderedPNG()){NSSharingServicePicker(items:[image]).show(relativeTo:sender.bounds,of:sender,preferredEdge:.minY)}} catch {report(error.localizedDescription)}
    }
    @discardableResult private func save() -> Bool {
        // Saving writes PNG data in place; never flatten an animated GIF into one frame.
        guard item.url.pathExtension.lowercased()=="png" else {report("This capture can't be saved in place. Use Export or Copy to keep your edits.");return false}
        do {
            let data=try surface.renderedPNG();try data.write(to:item.url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:item.url.path)
            if let image=NSImage(data:data){surface.flattenSavedImage(image)}
            window?.isDocumentEdited=false;report("Edits saved in screenshot history");onSaved?();return true
        } catch {report("Save failed: \(error.localizedDescription)");return false}
    }
    @objc private func exportImage() {
        let panel=NSSavePanel();panel.directoryURL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop");panel.nameFieldStringValue=item.url.lastPathComponent;panel.allowedContentTypes=[.png]
        guard let window else{return}
        panel.beginSheetModal(for:window){[weak self] response in
            guard let self,response == .OK,let target=panel.url else{return}
            do {try self.surface.renderedPNG().write(to:target,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path);self.onSaved?();UsageLog.shared?.record("editor_export");self.report("Annotated screenshot exported")}
            catch {self.report("Export failed: \(error.localizedDescription)")}
        }
    }
    @objc private func copyImage() {
        do {let data=try surface.renderedPNG();NSPasteboard.general.clearContents();NSPasteboard.general.setData(data,forType:.png)
            if let image=NSImage(data:data),let tiff=image.tiffRepresentation{NSPasteboard.general.setData(tiff,forType:.tiff)}
            UsageLog.shared?.record("editor_export")
            report("Edited screenshot copied")
        } catch {report("Copy failed: \(error.localizedDescription)")}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard surface.hasChanges else{return true}
        let alert=NSAlert();alert.messageText="Keep your screenshot edits?";alert.informativeText="Your original capture is already in local history."
        alert.addButton(withTitle:"Save edits");alert.addButton(withTitle:"Discard edits");alert.addButton(withTitle:"Keep editing")
        let result=alert.runModal();if result == .alertFirstButtonReturn{return save()};return result == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification:Notification){onClose?()}
}
