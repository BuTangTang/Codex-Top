// Rebuild the share cards with: swift docs/share/xiaohongshu/render.swift
// App screenshots are embedded as captured; only the surrounding layout is drawn.
import AppKit
import SwiftUI

let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repo = base.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let output = base.appendingPathComponent("effects")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width: CGFloat = 1080, height: CGFloat = 1080

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let ink = color(0xF1F3F6), secondary = color(0x8993A2), blue = color(0x689CF0), orange = color(0xD5A34E)
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: height - y - h, width: w, height: h)
}
func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: NSColor, radius: CGFloat = 0) {
    fill.setFill(); NSBezierPath(roundedRect: rect(x,y,w,h), xRadius: radius, yRadius: radius).fill()
}
func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ tint: NSColor, _ weight: CGFloat = 1) {
    let p = NSBezierPath(); p.move(to: NSPoint(x: x1, y: height-y1)); p.line(to: NSPoint(x: x2, y: height-y2))
    p.lineWidth = weight; tint.setStroke(); p.stroke()
}
func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
           _ tint: NSColor = ink, _ weight: NSFont.Weight = .regular,
           _ w: CGFloat = 920, _ h: CGFloat = 160, alignment: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle(); style.alignment = alignment; style.lineSpacing = 8
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint, .paragraphStyle: style]
    let content = NSAttributedString(string: text, attributes: attributes)
    let required = content.boundingRect(with: NSSize(width: w, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    precondition(required.height <= h + 2, "Text overflows: \(text)")
    content.draw(with: rect(x,y,w,h), options: [.usesLineFragmentOrigin, .usesFontLeading])
}
func photo(_ file: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ radius: CGFloat = 20, shadow: Bool = true, squareTop: Bool = false) {
    let image = NSImage(contentsOf: base.appendingPathComponent("screenshots/\(file)"))!
    let h = w * image.size.height / image.size.width
    let target = rect(x,y,w,h)
    let curve: RoundedCornerStyle = file.hasPrefix("orb-") ? .circular : .continuous
    let outline = NSBezierPath(cgPath: RoundedRectangle(cornerRadius: radius, style: curve).path(in: target).cgPath)
    if squareTop { outline.appendRect(rect(x,y,w,radius)) }
    NSGraphicsContext.saveGraphicsState()
    if shadow {
        let s = NSShadow(); s.shadowOffset = NSSize(width: 0, height: -18); s.shadowBlurRadius = 42
        s.shadowColor = color(0x000000, 0.45); s.set()
        color(0x000000).setFill(); outline.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    outline.addClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}
func background() {
    let gradient = NSGradient(starting: color(0x0B0D11), ending: color(0x171B23))!
    gradient.draw(in: rect(0,0,width,height), angle: -65)
    let wash = NSGradient(colors: [color(0x314359,0.14), color(0x314359,0)])!
    wash.draw(fromCenter: NSPoint(x: 600,y: 520), radius: 0,
              toCenter: NSPoint(x: 600,y: 520), radius: 700, options: .drawsAfterEndingLocation)
}
func brand(_ number: Int) {
    let logo = NSImage(contentsOf: repo.appendingPathComponent("Resources/AppIcon.png"))!
    logo.draw(in: rect(64,61,55,55))
    label("Codex Top",135,67,29,ink,.semibold,600,55)
    label("黑色主题",820,75,21,secondary,.medium,190,40,alignment:.right)
}
func footer(_ number: Int) {
    label(number == 1 ? "44pt 圆环 · 图中等比放大展示" : "常驻浮窗 · 90% 应用比例",72,1006,20,secondary,.regular,700,40)
    label("真实窗口 · 示例任务",700,1006,20,secondary,.regular,310,40,alignment:.right)
}
func card(_ filename: String, _ number: Int, _ body: () -> Void) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    background(); brand(number); body(); footer(number)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
    print(filename)
}

try card("01-orb.png",1) {
    label("圆环",72,183,30,ink,.medium,430,60)
    label("点开展开",575,183,30,ink,.medium,435,60)
    // Two separately captured native states, placed on one quiet background.
    photo("orb-dark.jpg",183,462,88,44,shadow:true)
    line(325,506,468,506,color(0x637084),1.5)
    line(459,498,468,506,color(0x637084),1.5)
    line(459,514,468,506,color(0x637084),1.5)
    photo("panel-dark.jpg",510,339,480,18 * 480 / 369)
    label("收起时，只留一个小圆环",72,711,23,secondary,.regular,425,55)
    label("需要时，点开看任务",575,711,23,secondary,.regular,435,55)
}

try card("02-pinned.png",2) {
    label("钉住，留在眼前。",72,183,30,ink,.medium,920,60)
    photo("floating-dark.jpg",270,401,540,18 * 540 / 324)
    // This leader points at the actual blue pin in the captured window.
    line(716,404,716,326,blue,1.5)
    line(716,326,812,326,blue,1.5)
    label("图钉已开启",832,308,23,blue,.medium,190,45)
    label("常驻置顶  ·  顶部可拖动",72,803,24,secondary,.regular,936,55,alignment:.center)
}
