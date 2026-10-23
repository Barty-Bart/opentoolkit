import AppKit
import CoreVideo
import QuartzCore

/// Cursor options for screen recordings and GIFs. They are drawn only into the video;
/// the user's own screen and pointer stay unchanged. All off by default.
struct CursorEffects: Equatable {
    var scale: CGFloat = 1
    var highlight = false
    var clicks = false
    var colorName = "Yellow"
    var active: Bool { scale > 1 || highlight || clicks }
    static let sizes: [(name: String, scale: CGFloat)] = [("Normal", 1), ("Large", 1.6), ("Extra large", 2.2)]
    static let colors: [(name: String, color: NSColor)] = [("Yellow", .systemYellow), ("Blue", .systemBlue), ("Pink", .systemPink), ("Green", .systemGreen), ("Red", .systemRed), ("White", .white)]
    var color: NSColor { Self.colors.first { $0.name == colorName }?.color ?? .systemYellow }
    static var current: CursorEffects {
        let d = UserDefaults.standard
        return CursorEffects(scale: CGFloat(d.object(forKey: "recordingCursorScale") as? Double ?? 1),
                             highlight: d.bool(forKey: "recordingHighlight"), clicks: d.bool(forKey: "recordingClicks"),
                             colorName: d.string(forKey: "recordingEffectColor") ?? "Yellow")
    }
}

/// Pointer position, cursor image and recent clicks, sampled on the main thread and read
/// by the recording writer queue.
final class CursorTracker: @unchecked Sendable {
    struct Snapshot {
        var location: CGPoint = .zero
        var cursor: CGImage?
        var cursorSize: CGSize = .zero
        var hotSpot: CGPoint = .zero
        var clicks: [(point: CGPoint, time: CFTimeInterval)] = []
    }
    private let lock = NSLock()
    private var state = Snapshot()
    private var timer: Timer?
    private var monitors: [Any] = []
    private weak var lastCursor: NSCursor?

    @MainActor func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.sample() } }
        let click: (NSEvent) -> Void = { [weak self] _ in self?.recordClick() }
        // Mouse-button monitors need no Accessibility permission.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: click) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { click($0); return $0 }) { monitors.append(local) }
    }
    @MainActor func stop() {
        timer?.invalidate(); timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
    }
    @MainActor private func sample() {
        let location = NSEvent.mouseLocation
        var image: CGImage?, size = CGSize.zero, hotSpot = CGPoint.zero, changed = false
        if let cursor = NSCursor.currentSystem, cursor !== lastCursor {
            lastCursor = cursor; changed = true
            size = cursor.image.size; hotSpot = cursor.hotSpot
            image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        lock.lock(); state.location = location
        if changed { state.cursor = image; state.cursorSize = size; state.hotSpot = hotSpot }
        lock.unlock()
    }
    private func recordClick() {
        let point = NSEvent.mouseLocation, now = CACurrentMediaTime()
        lock.lock(); state.clicks = state.clicks.filter { now - $0.time < 1 } + [(point, now)]; lock.unlock()
    }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return state }
}

enum CursorOverlay {
    static let rippleDuration: CFTimeInterval = 0.6
    /// Draw the effects into a BGRA frame showing `region` (global AppKit coordinates).
    static func draw(_ snap: CursorTracker.Snapshot, effects: CursorEffects, region: CGRect, into buffer: CVPixelBuffer, now: CFTimeInterval) {
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard region.width > 0, region.height > 0, let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let sx = CGFloat(width) / region.width, sy = CGFloat(height) / region.height
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - region.minX) * sx, y: (p.y - region.minY) * sy) }
        let color = effects.color.usingColorSpace(.sRGB) ?? .systemYellow
        if effects.clicks {
            for click in snap.clicks where now - click.time < rippleDuration && now >= click.time {
                let t = CGFloat((now - click.time) / rippleDuration), c = pixel(click.point), r = (8 + 28 * t) * sx
                context.setStrokeColor(color.withAlphaComponent(0.85 * (1 - t)).cgColor); context.setLineWidth(3 * sx)
                context.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
        }
        let p = pixel(snap.location)
        if effects.highlight {
            let r = 24 * sx, ring = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            context.setFillColor(color.withAlphaComponent(0.3).cgColor); context.fillEllipse(in: ring)
            context.setStrokeColor(color.withAlphaComponent(0.75).cgColor); context.setLineWidth(2 * sx); context.strokeEllipse(in: ring)
        }
        if effects.scale > 1, let cursor = snap.cursor {
            let s = effects.scale * sx, size = CGSize(width: snap.cursorSize.width * s, height: snap.cursorSize.height * s)
            // NSCursor hot spots are measured from the image's top-left corner.
            context.interpolationQuality = .high
            context.draw(cursor, in: CGRect(x: p.x - snap.hotSpot.x * s, y: p.y - (snap.cursorSize.height - snap.hotSpot.y) * s, width: size.width, height: size.height))
        }
    }
}

import SwiftUI

/// Recording page: cursor size, highlight ring and click ripples (drawn only into recordings).
struct CursorEffectsSettings: View {
    @AppStorage("recordingCursorScale") private var scale = 1.0
    @AppStorage("recordingHighlight") private var highlight = false
    @AppStorage("recordingClicks") private var clicks = false
    @AppStorage("recordingEffectColor") private var colorName = "Yellow"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Cursor size", selection: $scale) { ForEach(CursorEffects.sizes, id: \.name) { Text($0.name).tag(Double($0.scale)) } }.pickerStyle(.segmented)
            Toggle("Highlight the cursor", isOn: $highlight)
            Toggle("Show clicks", isOn: $clicks)
            HStack(spacing: 6) {
                Text("Highlight and click colour").padding(.trailing, 6)
                ForEach(CursorEffects.colors, id: \.name) { option in
                    Button { colorName = option.name } label: {
                        Circle().fill(Color(nsColor: option.color)).frame(width: 18, height: 18)
                            .overlay { Circle().strokeBorder(.white, lineWidth: colorName == option.name ? 2 : 0).padding(-3) }
                    }.buttonStyle(.plain).help(option.name)
                }
                Spacer()
            }.opacity(highlight || clicks ? 1 : 0.4)
            Text("These appear only in the recording or GIF; your own screen and pointer stay as they are.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Compact version for the capture bar.
struct CursorEffectsMenu: View {
    @AppStorage("recordingCursorScale") private var scale = 1.0
    @AppStorage("recordingHighlight") private var highlight = false
    @AppStorage("recordingClicks") private var clicks = false
    var body: some View {
        Menu {
            Picker("Cursor size", selection: $scale) { ForEach(CursorEffects.sizes, id: \.name) { Text($0.name).tag(Double($0.scale)) } }
            Toggle("Highlight the cursor", isOn: $highlight)
            Toggle("Show clicks", isOn: $clicks)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: highlight || clicks || scale > 1 ? "cursorarrow.rays" : "cursorarrow").font(.system(size: 18))
                Text("Cursor").font(.system(size: 10, weight: .medium))
            }.frame(width: 58, height: 52)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Cursor size, highlight and clicks in recordings")
    }
}
