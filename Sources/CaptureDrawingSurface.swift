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
}

@MainActor
final class DrawingSurface: NSView, NSTextFieldDelegate {
    var image: NSImage?
    var tool: DrawingTool = .pen { didSet { if tool != .select { selectedIndex=nil }; needsDisplay=true; onToolChange?() } }
    var zoomScale: CGFloat? = nil
    var onToolChange: (() -> Void)?
    private(set) var selectedIndex: Int?
    private var moveOrigin: CGPoint?
    private var movePoints: [CGPoint] = []
    private var moveRemembered = false
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
        let scale = zoomScale ?? min(1, min(inset.width / max(image.size.width, 1), inset.height / max(image.size.height, 1)))
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
        if tool == .select {
            selectedIndex=marks.lastIndex(where:{boundsForMark($0).insetBy(dx:-8,dy:-8).contains(p)})
            moveOrigin=p;movePoints=selectedIndex.map{marks[$0].points} ?? [];moveRemembered=false
            needsDisplay=true;onChange?();return
        }
        if tool == .number {
            let next=(marks.filter{$0.tool == .number}.compactMap{Int($0.text)}.max() ?? 0)+1
            remember();marks.append(DrawingMark(tool:.number,points:[p],color:color,width:effectiveWidth,text:String(next),fontSize:textSize));needsDisplay=true;onChange?();return
        }
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
        if tool == .select,let index=selectedIndex,marks.indices.contains(index),let origin=moveOrigin {
            if !moveRemembered {remember();moveRemembered=true}
            let p=canvasPoint(event);let dx=p.x-origin.x,dy=p.y-origin.y
            marks[index].points=movePoints.map{CGPoint(x:$0.x+dx,y:$0.y+dy)}
            needsDisplay=true;onChange?();return
        }
        if tool == .eraser {erase(at:canvasPoint(event));return}
        if let origin=cropMoveOrigin,let original=cropMoveRect {
            let p=canvasPoint(event)
            cropRect=CGRect(x:max(0,min(canvasSize.width-original.width,original.minX+p.x-origin.x)),y:max(0,min(canvasSize.height-original.height,original.minY+p.y-origin.y)),width:original.width,height:original.height)
            needsDisplay=true;return
        }
        if let anchor=cropAnchor {let p=canvasPoint(event);cropRect=CGRect(x:min(anchor.x,p.x),y:min(anchor.y,p.y),width:abs(p.x-anchor.x),height:abs(p.y-anchor.y));needsDisplay=true;return}
        guard var mark = current else { return }
        let p = canvasPoint(event)
        if mark.tool == .pen || mark.tool == .highlighter { mark.points.append(p) } else { mark.points[1] = p }
        current = mark; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if tool == .select {moveOrigin=nil;movePoints=[];moveRemembered=false;return}
        if cropAnchor != nil || cropMoveOrigin != nil {cropAnchor=nil;cropMoveOrigin=nil;cropMoveRect=nil;needsDisplay=true;onStatus?("Adjust the crop by dragging its corners or centre. Return or Apply Crop confirms; Escape cancels.");onChange?();return}
        guard let mark = current else { return }
        addAnnotation(mark); current = nil; redoMarks.removeAll(); needsDisplay = true; onChange?()
    }
    override func keyDown(with event: NSEvent) {
        if [51,117].contains(event.keyCode),selectedIndex != nil {deleteSelection();return}
        if event.keyCode == 36,hasPendingCrop {applyCrop();return}
        if event.keyCode == 53 {if hasPendingCrop || cropAnchor != nil {cancelCrop()}else{onEscape?()};return}
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }; return
        }
        let shortcuts: [String: DrawingTool] = ["v": .select,"p": .pen, "a": .arrow, "r": .rectangle, "o": .ellipse, "t": .text,"c": .crop]
        if let key = event.charactersIgnoringModifiers, let next = shortcuts[key] { tool = next; return }
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
        if mark.tool == .text {return CGRect(origin:a,size:(mark.text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:mark.fontSize,weight:.semibold)]))}
        if mark.tool == .number {return CGRect(x:a.x-16,y:a.y-16,width:32,height:32)}
        let xs=mark.points.map(\.x),ys=mark.points.map(\.y)
        return CGRect(x:xs.min()!,y:ys.min()!,width:max(1,xs.max()!-xs.min()!),height:max(1,ys.max()!-ys.min()!)).insetBy(dx:-mark.width/2,dy:-mark.width/2)
    }
    func deleteSelection(){guard let index=selectedIndex,marks.indices.contains(index) else{return};remember();marks.remove(at:index);selectedIndex=nil;needsDisplay=true;onChange?()}
    func changeSelectedColor(_ color:NSColor){self.color=color;guard let index=selectedIndex,marks.indices.contains(index) else{return};remember();marks[index].color=color;needsDisplay=true;onChange?()}
    func changeSelectedWidth(_ width:CGFloat){strokeWidth=width;guard let index=selectedIndex,marks.indices.contains(index) else{return};remember();marks[index].width=effectiveWidth;needsDisplay=true;onChange?()}
    private var snapshot:Snapshot {Snapshot(image:image,marks:marks,edited:editedImage)}
    private func remember(){undoStates.append(snapshot);if undoStates.count>20{undoStates.removeFirst()};redoStates=[]}
    private func restore(_ state:Snapshot){selectedIndex=nil;image=state.image;marks=state.marks;editedImage=state.edited;current=nil;needsDisplay=true;onChange?()}
    func undo(){commitText();if let state=undoStates.popLast(){redoStates.append(snapshot);restore(state)}}
    func redo(){if let state=redoStates.popLast(){undoStates.append(snapshot);restore(state)}}
    func clear(){commitText();remember();selectedIndex=nil;marks=[];current=nil;needsDisplay=true;onChange?()}
    func applyCrop(){guard let rect=cropRect else{return};cancelCrop();crop(to:rect)}
    func cancelCrop(){cropAnchor=nil;cropRect=nil;cropMoveOrigin=nil;cropMoveRect=nil;needsDisplay=true;onChange?()}
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
        if image != nil { NSColor.controlBackgroundColor.setFill(); bounds.fill() }
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
        if let index=selectedIndex,marks.indices.contains(index) {
            NSColor.controlAccentColor.setStroke();let border=NSBezierPath(rect:boundsForMark(marks[index]).insetBy(dx:-5,dy:-5));border.lineWidth=1.5*size.width/max(rect.width,1);border.setLineDash([5,3],count:2,phase:0);border.stroke()
        }
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
        case .pen, .highlighter:
            if mark.tool == .highlighter {mark.color.withAlphaComponent(0.32).setStroke();path.lineWidth=max(mark.width,18)}
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
        // Keep the point size so Retina captures stay 144 dpi instead of doubling in other apps.
        bitmap.size = image.size
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "CaptureTools", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode this screenshot"]) }
        return data
    }

    func flattenSavedImage(_ image: NSImage) { selectedIndex=nil; self.image = image; marks.removeAll(); redoMarks.removeAll();undoStates=[];redoStates=[];editedImage=false;needsDisplay = true }
}

