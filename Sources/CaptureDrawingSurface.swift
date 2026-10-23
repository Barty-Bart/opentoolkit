import AppKit
import CoreGraphics

enum DrawingTool: Int, CaseIterable { case pen, arrow, rectangle, ellipse, text, crop, line, eraser, select, filledRectangle, highlighter, number, redact
    var title: String { ["Pen", "Arrow", "Box", "Oval", "Text", "Crop", "Line", "Eraser", "Select", "Filled box", "Highlight", "Number", "Redact"][rawValue] }
}

struct DrawingMark {
    let tool: DrawingTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 24
    /// Text bands a smart highlight snapped to; empty for a freehand stroke.
    var rects: [CGRect] = []
    func offset(by dx: CGFloat, _ dy: CGFloat) -> DrawingMark {
        var moved = self
        moved.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        moved.rects = rects.map { $0.offsetBy(dx: dx, dy: dy) }
        return moved
    }
}

/// An image on the editor canvas. Frames are in document points; the first layer is the capture.
struct CanvasLayer {
    var id = UUID()
    var image: NSImage
    var frame: CGRect
    var pixelScale: CGFloat {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), frame.width > 0 else { return 1 }
        return CGFloat(cg.width) / frame.width
    }
}

enum CanvasBackground: Int, CaseIterable { case auto, clear, white, black
    var title: String { ["Match image edge", "Transparent", "White", "Black"][rawValue] }
}

/// Pure canvas geometry, shared by the editor and its tests.
enum CanvasGeometry {
    static let workspaceMargin: CGFloat = 56
    static let minimumSide: CGFloat = 16
    /// Largest zoom that shows the whole canvas with working room around it, never above 100%.
    static func fitScale(canvas: CGSize, viewport: CGSize) -> CGFloat {
        let m = workspaceMargin * 2
        return max(0.02, min(1, min((viewport.width - m) / max(canvas.width, 1), (viewport.height - m) / max(canvas.height, 1))))
    }
    /// Moves the dragged canvas edges (`h`/`v`: -1 = min edge, 1 = max edge, 0 = unchanged), snapping to nearby image edges.
    static func resize(_ canvas: CGRect, h: Int, v: Int, to p: CGPoint, snapTo targets: [CGRect], tolerance: CGFloat) -> CGRect {
        func snap(_ value: CGFloat, _ candidates: [CGFloat]) -> CGFloat { candidates.min { abs($0 - value) < abs($1 - value) }.flatMap { abs($0 - value) <= tolerance ? $0 : nil } ?? value }
        let xs = targets.flatMap { [$0.minX, $0.maxX] }, ys = targets.flatMap { [$0.minY, $0.maxY] }
        var minX = canvas.minX, maxX = canvas.maxX, minY = canvas.minY, maxY = canvas.maxY
        if h < 0 { minX = min(snap(p.x, xs), maxX - minimumSide) }
        if h > 0 { maxX = max(snap(p.x, xs), minX + minimumSide) }
        if v < 0 { minY = min(snap(p.y, ys), maxY - minimumSide) }
        if v > 0 { maxY = max(snap(p.y, ys), minY + minimumSide) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    /// Places added images below (or to the right of) everything already on the canvas, with a gap.
    static func placements(for sizes: [CGSize], after content: CGRect, horizontal: Bool, gap: CGFloat = 16) -> [CGRect] {
        var union = content
        return sizes.map { size in
            let frame = horizontal ? CGRect(x: union.maxX + gap, y: union.maxY - size.height, width: size.width, height: size.height)
                                   : CGRect(x: union.minX, y: union.minY - gap - size.height, width: size.width, height: size.height)
            union = union.union(frame); return frame
        }
    }
    /// Rounds a document position onto the export pixel grid so moved images stay sharp.
    static func aligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale, width: rect.width, height: rect.height)
    }
}

