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

/// What each editor tool is called, its key, and a one-line hint shown when it is chosen.
struct EditorToolInfo {
    let tool: DrawingTool
    let symbol: String
    let name: String
    let key: String
    let hint: String
    var tooltip: String { "\(name) (\(key))\n\(hint)" }
    static let all: [EditorToolInfo] = [
        EditorToolInfo(tool: .select, symbol: "cursorarrow", name: "Select", key: "V", hint: "Click a mark or image to select it, drag to move it. Drag the canvas edges to resize the canvas."),
        EditorToolInfo(tool: .crop, symbol: "crop", name: "Crop image", key: "C", hint: "Drag over an image to crop it. Return applies, Escape cancels."),
        EditorToolInfo(tool: .pen, symbol: "scribble.variable", name: "Pen", key: "P", hint: "Draw freehand."),
        EditorToolInfo(tool: .line, symbol: "line.diagonal", name: "Line", key: "L", hint: "Drag to draw a straight line."),
        EditorToolInfo(tool: .arrow, symbol: "arrow.up.right", name: "Arrow", key: "A", hint: "Drag from the tail to the point."),
        EditorToolInfo(tool: .rectangle, symbol: "rectangle", name: "Rectangle", key: "R", hint: "Drag to outline an area."),
        EditorToolInfo(tool: .filledRectangle, symbol: "rectangle.fill", name: "Filled box", key: "F", hint: "Drag to cover an area with the current colour."),
        EditorToolInfo(tool: .ellipse, symbol: "circle", name: "Oval", key: "O", hint: "Drag to circle something."),
        EditorToolInfo(tool: .text, symbol: "textformat", name: "Text", key: "T", hint: "Click where the label goes, type, then Return."),
        EditorToolInfo(tool: .highlighter, symbol: "highlighter", name: "Highlighter", key: "H", hint: "Drag across text to highlight whole words and lines. Hold Option (⌥) to draw freehand."),
        EditorToolInfo(tool: .number, symbol: "1.circle.fill", name: "Counter", key: "N", hint: "Click to place numbered steps: 1, 2, 3…"),
        EditorToolInfo(tool: .redact, symbol: "eye.slash", name: "Redact", key: "X", hint: "Drag to hide sensitive details under a solid black box."),
        EditorToolInfo(tool: .eraser, symbol: "eraser", name: "Eraser", key: "E", hint: "Click or drag over a mark to remove it."),
    ]
}

