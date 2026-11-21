import AppKit

let destination = CommandLine.arguments[1]
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 32, y: 32, width: 960, height: 960)
let shape = NSBezierPath(roundedRect: rect, xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(calibratedRed: 0.26, green: 0.63, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.78, alpha: 1))!.draw(in: shape, angle: -85)
let symbol = NSImage(systemSymbolName: "internaldrive.fill", accessibilityDescription: nil)!
let config = NSImage.SymbolConfiguration(pointSize: 500, weight: .regular)
let icon = symbol.withSymbolConfiguration(config)!
NSColor.white.setFill()
icon.draw(in: NSRect(x: 204, y: 275, width: 616, height: 450), from: .zero, operation: .sourceOver, fraction: 1)
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
let data = representation.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: destination))
