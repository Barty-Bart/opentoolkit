import AppKit
import SwiftUI

/// A real file URL supports attachments and Finder; image representations support image-only editors.
func captureDragItem(url:URL) -> NSPasteboardItem? {
    guard let data=try? Data(contentsOf:url),let image=NSImage(data:data) else{return nil}
    let item=NSPasteboardItem()
    item.setString(url.absoluteString,forType:.fileURL)
    item.setData(data,forType:.png)
    if let tiff=image.tiffRepresentation {item.setData(tiff,forType:.tiff)}
    return item
}
struct CaptureDragPreview:NSViewRepresentable {
    let url:URL
    var onClick:(()->Void)?
    var onOpen:(()->Void)?
    var onDropped:(()->Void)?
    var contextMenu:NSMenu?
    func makeNSView(context:Context)->CaptureDragImageView {CaptureDragImageView()}
    func updateNSView(_ view:CaptureDragImageView,context:Context) {
        view.url=url;view.image=captureThumbnail(url,maxPixels:420)
        view.onClick=onClick;view.onOpen=onOpen;view.onDropped=onDropped;view.menu=contextMenu
    }
}
final class CaptureDragImageView:NSView,NSDraggingSource {
    var image:NSImage? {didSet{needsDisplay=true}}
    var url:URL?
    var onClick:(()->Void)?
    var onOpen:(()->Void)?
    var onDropped:(()->Void)?
    private var origin=CGPoint.zero
    private var dragging=false
    private var contextClick=false
    override init(frame:NSRect) {super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.image);setAccessibilityLabel("Screenshot preview. Double-click to edit, or drag into another app.")}
    required init?(coder:NSCoder){fatalError()}
    override func draw(_ dirtyRect:NSRect) {
        guard let image else{return}
        let scale=min(bounds.width/max(image.size.width,1),bounds.height/max(image.size.height,1))
        let size=CGSize(width:image.size.width*scale,height:image.size.height*scale)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in:CGRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height))
    }
    override func mouseDown(with event:NSEvent){
        contextClick=event.modifierFlags.contains(.control) && menu != nil
        if contextClick {rightMouseDown(with:event);return}
        origin=convert(event.locationInWindow,from:nil);dragging=false
    }
    override func mouseUp(with event:NSEvent){guard !dragging,!contextClick else{return};if event.clickCount>=2 {onOpen?()}else{onClick?()}}
    override func rightMouseDown(with event:NSEvent){
        guard let menu else{super.rightMouseDown(with:event);return}
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    override func mouseDragged(with event:NSEvent){
        let point=convert(event.locationInWindow,from:nil)
        guard !contextClick,!dragging,hypot(point.x-origin.x,point.y-origin.y)>4,let url,let item=captureDragItem(url:url),let image else{return}
        dragging=true
        let drag=NSDraggingItem(pasteboardWriter:item)
        let scale=min(bounds.width/max(image.size.width,1),bounds.height/max(image.size.height,1))
        let size=CGSize(width:image.size.width*scale,height:image.size.height*scale)
        drag.setDraggingFrame(CGRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height),contents:image)
        beginDraggingSession(with:[drag],event:event,source:self)
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation {.copy}
    func ignoreModifierKeys(for session:NSDraggingSession)->Bool {true}
    func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation){
        // Only a drop another app accepted counts; a cancelled drag keeps the thumbnail.
        if !operation.isEmpty {DispatchQueue.main.async{[weak self] in self?.onDropped?()}}
    }
}