@MainActor
final class CaptureEditorController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let item: CaptureItem
    let surface: DrawingSurface
    private let scroll = NSScrollView()
    private let toolPicker = NSSegmentedControl()
    private let toolName = NSTextField(labelWithString: "")
    private let zoomPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let canvasPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let cropActions = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pinButton = NSButton()
    private var viewportObserver: NSObjectProtocol?
    private let editorTools = EditorToolInfo.all
    private let zoomLevels: [CGFloat?] = [nil, 0.25, 0.5, 0.75, 1, 1.5, 2, 4]
    var onStatus: ((String) -> Void)?
    var onSaved: (() -> Void)?
    var onClose: (() -> Void)?

    init(item: CaptureItem, image: NSImage) {
        self.item = item
        surface = DrawingSurface(frame: NSRect(x: 0, y: 0, width: 1000, height: 650), image: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Screenshot — OpenToolkit"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 860, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        surface.tool = .select
        surface.onEscape = { [weak self] in self?.window?.performClose(nil) }
        surface.onStatus = { [weak self] in self?.report($0) }
        surface.onChange = { [weak self] in self?.changed() }
        surface.onToolChange = { [weak self] in self?.syncTools(announce: true) }
        surface.onMagnify = { [weak self] factor, point in guard let self else { return }; self.zoom(to: self.surface.viewScale * factor, anchor: point) }
        surface.onSmartMagnify = { [weak self] point in guard let self else { return }; self.zoom(to: self.surface.zoomScale == nil ? 1 : nil, anchor: point) }
        surface.onZoomCommand = { [weak self] key in
            guard let self else { return }
            switch key { case "0": self.zoom(to: nil); case "1": self.zoom(to: 1); case "-": self.zoom(to: self.surface.viewScale / 1.25); default: self.zoom(to: self.surface.viewScale * 1.25) }
        }
        let toolbar = NSToolbar(identifier: "OpenToolkit.CaptureEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        makeContent(window)
        window.makeFirstResponder(surface)
        syncTools(announce: false)
        report("Pinch to zoom. Drag the canvas edges to make room; drop or paste images to add them as layers.")
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
        zoomPicker.addItem(withTitle: "Fit")
        zoomPicker.addItems(withTitles: ["Zoom to fit  ⌘0", "25%", "50%", "75%", "Actual size  ⌘1", "150%", "200%", "400%"])
        zoomPicker.target = self; zoomPicker.action = #selector(changeZoom)
        zoomPicker.toolTip = "Zoom: pinch on the trackpad, ⌘+ and ⌘−, ⌘0 to fit. Two fingers scroll around. Export keeps full resolution."
        canvasPicker.addItem(withTitle: "Canvas")
        for (title, tag) in [("Fit canvas to images", 1), ("Add 40 pt of room", 2), ("Add 120 pt of room", 3)] { canvasPicker.addItem(withTitle: title); canvasPicker.lastItem?.tag = tag }
        canvasPicker.menu?.addItem(.separator())
        for background in CanvasBackground.allCases { canvasPicker.addItem(withTitle: "Background: " + background.title); canvasPicker.lastItem?.tag = 10 + background.rawValue }
        canvasPicker.menu?.addItem(.separator())
        canvasPicker.addItem(withTitle: "Grow canvas when images move outside"); canvasPicker.lastItem?.tag = 20
        canvasPicker.target = self; canvasPicker.action = #selector(canvasAction(_:))
        canvasPicker.toolTip = "Canvas size and background. With the Select tool, drag the canvas edges to grow or shrink it."
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
        let more = iconButton("ellipsis.circle", "More: add images, arrange layers, smart highlighter", #selector(moreActions(_:)))
        let right = NSStackView(views: [share,pinButton,copy,more]); right.spacing = 6
        let apply = NSButton(title: "Apply crop", target: self, action: #selector(applyCrop))
        apply.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCrop))
        cancel.bezelStyle = .rounded
        cropActions.addArrangedSubview(apply);cropActions.addArrangedSubview(cancel);cropActions.spacing=6;cropActions.isHidden=true
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        for view in [scroll,footer] { view.translatesAutoresizingMaskIntoConstraints=false;container.addSubview(view) }
        for view in [zoomPicker,canvasPicker,drag,right,cropActions,statusLabel] { view.translatesAutoresizingMaskIntoConstraints=false;footer.addSubview(view) }
        let guide = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),scroll.leadingAnchor.constraint(equalTo:container.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:container.trailingAnchor),scroll.bottomAnchor.constraint(equalTo:footer.topAnchor),
            footer.heightAnchor.constraint(equalToConstant:50),footer.leadingAnchor.constraint(equalTo:container.leadingAnchor),footer.trailingAnchor.constraint(equalTo:container.trailingAnchor),footer.bottomAnchor.constraint(equalTo:container.bottomAnchor),
            zoomPicker.leadingAnchor.constraint(equalTo:footer.leadingAnchor,constant:12),zoomPicker.centerYAnchor.constraint(equalTo:footer.centerYAnchor),zoomPicker.widthAnchor.constraint(equalToConstant:96),
            canvasPicker.leadingAnchor.constraint(equalTo:zoomPicker.trailingAnchor,constant:8),canvasPicker.centerYAnchor.constraint(equalTo:footer.centerYAnchor),canvasPicker.widthAnchor.constraint(equalToConstant:172),
            drag.centerXAnchor.constraint(equalTo:footer.centerXAnchor),drag.centerYAnchor.constraint(equalTo:footer.centerYAnchor),drag.widthAnchor.constraint(equalToConstant:116),drag.heightAnchor.constraint(equalToConstant:28),
            right.trailingAnchor.constraint(equalTo:footer.trailingAnchor,constant:-12),right.centerYAnchor.constraint(equalTo:footer.centerYAnchor),
            cropActions.leadingAnchor.constraint(equalTo:canvasPicker.trailingAnchor,constant:12),cropActions.centerYAnchor.constraint(equalTo:footer.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo:canvasPicker.trailingAnchor,constant:12),statusLabel.trailingAnchor.constraint(lessThanOrEqualTo:drag.leadingAnchor,constant:-16),statusLabel.centerYAnchor.constraint(equalTo:footer.centerYAnchor)
        ])
        container.layoutSubtreeIfNeeded();layoutCanvas()
    }
    func windowDidResize(_ notification: Notification) { layoutCanvas() }
    private func layoutCanvas() {
        let desired=surface.documentViewSize(viewport:scroll.contentView.bounds.size)
        if surface.frame.size != desired {surface.setFrameSize(desired)}
        surface.needsDisplay=true
        syncLabels()
    }
    /// Zooms around a window point (the pinch centre) so the content under the fingers stays put.
    func zoom(to scale: CGFloat?, anchor windowPoint: NSPoint? = nil) {
        let clip = scroll.contentView
        let anchor = windowPoint.map { clip.convert($0, from: nil) } ?? NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        let offset = NSPoint(x: anchor.x - clip.bounds.minX, y: anchor.y - clip.bounds.minY)
        let documentAnchor = surface.documentPoint(surface.convert(anchor, from: clip))
        surface.zoomScale = scale.map { min(8, max(0.05, $0)) }
        layoutCanvas()
        let moved = clip.convert(surface.viewPoint(documentAnchor), from: surface)
        let origin = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: moved.x - offset.x, y: moved.y - offset.y), size: clip.bounds.size)).origin
        clip.setBoundsOrigin(origin); scroll.reflectScrolledClipView(clip)
        surface.needsDisplay = true
    }
    private func syncLabels() {
        let percent = Int((surface.viewScale * 100).rounded())
        zoomPicker.item(at: 0)?.title = surface.zoomScale == nil ? "Fit · \(percent)%" : "\(percent)%"
        canvasPicker.item(at: 0)?.title = "Canvas \(Int(surface.canvas.width)) × \(Int(surface.canvas.height))"
        for item in canvasPicker.itemArray {
            if item.tag >= 10 && item.tag < 20 { item.state = item.tag - 10 == surface.canvasBackground.rawValue ? .on : .off }
            if item.tag == 20 { item.state = surface.growsCanvasForMovedImages ? .on : .off }
        }
    }
    private func changed() { window?.isDocumentEdited=surface.hasChanges;cropActions.isHidden = !surface.hasPendingCrop;statusLabel.isHidden=surface.hasPendingCrop;layoutCanvas() }
    private func syncTools(announce: Bool) {
        let index = editorTools.firstIndex(where:{$0.tool==surface.tool}) ?? 0
        toolPicker.selectedSegment=index
        toolName.stringValue = "\(editorTools[index].name)  \(editorTools[index].key)"
        toolName.toolTip = editorTools[index].hint
        if announce { report(editorTools[index].hint) }
    }
    private func report(_ text: String) { statusLabel.stringValue=text;statusLabel.toolTip=text;onStatus?(text) }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ["tools","toolName","color","width","textSize","undo","redo"].map{NSToolbarItem.Identifier($0)} + [.flexibleSpace] + ["saveAs","done"].map{NSToolbarItem.Identifier($0)} }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item=NSToolbarItem(itemIdentifier:id)
        func symbolPopUp(_ titles:[String],_ symbol:String,_ selected:String,_ action:Selector,_ tip:String)->NSPopUpButton {
            let control=NSPopUpButton();control.addItems(withTitles:titles);control.selectItem(withTitle:selected);control.target=self;control.action=action;control.toolTip=tip
            let image=NSImage(systemSymbolName:symbol,accessibilityDescription:tip);control.itemArray.forEach{$0.image=image};control.imagePosition = .imageLeading
            return control
        }
        switch id.rawValue {
        case "tools":
            toolPicker.segmentCount=editorTools.count;toolPicker.trackingMode = .selectOne;toolPicker.segmentStyle = .rounded
            for (index,entry) in editorTools.enumerated() {toolPicker.setImage(NSImage(systemSymbolName:entry.symbol,accessibilityDescription:entry.name),forSegment:index);toolPicker.setWidth(28,forSegment:index);toolPicker.setToolTip(entry.tooltip,forSegment:index)}
            toolPicker.target=self;toolPicker.action=#selector(changeTool);toolPicker.selectedSegment=0;item.view=toolPicker;item.label="Editing tools"
        case "toolName":
            // The chosen tool in words, so the icons never have to be guessed.
            toolName.font = .systemFont(ofSize:12,weight:.semibold);toolName.textColor = .secondaryLabelColor;toolName.alignment = .left
            toolName.widthAnchor.constraint(equalToConstant:104).isActive=true
            item.view=toolName;item.label="Current tool"
        case "color":
            let well=NSColorWell();well.color=surface.color;well.colorWellStyle = .minimal;well.target=self;well.action=#selector(changeColor(_:));well.frame=NSRect(x:0,y:0,width:32,height:28);item.view=well;item.label="Colour";item.toolTip="Colour for new marks and the selected mark"
        case "width":
            item.view=symbolPopUp(["2 pt","4 pt","6 pt","10 pt","16 pt"],"lineweight","4 pt",#selector(changeWidth(_:)),"Line width for pens, shapes and arrows");item.label="Line width"
        case "textSize":
            item.view=symbolPopUp(["12","16","20","24","32","48","64"],"textformat.size","24",#selector(changeTextSize(_:)),"Text and counter size");item.label="Text size"
        case "undo": item.view=iconButton("arrow.uturn.backward","Undo (⌘Z)",#selector(undoEdit));item.label="Undo"
        case "redo": item.view=iconButton("arrow.uturn.forward","Redo (⇧⌘Z)",#selector(redoEdit));item.label="Redo"
        case "saveAs":
            let button=NSButton(title:"Save as…",target:self,action:#selector(exportImage));button.bezelStyle = .rounded;button.keyEquivalent="s";button.keyEquivalentModifierMask=[.command,.shift];button.toolTip="Export a copy as a PNG file (⇧⌘S)";item.view=button;item.label="Save as…"
        case "done":
            let button=NSButton(title:"Done",target:self,action:#selector(done));button.bezelStyle = .rounded;button.bezelColor = .controlAccentColor;button.keyEquivalent="s";button.keyEquivalentModifierMask=[.command];button.toolTip="Save edits in screenshot history and close (⌘S)";item.view=button;item.label="Done";item.toolTip="Save edits in screenshot history and close"
        default:return nil
        }
        if let view=item.view {view.setAccessibilityLabel(item.label)}
        return item
    }
    @objc private func changeTool() { let index=toolPicker.selectedSegment;guard editorTools.indices.contains(index) else{return};surface.finishStroke();surface.tool=editorTools[index].tool;window?.makeFirstResponder(surface) }
    @objc private func changeColor(_ sender:NSColorWell) { surface.changeSelectedColor(sender.color) }
    @objc private func changeWidth(_ sender:NSPopUpButton) { surface.changeSelectedWidth([2,4,6,10,16][sender.indexOfSelectedItem]) }
    @objc private func changeTextSize(_ sender:NSPopUpButton) { surface.textSize=CGFloat(Double(sender.titleOfSelectedItem ?? "24") ?? 24) }
    @objc private func changeZoom() { let index=zoomPicker.indexOfSelectedItem-1;guard zoomLevels.indices.contains(index) else{return};zoom(to:zoomLevels[index]);window?.makeFirstResponder(surface) }
    @objc private func canvasAction(_ sender:NSPopUpButton) {
        guard let tag=sender.selectedItem?.tag else{return}
        switch tag {
        case 1:surface.fitCanvasToImages()
        case 2:surface.padCanvas(40)
        case 3:surface.padCanvas(120)
        case 10..<20:surface.canvasBackground=CanvasBackground(rawValue:tag-10) ?? .auto
        case 20:surface.growsCanvasForMovedImages.toggle()
        default:break
        }
        layoutCanvas();window?.makeFirstResponder(surface)
    }
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
        for (title,selector) in [("Add images…",#selector(addImages)),("Place new images below",#selector(stackVertically)),("Place new images to the right",#selector(joinHorizontally))] {
            let item=NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target=self;menu.addItem(item)
        }
        menu.items[1].state = surface.combineHorizontal ? .off:.on;menu.items[2].state = surface.combineHorizontal ? .on:.off
        menu.addItem(.separator())
        for (title,selector) in [("Bring selected image to front",#selector(bringToFront)),("Send selected image to back",#selector(sendToBack)),("Delete selection",#selector(deleteSelected)),("Clear annotations",#selector(clearAnnotations))] {
            let item=NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target=self;menu.addItem(item)
        }
        menu.addItem(.separator())
        let smart=NSMenuItem(title:"Highlighter snaps to text",action:#selector(toggleSmartHighlight),keyEquivalent:"");smart.target=self;smart.state=surface.smartHighlight ? .on:.off;menu.addItem(smart)
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)
    }
    @objc private func stackVertically(){surface.combineHorizontal=false;report("New images go below. Drop, paste or add them, then drag to place.")}
    @objc private func joinHorizontally(){surface.combineHorizontal=true;report("New images go to the right. Drop, paste or add them, then drag to place.")}
    @objc private func bringToFront(){surface.arrangeSelectedLayer(toFront:true)}
    @objc private func sendToBack(){surface.arrangeSelectedLayer(toFront:false)}
    @objc private func toggleSmartHighlight(){surface.smartHighlight.toggle();report(surface.smartHighlight ? "The highlighter snaps to text. Hold Option (⌥) for freehand.":"The highlighter draws freehand.")}
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
