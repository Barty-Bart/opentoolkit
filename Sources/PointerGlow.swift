import AppKit
import Combine

/// A soft glow around the pointer while "Hey Toolkit" is waiting for a command, so it's
/// clear the app is listening. It fades as soon as the command runs or the window closes.
@MainActor final class PointerGlow {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "wakePointerGlow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wakePointerGlow") }
    }
    private var panel: NSPanel?
    private var timer: Timer?
    private var observer: AnyCancellable?

    func bind(to voice: VoiceBridge) {
        observer = voice.$state.map { $0.awaitingCommand == true }.removeDuplicates().sink { [weak self] listening in
            if listening && Self.enabled { self?.show() } else { self?.hide() }
        }
    }

    private func show() {
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        follow(); panel.alphaValue = 0; panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.15; panel.animator().alphaValue = 1 }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.follow() } }
    }

    private func hide() {
        timer?.invalidate(); timer = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in context.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    private func follow() {
        guard let panel else { return }
        let p = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(x: p.x - panel.frame.width / 2, y: p.y - panel.frame.height / 2))
    }

    private static func makePanel() -> NSPanel {
        let size: CGFloat = 80
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = GlowView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        return panel
    }
}

private final class GlowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // Concentric rings fading outwards read as a soft halo without hiding the pointer.
        for step in 0..<7 {
            let radius = 12 + CGFloat(step) * 4
            NSColor.systemTeal.withAlphaComponent(0.34 - CGFloat(step) * 0.045).setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 4; ring.stroke()
        }
    }
}
