import Cocoa
@main struct TitlebarTests {
    static func main() {
        let parent = NSView(frame:NSRect(x:0,y:0,width:600,height:400))
        let overlay = TitlebarDragView(frame:parent.bounds)
        parent.addSubview(overlay)
        overlay.regions = [NSRect(x:100,y:0,width:500,height:76)]
        overlay.exclusions = [NSRect(x:300,y:20,width:40,height:35)]
        overlay.enabled = true
        precondition(overlay.hitTest(NSPoint(x:150,y:360)) === overlay)
        precondition(overlay.hitTest(NSPoint(x:310,y:360)) == nil)
        precondition(overlay.hitTest(NSPoint(x:150,y:200)) == nil)
        precondition(overlay.hitTest(NSPoint(x:50,y:360)) == nil)
        overlay.enabled = false
        precondition(overlay.hitTest(NSPoint(x:150,y:360)) == nil)
        print("PASS: native titlebar hit testing, flipped coordinates, button exclusion, editor passthrough, modal disabling")
    }
}
