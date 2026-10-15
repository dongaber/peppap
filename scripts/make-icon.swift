// Рисует иконку Peppap: тёмный скруглённый квадрат, «челка» сверху и оранжевая ✻.
// Использование: swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Peppap.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Сетка иконок macOS: поле ~10% по краям.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let body = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.04, alpha: 1))!.draw(in: body, angle: -90)

    // Челка.
    let notchW = rect.width * 0.42, notchH = rect.height * 0.12
    let notch = NSBezierPath(roundedRect: NSRect(x: rect.midX - notchW / 2, y: rect.maxY - notchH, width: notchW, height: notchH * 2),
                             xRadius: notchH * 0.7, yRadius: notchH * 0.7)
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    NSColor.black.setFill()
    notch.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // ✻
    let orange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    let font = NSFont.systemFont(ofSize: rect.height * 0.52, weight: .bold)
    let str = NSAttributedString(string: "✻", attributes: [.font: font, .foregroundColor: orange])
    let size = str.size()
    str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - rect.height * 0.04))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: tmp.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: tmp.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Иконка: \(out)" : "iconutil завершился с ошибкой")