@MainActor
final class DrawingSurface: NSView, NSTextFieldDelegate {
    /// Editor documents hold image layers; screen drawing has none and uses the view bounds.
    private(set) var layers: [CanvasLayer] = []
    /// The area that is exported, in document points. It can be larger or smaller than the images.
    private(set) var canvas: CGRect = .zero
    var image: NSImage? { layers.first?.image }
    var isDocument: Bool { !layers.isEmpty }
    var canvasBackground = CanvasBackground.auto { didSet { needsDisplay = true } }
    var growsCanvasForMovedImages = true
    var smartHighlight = true
    var tool: DrawingTool = .pen { didSet { if tool != .select { selectedIndex=nil;selectedLayer=nil }; needsDisplay=true; onToolChange?() } }
    var zoomScale: CGFloat? = nil
    var onToolChange: (() -> Void)?
    var onMagnify: ((CGFloat, NSPoint) -> Void)?
    var onSmartMagnify: ((NSPoint) -> Void)?
    var onZoomCommand: ((String) -> Void)?
    private(set) var selectedIndex: Int?
    private(set) var selectedLayer: Int?
    private var moveOrigin: CGPoint?
    private var movePoints: [CGPoint] = []
    private var moveRects: [CGRect] = []
    private var moveFrame: CGRect?
    private var moveRemembered = false
    private var canvasDrag: (h: Int, v: Int, original: CGRect)?
    /// Holds zoom and position still while a canvas edge is dragged, so the canvas never re-fits under the pointer.
    private var frozenMapping: (scale: CGFloat, origin: CGPoint)?
    var color = NSColor.systemRed
    var strokeWidth: CGFloat = 4
    var textSize: CGFloat = 24
    var combineHorizontal = false
    var onStatus: ((String)->Void)?
    private var cropAnchor: CGPoint?
    private var cropRect: CGRect?
    private var cropLayer: Int?
    private var cropMoveOrigin:CGPoint?
    private var cropMoveRect:CGRect?
    var hasPendingCrop:Bool {cropRect != nil}
    private var editedImage = false
    private struct Snapshot {let layers:[CanvasLayer];let canvas:CGRect;let marks:[DrawingMark];let edited:Bool}
    private var undoStates:[Snapshot]=[]
    private var redoStates:[Snapshot]=[]
    private var textLines:[UUID:[TextLine]]=[:]
    private var textPending:Set<UUID>=[]
    private var freehandHighlight = false
    var onEscape: (() -> Void)?
    var onActivity: (() -> Void)?
    var onChange: (() -> Void)?
    var onTextFinished: (() -> Void)?
    var hasTextEntry:Bool {entry != nil}
    private(set) var marks: [DrawingMark] = []
    private var redoMarks: [DrawingMark] = []
    private var current: DrawingMark?
    private var entry: NSTextField?
    private var entryPoint: CGPoint?
    override var acceptsFirstResponder: Bool { true }
    var hasChanges: Bool { editedImage || !marks.isEmpty || current != nil || entry != nil }

    init(frame: CGRect, image: NSImage?) {
        super.init(frame: frame)
        if let image { layers = [CanvasLayer(image: image, frame: CGRect(origin: .zero, size: image.size))]; canvas = layers[0].frame }
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        detectText()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Geometry — document points to view points
    private var canvasRect: CGRect { isDocument ? canvas : bounds }
    var viewScale: CGFloat { isDocument ? frozenMapping?.scale ?? zoomScale ?? CanvasGeometry.fitScale(canvas: canvas.size, viewport: bounds.size) : 1 }
    private var viewOrigin: CGPoint {
        guard isDocument else { return .zero }
        if let frozenMapping { return frozenMapping.origin }
        let s = viewScale
        return CGPoint(x: (bounds.midX - canvas.midX * s).rounded(), y: (bounds.midY - canvas.midY * s).rounded())
    }
    func viewPoint(_ p: CGPoint) -> CGPoint { let o = viewOrigin, s = viewScale; return CGPoint(x: o.x + p.x * s, y: o.y + p.y * s) }
    func documentPoint(_ v: CGPoint) -> CGPoint { let o = viewOrigin, s = viewScale; return CGPoint(x: (v.x - o.x) / s, y: (v.y - o.y) / s) }
    func viewRect(_ r: CGRect) -> CGRect { let a = viewPoint(r.origin); return CGRect(x: a.x, y: a.y, width: r.width * viewScale, height: r.height * viewScale) }
    /// The surface size the scroll view needs: the canvas at this zoom plus working room, at least the viewport.
    func documentViewSize(viewport: CGSize) -> CGSize {
        guard isDocument else { return viewport }
        if frozenMapping != nil { return CGSize(width: max(viewport.width, bounds.width), height: max(viewport.height, bounds.height)) }
        let s = zoomScale ?? CanvasGeometry.fitScale(canvas: canvas.size, viewport: viewport), m = CanvasGeometry.workspaceMargin * 2
        return CGSize(width: max(viewport.width, (canvas.width * s + m).rounded(.up)), height: max(viewport.height, (canvas.height * s + m).rounded(.up)))
    }
    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        if isDocument { return documentPoint(v) }
        return CGPoint(x: min(bounds.width, max(0, v.x)), y: min(bounds.height, max(0, v.y)))
    }
    private var effectiveWidth: CGFloat { strokeWidth / viewScale }
    var exportScale: CGFloat { max(1, layers.map(\.pixelScale).max() ?? 1) }
    private var contentBounds: CGRect { layers.dropFirst().reduce(layers.first?.frame ?? .zero) { $0.union($1.frame) } }
    private func canvasHandle(at v: CGPoint) -> (h: Int, v: Int)? {
        guard isDocument else { return nil }
        let r = viewRect(canvas), t: CGFloat = 7
        guard r.insetBy(dx: -t, dy: -t).contains(v), !r.insetBy(dx: t, dy: t).contains(v) else { return nil }
        let h = abs(v.x - r.minX) <= t ? -1 : abs(v.x - r.maxX) <= t ? 1 : 0
        let vv = abs(v.y - r.minY) <= t ? -1 : abs(v.y - r.maxY) <= t ? 1 : 0
        return h == 0 && vv == 0 ? nil : (h, vv)
    }
    private func movableLayer(at p: CGPoint) -> Int? {
        // A lone capture that fills the canvas stays put, so a stray drag never shifts the screenshot.
        guard let index = layers.lastIndex(where: { $0.frame.contains(p) }) else { return nil }
        if layers.count == 1, canvas.width <= layers[0].frame.width + 0.5, canvas.height <= layers[0].frame.height + 0.5 { return nil }
        return index
    }

