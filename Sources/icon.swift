import AppKit
let destination = CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let n = CGFloat(size)
    let image = NSImage(size: NSSize(width:n,height:n))
    image.lockFocus()
    let tile = NSBezierPath(roundedRect: NSRect(x:n*0.06,y:n*0.06,width:n*0.88,height:n*0.88), xRadius:n*0.2,yRadius:n*0.2)
    NSGradient(starting:NSColor(calibratedRed:0.96,green:0.97,blue:0.99,alpha:1),ending:NSColor(calibratedRed:0.79,green:0.85,blue:0.92,alpha:1))!.draw(in:tile,angle:-70)
    // Original page-and-ink artwork; no SF Symbol is exported as an app icon.
    let paper = NSBezierPath(roundedRect: NSRect(x:n*0.27,y:n*0.20,width:n*0.46,height:n*0.60), xRadius:n*0.045,yRadius:n*0.045)
    NSColor(calibratedWhite:1,alpha:0.88).setFill(); paper.fill()
    NSColor(calibratedRed:0.29,green:0.39,blue:0.52,alpha:1).setStroke()
    let ink = NSBezierPath(); ink.lineWidth = max(1,n*0.026); ink.lineCapStyle = .round
    for (y,length) in [(0.65,0.23),(0.53,0.29),(0.41,0.18)] {
        ink.move(to:NSPoint(x:n*0.355,y:n*y)); ink.line(to:NSPoint(x:n*(0.355+length),y:n*y))
    }
    ink.stroke()
    NSColor(calibratedRed:0.35,green:0.52,blue:0.72,alpha:1).setFill()
    NSBezierPath(ovalIn:NSRect(x:n*0.61,y:n*0.245,width:n*0.065,height:n*0.065)).fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
    let data = bitmap.representation(using:.png,properties:[:])!
    if size <= 512 { try! data.write(to:URL(fileURLWithPath:destination+"/icon_\(size)x\(size).png")) }
    if size >= 32 { try! data.write(to:URL(fileURLWithPath:destination+"/icon_\(size/2)x\(size/2)@2x.png")) }
}
