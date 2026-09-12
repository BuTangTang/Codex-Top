// Rebuild the share cards with: swift docs/share/xiaohongshu/render.swift
// App screenshots are embedded as captured; only the surrounding layout is drawn.
import AppKit

let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repo = base.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let output = base.appendingPathComponent("posters")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width: CGFloat = 1080, height: CGFloat = 1440

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let ink = color(0x172332), secondary = color(0x667383), blue = color(0x3474D4), orange = color(0xDE873C)
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
    let outline = NSBezierPath(roundedRect: target, xRadius: radius, yRadius: radius)
    if squareTop { outline.appendRect(rect(x,y,w,radius)) }
    NSGraphicsContext.saveGraphicsState()
    if shadow {
        let s = NSShadow(); s.shadowOffset = NSSize(width: 0, height: -18); s.shadowBlurRadius = 42
        s.shadowColor = color(0x18324E, 0.16); s.set()
        color(0xE1E2E3).setFill(); outline.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    outline.addClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}
func background() {
    let gradient = NSGradient(starting: color(0xF8FAFC), ending: color(0xE7EEF7))!
    gradient.draw(in: rect(0,0,width,height), angle: -70)
    let wash = NSGradient(colors: [color(0xB6CAE7,0.20),color(0xB6CAE7,0)])!
    wash.draw(fromCenter: NSPoint(x: 910,y: 730), radius: 0,
              toCenter: NSPoint(x: 910,y: 730), radius: 750, options: .drawsAfterEndingLocation)
}
func brand(_ number: Int) {
    let logo = NSImage(contentsOf: repo.appendingPathComponent("Resources/AppIcon.png"))!
    logo.draw(in: rect(75,63,72,72))
    label("Codex Top",162,75,31,ink,.semibold,600,55)
    label(String(format:"%02d / 04",number),830,82,22,secondary,.medium,170,40,alignment:.right)
}
func footer(_ number: Int) {
    line(80,1311,1000,1311,color(0xCED7E1))
    label("macOS 14+  ·  开源社区项目",80,1341,22,secondary,.medium,600,40)
    label(number == 4 ? "公开资料 · 2026.09.12" : "真实窗口 · 示例任务",670,1341,22,secondary,.regular,330,40,alignment:.right)
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

try card("01-cover.png",1) {
    label("给 Codex",80,207,84,ink,.semibold,920,120)
    label("一个桌面小挂件",80,311,84,ink,.semibold,920,120)
    label("简单看任务，自由选位置。",84,456,32,secondary,.regular,900,70)
    box(84,555,54,5,orange,radius:2.5)
    // A quiet display stage, with no personal desktop or invented app UI.
    box(80,615,920,428,color(0xFFFFFF,0.42),radius:32)
    photo("floating-light.jpg",275,674,530,24)
    label("关注任务，四种方式随手切换。",80,1111,34,ink,.medium,920,60,alignment:.center)
    label("刘海  /  浮窗  /  圆环  /  状态栏",80,1176,25,secondary,.regular,920,50,alignment:.center)
}

try card("02-modes.png",2) {
    label("想常驻，也能收起。",80,209,65,ink,.semibold,930,110)
    label("同一份关注列表，换个舒服的位置。",84,326,30,secondary,.regular,900,60)
    label("01   刘海模式",84,427,27,blue,.semibold,900,50)
    // The line marks the screen edge; the window itself is an untouched capture.
    box(80,495,920,435,color(0xFFFFFF,0.4),radius:26)
    line(104,505,976,505,color(0xBAC8D8),2)
    photo("notch-light.jpg",291,505,498,18,squareTop:true)
    label("屏幕顶部查看，悬停展开任务",84,959,25,secondary,.regular,900,55)
    line(80,1034,1000,1034,color(0xD1DBE6))
    photo("orb-light.jpg",102,1100,66,33,shadow:false)
    label("02   圆环模式",209,1077,28,blue,.semibold,740,55)
    label("一个小圆环，需要时再点开。",209,1140,31,ink,.medium,760,60)
    label("原生尺寸 44pt · 图中等比放大展示",209,1200,22,secondary,.regular,760,45)
}

try card("03-details.png",3) {
    label("它在忙，还是在等你？",80,209,65,ink,.semibold,940,110)
    label("任务状态，集中看一眼。",84,326,30,secondary,.regular,900,60)
    photo("panel-light.jpg",290,437,500,24)
    box(82,869,7,49,orange,radius:3)
    label("待处理优先",112,861,31,ink,.semibold,850,55)
    label("需要回复或确认的任务，排在前面。",112,918,26,secondary,.regular,850,55)
    box(82,1014,7,49,blue,radius:3)
    label("关注你正在做的事",112,1006,31,ink,.semibold,850,55)
    label("搜索、多选；新建并开始的任务自动加入。",112,1063,26,secondary,.regular,850,55)
    line(80,1153,1000,1153,color(0xD1DBE6))
    label("只读本地任务记录，不上传任务内容。",84,1185,26,ink,.medium,920,55)
    label("状态以本机记录为准；回复和批准仍在 Codex 中完成。",84,1232,21,secondary,.regular,920,45)
}

try card("04-comparison.png",4) {
    label("简单一点，",80,205,76,ink,.semibold,920,110)
    label("也自由一点。",80,301,76,ink,.semibold,920,110)
    label("专注 Codex 任务，提供四种显示方式。",84,429,30,secondary,.regular,920,65)
    box(80,536,920,69,color(0xFFFFFF,0.55),radius:14)
    label("工具",104,554,23,secondary,.medium,240,45)
    label("主要侧重",335,554,23,secondary,.medium,335,45)
    label("主要显示入口",698,554,23,secondary,.medium,275,45)
    let rows: [(String,String,String)] = [
        ("Atoll","音乐、计时、系统信息","刘海 / 锁屏组件"),
        ("CodexBar","多平台额度与用量","菜单栏 / 桌面组件"),
        ("CodexNotch","Codex 额度与任务","刘海 / 无刘海回退")
    ]
    for (index,row) in rows.enumerated() {
        let y: CGFloat = 634 + CGFloat(index) * 105
        label(row.0,104,y,28,ink,.semibold,245,50)
        label(row.1,335,y+3,24,ink,.regular,355,50)
        label(row.2,698,y+3,23,secondary,.regular,290,50)
        line(104,y+70,976,y+70,color(0xD2DCE7))
    }
    box(80,969,920,135,color(0xD8E5F5,0.86),radius:20)
    label("Codex Top",104,990,31,blue,.semibold,290,55)
    label("专注任务监控，关注列表共用",402,997,26,ink,.medium,570,50)
    label("刘海  /  常驻浮窗  /  44pt 圆环  /  仅状态栏",104,1056,27,ink,.medium,850,55)
    label("各有侧重；以上按公开说明整理，未经竞品实机横测。",84,1135,21,secondary,.regular,920,45)
    label("来源  github.com/Ebullioscopic/Atoll",84,1190,18,secondary,.regular,920,35)
    label("github.com/steipete/CodexBar  ·  github.com/fengdwx/codex-notch",84,1224,18,secondary,.regular,920,40)
}
