import Cocoa

// A transparent native hit-test layer over titlebar whitespace only.
// WebKit keeps all input events outside those rectangles.
final class TitlebarDragView: NSView {
    var regions: [NSRect] = []
    var exclusions: [NSRect] = []
    var enabled = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard enabled, !isHidden, bounds.contains(local), regions.contains(where: { $0.contains(local) }), !exclusions.contains(where: { $0.contains(local) }) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.miniaturize(nil) }
            else if action != "None" { window.performZoom(nil) }
        } else {
            window.performDrag(with: event)
        }
    }
}