    // MARK: Mouse and keys
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        guard isDocument, tool == .select else { return }
        let v = convert(event.locationInWindow, from: nil)
        if let handle = canvasHandle(at: v) { (handle.v == 0 ? NSCursor.resizeLeftRight : handle.h == 0 ? NSCursor.resizeUpDown : NSCursor.crosshair).set() }
        else if movableLayer(at: documentPoint(v)) != nil { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }
    override func magnify(with event: NSEvent) { if isDocument { onMagnify?(1 + event.magnification, event.locationInWindow) } else { super.magnify(with: event) } }
    override func smartMagnify(with event: NSEvent) { if isDocument { onSmartMagnify?(event.locationInWindow) } else { super.smartMagnify(with: event) } }

    override func mouseDown(with event: NSEvent) {
        commitText(); onActivity?(); window?.makeFirstResponder(self)
        let v = convert(event.locationInWindow, from: nil)
        guard isDocument || canvasRect.contains(v) else { return }
        let p = canvasPoint(event)
        if tool == .select {
            moveOrigin=p;moveRemembered=false;moveFrame=nil;movePoints=[];moveRects=[]
            if let handle=canvasHandle(at:v) {frozenMapping=(viewScale,viewOrigin);canvasDrag=(handle.h,handle.v,canvas);selectedIndex=nil;selectedLayer=nil;needsDisplay=true;onChange?();return}
            selectedIndex=marks.lastIndex(where:{boundsForMark($0).insetBy(dx:-8/viewScale,dy:-8/viewScale).contains(p)})
            selectedLayer=selectedIndex == nil ? movableLayer(at:p):nil
            if let index=selectedIndex {movePoints=marks[index].points;moveRects=marks[index].rects}
            if let index=selectedLayer {moveFrame=layers[index].frame;NSCursor.closedHand.set()}
            needsDisplay=true;onChange?();return
        }
        if tool == .number {
            let next=(marks.filter{$0.tool == .number}.compactMap{Int($0.text)}.max() ?? 0)+1
            remember();marks.append(DrawingMark(tool:.number,points:[p],color:color,width:effectiveWidth,text:String(next),fontSize:textSize/viewScale));needsDisplay=true;onChange?();return
        }
        if tool == .crop, isDocument {
            if let r=cropRect {
                let corners=[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)]
                let tolerance=12/viewScale
                if let n=corners.firstIndex(where:{hypot($0.x-p.x,$0.y-p.y)<tolerance}) {cropAnchor=corners[(n+2)%4];return}
                if r.contains(p) {cropMoveOrigin=p;cropMoveRect=r;return}
            }
            cropLayer=layers.lastIndex(where:{$0.frame.contains(p)}) ?? selectedLayer ?? 0
            cropAnchor=clamp(p,to:layers[cropLayer!].frame);cropRect=nil;return
        }
        if tool == .text { beginText(at: p); return }
        if tool == .eraser {erase(at:p);return}
        freehandHighlight=event.modifierFlags.contains(.option) || !smartHighlight
        current = DrawingMark(tool: tool, points: [p, p], color: color, width: effectiveWidth)
        needsDisplay = true
    }
    private func clamp(_ p:CGPoint,to r:CGRect)->CGPoint {CGPoint(x:min(r.maxX,max(r.minX,p.x)),y:min(r.maxY,max(r.minY,p.y)))}
    override func mouseDragged(with event: NSEvent) {
        if tool == .select,let origin=moveOrigin {
            let p=canvasPoint(event);let dx=p.x-origin.x,dy=p.y-origin.y
            if let drag=canvasDrag {
                if !moveRemembered {remember();moveRemembered=true}
                let resized=CanvasGeometry.resize(drag.original,h:drag.h,v:drag.v,to:p,snapTo:layers.map(\.frame)+[contentBounds],tolerance:6/viewScale)
                canvas=CGRect(x:resized.minX.rounded(),y:resized.minY.rounded(),width:resized.width.rounded(),height:resized.height.rounded())
                editedImage=true;onStatus?("Canvas \(Int(canvas.width)) × \(Int(canvas.height)) pt");needsDisplay=true;onChange?();return
            }
            if let index=selectedIndex,marks.indices.contains(index) {
                if !moveRemembered {remember();moveRemembered=true}
                marks[index].points=movePoints.map{CGPoint(x:$0.x+dx,y:$0.y+dy)};marks[index].rects=moveRects.map{$0.offsetBy(dx:dx,dy:dy)}
                needsDisplay=true;onChange?();return
            }
            if let index=selectedLayer,layers.indices.contains(index),let frame=moveFrame {
                if !moveRemembered {remember();moveRemembered=true}
                layers[index].frame=frame.offsetBy(dx:dx,dy:dy);editedImage=true
                needsDisplay=true;onChange?();return
            }
            return
        }
        if tool == .eraser {erase(at:canvasPoint(event));return}
        if let origin=cropMoveOrigin,let original=cropMoveRect,let index=cropLayer,layers.indices.contains(index) {
            let p=canvasPoint(event),bounds=layers[index].frame
            cropRect=CGRect(x:max(bounds.minX,min(bounds.maxX-original.width,original.minX+p.x-origin.x)),y:max(bounds.minY,min(bounds.maxY-original.height,original.minY+p.y-origin.y)),width:original.width,height:original.height)
            needsDisplay=true;return
        }
        if let anchor=cropAnchor,let index=cropLayer,layers.indices.contains(index) {let p=clamp(canvasPoint(event),to:layers[index].frame);cropRect=CGRect(x:min(anchor.x,p.x),y:min(anchor.y,p.y),width:abs(p.x-anchor.x),height:abs(p.y-anchor.y));needsDisplay=true;return}
        guard var mark = current else { return }
        let p = canvasPoint(event)
        if mark.tool == .pen || mark.tool == .highlighter { mark.points.append(p) } else { mark.points[1] = p }
        if mark.tool == .highlighter {
            let freehand=freehandHighlight || event.modifierFlags.contains(.option)
            mark.rects=freehand ? []:TextSnap.highlightRects(for:mark.points,lines:documentTextLines) ?? []
        }
        current = mark; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if tool == .select {
            if canvasDrag != nil, moveRemembered {onStatus?("Canvas \(Int(canvas.width)) × \(Int(canvas.height)) pt. Command-Z undoes it.")}
            if let index=selectedLayer,layers.indices.contains(index),moveRemembered {
                layers[index].frame=CanvasGeometry.aligned(layers[index].frame,scale:exportScale)
                if growsCanvasForMovedImages, !canvas.contains(layers[index].frame) {canvas=canvas.union(layers[index].frame).integral;onStatus?("The canvas grew to fit the image. Drag its edges to trim it.")}
                needsDisplay=true;onChange?()
            }
            moveOrigin=nil;movePoints=[];moveRects=[];moveFrame=nil;moveRemembered=false
            if canvasDrag != nil {canvasDrag=nil;frozenMapping=nil;needsDisplay=true;onChange?()}
            if selectedLayer != nil {NSCursor.openHand.set()}
            return
        }
        if cropAnchor != nil || cropMoveOrigin != nil {cropAnchor=nil;cropMoveOrigin=nil;cropMoveRect=nil;needsDisplay=true;onStatus?("Adjust the crop by dragging its corners or centre. Return or Apply Crop confirms; Escape cancels.");onChange?();return}
        guard let mark = current else { return }
        addAnnotation(mark); current = nil; redoMarks.removeAll(); needsDisplay = true; onChange?()
    }
    static let toolKeys: [String: DrawingTool] = ["v": .select, "c": .crop, "p": .pen, "l": .line, "a": .arrow, "r": .rectangle, "f": .filledRectangle, "o": .ellipse, "t": .text, "h": .highlighter, "n": .number, "x": .redact, "e": .eraser]
    override func keyDown(with event: NSEvent) {
        if [51,117].contains(event.keyCode),selectedIndex != nil || selectedLayer != nil {deleteSelection();return}
        if event.keyCode == 36,hasPendingCrop {applyCrop();return}
        if event.keyCode == 53 {if hasPendingCrop || cropAnchor != nil {cancelCrop()}else{onEscape?()};return}
        if (123...126).contains(event.keyCode),selectedIndex != nil || selectedLayer != nil {
            let step:CGFloat=event.modifierFlags.contains(.shift) ? 10:1
            nudge(dx:event.keyCode == 123 ? -step:event.keyCode == 124 ? step:0,dy:event.keyCode == 125 ? -step:event.keyCode == 126 ? step:0);return
        }
        if event.modifierFlags.contains(.command), let key=event.charactersIgnoringModifiers {
            if key == "z" { if event.modifierFlags.contains(.shift) { redo() } else { undo() }; return }
            if isDocument, ["=","+","-","0","1"].contains(key) { onZoomCommand?(key); return }
            if isDocument, key == "v" { pasteImage(); return }
        }
        let shortcuts: [String: DrawingTool] = isDocument ? Self.toolKeys : ["v": .select,"p": .pen, "a": .arrow, "r": .rectangle, "o": .ellipse, "t": .text,"c": .crop]
        if !event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased(), let next = shortcuts[key] { tool = next; return }
        super.keyDown(with: event)
    }

    func addAnnotation(_ mark: DrawingMark) { remember(); marks.append(mark); needsDisplay=true; onChange?() }

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
            if !mark.rects.isEmpty {return mark.rects.contains{$0.insetBy(dx:-4,dy:-4).contains(point)}}
            if mark.tool == .text {let size=(mark.text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:mark.fontSize,weight:.semibold)]);return CGRect(origin:a,size:size).insetBy(dx:-radius,dy:-radius).contains(point)}
            var points=mark.points
            if mark.tool == .rectangle {points=[a,CGPoint(x:b.x,y:a.y),b,CGPoint(x:a.x,y:b.y),a]}
            if mark.tool == .ellipse {let cx=(a.x+b.x)/2,cy=(a.y+b.y)/2;points=(0...64).map{let t=CGFloat($0)*2 * .pi/64;return CGPoint(x:cx+abs(b.x-a.x)/2*cos(t),y:cy+abs(b.y-a.y)/2*sin(t))}}
            return zip(points,points.dropFirst()).contains{distance(point,$0.0,$0.1)<=radius}
        }) else{return}
        remember();marks.remove(at:index);needsDisplay=true;onChange?()
    }
    func boundsForMark(_ mark:DrawingMark)->CGRect {
        guard let a=mark.points.first else{return .zero}
        if let first=mark.rects.first {return mark.rects.reduce(first){$0.union($1)}}
        if mark.tool == .text {return CGRect(origin:a,size:(mark.text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:mark.fontSize,weight:.semibold)]))}
        if mark.tool == .number {let radius=max(14,mark.fontSize*0.7);return CGRect(x:a.x-radius,y:a.y-radius,width:radius*2,height:radius*2)}
        let xs=mark.points.map(\.x),ys=mark.points.map(\.y)
        return CGRect(x:xs.min()!,y:ys.min()!,width:max(1,xs.max()!-xs.min()!),height:max(1,ys.max()!-ys.min()!)).insetBy(dx:-mark.width/2,dy:-mark.width/2)
    }
    func deleteSelection(){
        if let index=selectedLayer,layers.indices.contains(index) {
            guard layers.count>1 else{onStatus?("The last image stays; use Clear annotations or close the editor instead.");return}
            remember();layers.remove(at:index);selectedLayer=nil;editedImage=true;needsDisplay=true;onChange?();return
        }
        guard let index=selectedIndex,marks.indices.contains(index) else{return};remember();marks.remove(at:index);selectedIndex=nil;needsDisplay=true;onChange?()
    }
    func selectLayer(_ index:Int?){selectedLayer=index.flatMap{layers.indices.contains($0) ? $0:nil};selectedIndex=nil;needsDisplay=true}
    /// Moves the selected image layer by its index and returns the result for tests and the editor menu.
    func moveLayer(_ index:Int,by dx:CGFloat,_ dy:CGFloat){
        guard layers.indices.contains(index) else{return}
        remember();layers[index].frame=CanvasGeometry.aligned(layers[index].frame.offsetBy(dx:dx,dy:dy),scale:exportScale);editedImage=true
        if growsCanvasForMovedImages {canvas=canvas.union(layers[index].frame).integral}
        needsDisplay=true;onChange?()
    }
    private func nudge(dx:CGFloat,dy:CGFloat){
        if let index=selectedLayer {moveLayer(index,by:dx,dy);return}
        guard let index=selectedIndex,marks.indices.contains(index) else{return}
        remember();marks[index]=marks[index].offset(by:dx,dy);needsDisplay=true;onChange?()
    }
    func arrangeSelectedLayer(toFront:Bool){
        guard let index=selectedLayer,layers.indices.contains(index),layers.count>1 else{onStatus?("Select an image first (Select tool, V).");return}
        remember();let layer=layers.remove(at:index)
        if toFront {layers.append(layer);selectedLayer=layers.count-1} else {layers.insert(layer,at:0);selectedLayer=0}
        editedImage=true;needsDisplay=true;onChange?()
    }
    func changeSelectedColor(_ color:NSColor){self.color=color;guard let index=selectedIndex,marks.indices.contains(index) else{return};remember();marks[index].color=color;needsDisplay=true;onChange?()}
    func changeSelectedWidth(_ width:CGFloat){strokeWidth=width;guard let index=selectedIndex,marks.indices.contains(index) else{return};remember();marks[index].width=effectiveWidth;needsDisplay=true;onChange?()}

    // MARK: Canvas
    /// Sets the exported canvas rectangle, for the canvas menu and tests. Content outside it is kept but not exported.
    func setCanvas(_ rect:CGRect){
        guard isDocument else{return}
        let next=CGRect(x:rect.minX.rounded(),y:rect.minY.rounded(),width:max(CanvasGeometry.minimumSide,rect.width.rounded()),height:max(CanvasGeometry.minimumSide,rect.height.rounded()))
        guard next != canvas else{return}
        remember();canvas=next;editedImage=true;needsDisplay=true;onChange?()
    }
    func fitCanvasToImages(){setCanvas(contentBounds.integral)}
    func padCanvas(_ amount:CGFloat){setCanvas(canvas.insetBy(dx:-amount,dy:-amount))}
    /// The colour behind the images: the capture's most common edge colour, as CleanShot does when expanding.
    var resolvedBackground:NSColor? {
        switch canvasBackground {
        case .clear:return nil
        case .white:return .white
        case .black:return .black
        case .auto:
            guard let first=layers.first else{return nil}
            if let cached=edgeColorCache,cached.id == first.id {return cached.color}
            let color=Self.edgeColor(of:first.image);edgeColorCache=(first.id,color);return color
        }
    }
    private var edgeColorCache:(id:UUID,color:NSColor?)?
    static func edgeColor(of image:NSImage)->NSColor? {
        guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil),let space=CGColorSpace(name:CGColorSpace.sRGB) else{return nil}
        let side=32
        var pixels=[UInt8](repeating:0,count:side*side*4)
        let drawn:Bool=pixels.withUnsafeMutableBytes{buffer in
            guard let context=CGContext(data:buffer.baseAddress,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            context.interpolationQuality = .medium;context.draw(cg,in:CGRect(x:0,y:0,width:side,height:side));return true
        }
        guard drawn else{return nil}
        var groups:[Int:[Int]]=[:]
        for y in 0..<side {for x in 0..<side where x==0 || y==0 || x==side-1 || y==side-1 {
            let i=(y*side+x)*4,key=Int(pixels[i]>>4)<<12|Int(pixels[i+1]>>4)<<8|Int(pixels[i+2]>>4)<<4|Int(pixels[i+3]>>4)
            groups[key,default:[]].append(i)
        }}
        guard let best=groups.max(by:{$0.value.count<$1.value.count}) else{return nil}
        let alpha=best.value.map{Double(pixels[$0+3])}.reduce(0,+)/Double(best.value.count)/255
        guard alpha>0.5 else{return nil}
        func channel(_ offset:Int)->CGFloat {CGFloat(best.value.map{Double(pixels[$0+offset])}.reduce(0,+)/Double(best.value.count)/255/alpha)}
        return NSColor(srgbRed:min(1,channel(0)),green:min(1,channel(1)),blue:min(1,channel(2)),alpha:1)
    }

    // MARK: Undo
    private var snapshot:Snapshot {Snapshot(layers:layers,canvas:canvas,marks:marks,edited:editedImage)}
    private func remember(){undoStates.append(snapshot);if undoStates.count>30{undoStates.removeFirst()};redoStates=[]}
    private func restore(_ state:Snapshot){selectedIndex=nil;selectedLayer=nil;layers=state.layers;canvas=state.canvas;marks=state.marks;editedImage=state.edited;current=nil;needsDisplay=true;detectText();onChange?()}
    func undo(){commitText();if let state=undoStates.popLast(){redoStates.append(snapshot);restore(state)}}
    func redo(){if let state=redoStates.popLast(){undoStates.append(snapshot);restore(state)}}
    func clear(){commitText();remember();selectedIndex=nil;marks=[];current=nil;needsDisplay=true;onChange?()}

    // MARK: Crop (one image) and adding images
    func applyCrop(){guard let rect=cropRect else{return};let index=cropLayer;cancelCrop();crop(to:rect,layer:index)}
    func cancelCrop(){cropAnchor=nil;cropRect=nil;cropMoveOrigin=nil;cropMoveRect=nil;needsDisplay=true;onChange?()}
    /// Crops one image layer (document points). A lone image keeps the canvas's working room around it.
    func crop(to rect:CGRect,layer:Int?=nil){
        guard let index=layer ?? layers.lastIndex(where:{$0.frame.intersects(rect)}),layers.indices.contains(index) else{return}
        let old=layers[index].frame,clipped=rect.intersection(old)
        guard clipped.width>=8,clipped.height>=8,let cg=layers[index].image.cgImage(forProposedRect:nil,context:nil,hints:nil) else{return}
        let sx=CGFloat(cg.width)/old.width,sy=CGFloat(cg.height)/old.height
        let pixels=CGRect(x:(clipped.minX-old.minX)*sx,y:(old.maxY-clipped.maxY)*sy,width:clipped.width*sx,height:clipped.height*sy).integral
        guard let cropped=cg.cropping(to:pixels) else{onStatus?("Crop failed; the image was kept unchanged.");return}
        remember()
        layers[index]=CanvasLayer(image:NSImage(cgImage:cropped,size:clipped.size),frame:clipped)
        if layers.count == 1 {canvas=CGRect(x:canvas.minX+clipped.minX-old.minX,y:canvas.minY+clipped.minY-old.minY,width:max(CanvasGeometry.minimumSide,canvas.width-(old.width-clipped.width)),height:max(CanvasGeometry.minimumSide,canvas.height-(old.height-clipped.height)))}
        editedImage=true;needsDisplay=true;detectText();onChange?();onStatus?("Cropped. Command-Z undoes this change.")
    }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation { isDocument ? .copy:[] }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        guard let urls=sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] else{return false}
        return combine(urls.compactMap{NSImage(contentsOf:$0)})
    }
    private func pasteImage(){
        guard let images=NSPasteboard.general.readObjects(forClasses:[NSImage.self]) as? [NSImage],!images.isEmpty else{onStatus?("The clipboard has no image to paste.");return}
        combine(images)
    }
    /// Adds images as movable layers below (or beside) the current content and grows the canvas to fit.
    @discardableResult func combine(_ images:[NSImage])->Bool {
        let images=images.filter{$0.size.width>0 && $0.size.height>0}
        guard !images.isEmpty,isDocument else{return false}
        let frames=CanvasGeometry.placements(for:images.map(\.size),after:contentBounds,horizontal:combineHorizontal)
        let added=zip(images,frames).map{CanvasLayer(image:$0.0,frame:$0.1)}
        let next=frames.reduce(canvas){$0.union($1)}
        let scale=max(exportScale,added.map(\.pixelScale).max() ?? 1)
        guard next.width*scale<=16000,next.height*scale<=16000,next.width*next.height*scale*scale<=64000000 else{onStatus?("Combined image is too large; use fewer or smaller images.");return false}
        remember();layers+=added;canvas=next;editedImage=true;tool = .select;selectedLayer=layers.count-1
        needsDisplay=true;detectText();onChange?()
        onStatus?(images.count == 1 ? "Image added as a layer. Drag it to move it; Delete removes it; Command-Z undoes it.":"\(images.count) images added as layers. Drag one to move it; Command-Z undoes it.")
        return true
    }

    // MARK: Text detection for the smart highlighter
    /// Recognised text lines on the visible parts of the images, in document points.
    var documentTextLines:[TextLine] {
        var result:[TextLine]=[]
        for (n,layer) in layers.enumerated() {
            let above=layers.dropFirst(n+1).map(\.frame)
            for line in textLines[layer.id] ?? [] {
                let mapped=line.mapped(into:layer.frame)
                if !above.contains(where:{$0.contains(CGPoint(x:mapped.frame.midX,y:mapped.frame.midY))}) {result.append(mapped)}
            }
        }
        return result
    }
    var isDetectingText:Bool {!textPending.isEmpty}
    /// Recognition runs on device, once per image, off the main thread.
    func detectText(){
        for layer in layers where textLines[layer.id] == nil && !textPending.contains(layer.id) {
            guard let cg=layer.image.cgImage(forProposedRect:nil,context:nil,hints:nil) else{continue}
            let id=layer.id;textPending.insert(id)
            Task.detached(priority:.userInitiated){
                let lines=TextSnap.recognizeLines(in:cg)
                await MainActor.run{[weak self] in self?.textLines[id]=lines;self?.textPending.remove(id)}
            }
        }
    }
    /// Test hook: supplies text lines (normalised to the layer) without running Vision.
    func setTextLines(_ lines:[TextLine],forLayer index:Int){guard layers.indices.contains(index) else{return};textLines[layers[index].id]=lines;textPending.remove(layers[index].id)}

    // MARK: Text entry
    private func beginText(at point: CGPoint) {
        let p = viewPoint(point)
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
        if !value.isEmpty { remember();marks.append(DrawingMark(tool: .text, points: [point], color: color, width: effectiveWidth, text: value,fontSize:textSize / viewScale)); redoMarks.removeAll(); onChange?() }
        needsDisplay = true
    }
    func controlTextDidEndEditing(_ obj: Notification) { commitText() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { entry?.removeFromSuperview(); entry = nil; entryPoint = nil; window?.makeFirstResponder(self);onTextFinished?();return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitText(); window?.makeFirstResponder(self); return true }
        return false
    }

    // MARK: Drawing
    override func draw(_ dirtyRect: NSRect) {
        guard isDocument else {
            NSColor.black.withAlphaComponent(0.008).setFill(); bounds.fill()
            for mark in marks { drawMark(mark) }
            if let current { drawMark(current) }
            return
        }
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        let s = viewScale, canvasView = viewRect(canvas)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -4); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
        (resolvedBackground ?? .white).setFill(); canvasView.fill()
        NSGraphicsContext.restoreGraphicsState()
        if resolvedBackground == nil { drawCheckerboard(in: canvasView) }
        NSGraphicsContext.current?.imageInterpolation = .high
        func drawContent() {
            for layer in layers { layer.image.draw(in: viewRect(layer.frame)) }
            NSGraphicsContext.saveGraphicsState()
            let o = viewOrigin, transform = NSAffineTransform(); transform.translateX(by: o.x, yBy: o.y); transform.scale(by: s); transform.concat()
            for mark in marks { drawMark(mark) }
            if let current { drawMark(current) }
            NSGraphicsContext.restoreGraphicsState()
        }
        // Content outside the canvas stays visible but faded, so it can be dragged back in.
        if let cg = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.saveGraphicsState()
            let outside = NSBezierPath(rect: bounds); outside.appendRect(canvasView); outside.windingRule = .evenOdd; outside.addClip()
            cg.setAlpha(0.35); cg.beginTransparencyLayer(auxiliaryInfo: nil); drawContent(); cg.endTransparencyLayer()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: canvasView).addClip(); drawContent(); NSGraphicsContext.restoreGraphicsState()
        // Overlays in view points.
        if let index = selectedIndex, marks.indices.contains(index) { dashedOutline(viewRect(boundsForMark(marks[index]).insetBy(dx: -5 / s, dy: -5 / s))) }
        if let index = selectedLayer, layers.indices.contains(index) { dashedOutline(viewRect(layers[index].frame).insetBy(dx: -2, dy: -2)) }
        if let cropRect, let index = cropLayer, layers.indices.contains(index) {
            let crop = viewRect(cropRect), shade = NSBezierPath(rect: viewRect(layers[index].frame)); shade.appendRect(crop); shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill(); shade.fill()
            NSColor.systemCyan.setStroke(); let outline = NSBezierPath(rect: crop); outline.lineWidth = 2; outline.stroke()
            NSColor.white.setFill()
            for p in [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.maxY)] { NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill() }
        }
        if tool == .select {
            for x in [canvasView.minX, canvasView.midX, canvasView.maxX] { for y in [canvasView.minY, canvasView.midY, canvasView.maxY] where x != canvasView.midX || y != canvasView.midY {
                let handle = NSBezierPath(roundedRect: CGRect(x: x - 4, y: y - 4, width: 8, height: 8), xRadius: 2, yRadius: 2)
                NSColor.white.setFill(); handle.fill(); NSColor.controlAccentColor.setStroke(); handle.lineWidth = 1.5; handle.stroke()
            } }
        }
    }
    private func dashedOutline(_ rect: CGRect) {
        NSColor.controlAccentColor.setStroke(); let border = NSBezierPath(rect: rect); border.lineWidth = 1.5; border.setLineDash([5, 3], count: 2, phase: 0); border.stroke()
    }
    private func drawCheckerboard(in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
        NSColor(white: 0.82, alpha: 1).setFill()
        let side: CGFloat = 8
        var y = rect.minY
        while y < rect.maxY { var x = rect.minX + (Int((y - rect.minY) / side) % 2 == 0 ? 0 : side); while x < rect.maxX { CGRect(x: x, y: y, width: side, height: side).fill(); x += side * 2 }; y += side }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMark(_ mark: DrawingMark) {
        guard let a = mark.points.first else { return }
        let b = mark.points.last ?? a
        mark.color.setStroke(); mark.color.setFill()
        let path = NSBezierPath(); path.lineWidth = mark.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch mark.tool {
        case .pen, .highlighter:
            if mark.tool == .highlighter {
                // Multiply keeps dark text legible under the highlight, like a real marker.
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.compositingOperation = .multiply
                if !mark.rects.isEmpty {
                    mark.color.withAlphaComponent(0.5).setFill()
                    let bands = NSBezierPath(); for r in mark.rects { bands.appendRoundedRect(r, xRadius: r.height * 0.18, yRadius: r.height * 0.18) }
                    bands.windingRule = .nonZero; bands.fill()
                } else {
                    mark.color.withAlphaComponent(0.32).setStroke();path.lineWidth=max(mark.width,18)
                    path.move(to: a); for p in mark.points.dropFirst() { path.line(to: p) }; path.stroke()
                }
                NSGraphicsContext.restoreGraphicsState(); return
            }
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
        case .filledRectangle, .redact:
            let rect=CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y))
            if mark.tool == .redact {NSColor.black.setFill()}
            NSBezierPath(rect:rect).fill()
        case .number:
            let radius=max(14,mark.fontSize * 0.7)
            NSBezierPath(ovalIn:CGRect(x:a.x-radius,y:a.y-radius,width:radius*2,height:radius*2)).fill()
            let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:radius,weight:.bold),.foregroundColor:NSColor.white]
            let size=(mark.text as NSString).size(withAttributes:attrs)
            (mark.text as NSString).draw(at:CGPoint(x:a.x-size.width/2,y:a.y-size.height/2),withAttributes:attrs)
        case .crop, .eraser, .select:break
        case .line:path.move(to:a);path.line(to:b);path.stroke()
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: mark.fontSize, weight: .semibold), .foregroundColor: mark.color]
            (mark.text as NSString).draw(at: a, withAttributes: attrs)
        }
    }

    /// Renders the canvas at the sharpest image's pixel density; zoom never resamples the export.
    func renderedPNG() throws -> Data {
        guard !hasPendingCrop else {throw NSError(domain:"CaptureTools",code:3,userInfo:[NSLocalizedDescriptionKey:"Apply or cancel the crop before saving, copying or exporting."])}
        commitText()
        let scale = exportScale
        let width = Int((canvas.width * scale).rounded()), height = Int((canvas.height * scale).rounded())
        guard isDocument, width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 64000000,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "CaptureTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot render this screenshot"])
        }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.imageInterpolation = .high
        if let fill = resolvedBackground { fill.setFill(); CGRect(x: 0, y: 0, width: width, height: height).fill() }
        let transform = NSAffineTransform(); transform.scaleX(by: CGFloat(width) / canvas.width, yBy: CGFloat(height) / canvas.height); transform.translateX(by: -canvas.minX, yBy: -canvas.minY); transform.concat()
        for layer in layers { layer.image.draw(in: layer.frame) }
        for mark in marks { drawMark(mark) }
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        // Keep the point size so Retina captures stay 144 dpi instead of doubling in other apps.
        bitmap.size = canvas.size
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "CaptureTools", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode this screenshot"]) }
        return data
    }

    func flattenSavedImage(_ image: NSImage) { selectedIndex=nil;selectedLayer=nil; layers=[CanvasLayer(image:image,frame:canvas)]; marks.removeAll(); redoMarks.removeAll();undoStates=[];redoStates=[];editedImage=false;needsDisplay = true;detectText() }
}
