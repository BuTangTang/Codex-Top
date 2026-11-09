import CoreGraphics

/// D-89 LED 点阵悬浮球的排版：3×5 方点字，四周一圈灯（四角整像素圆角）。
/// 所有点的位置和大小都是整数点，窗口原点也取整，所以 1 倍外接屏和 2 倍内置屏上都是清楚的方点。
public enum LEDOrbLayout {
    public enum Tone: Equatable, Sendable { case running, idle, waiting, failed, done }
    public struct Group: Equatable, Sendable {
        public let text: String
        public let tone: Tone
        public init(text: String, tone: Tone) { self.text = text; self.tone = tone }
    }
    public struct Dot: Equatable, Sendable {
        public let rect: CGRect
        public let tone: Tone
        public let lit: Bool
    }
    public struct Layout: Equatable, Sendable {
        public let width: CGFloat
        public let dots: [Dot]
        public let dividers: [CGRect]
        /// 外圈的灯，从左上角那段直边开始顺时针排。
        public let ring: [CGRect]
    }

    public static let height: CGFloat = 44
    public static let dotSize: CGFloat = 3
    static let pitch: CGFloat = 4
    static let digitTop: CGFloat = 13
    /// 3×5 字形，逐行从左到右，1 是亮点。
    static let glyphs: [Character: String] = [
        "0": "111101101101111", "1": "010110010010111", "2": "111001111100111", "3": "111001111001111",
        "4": "101101111001001", "5": "111100111001111", "6": "111100111101111", "7": "111001001001001",
        "8": "111101111101111", "9": "111101111001111", "+": "000010111010000", "?": "111001011000010",
        "✓": "000001001101010",
    ]

    /// 一组一种意思：先是在跑的个数（全部完成显示 ✓、暂停或无法判断显示 ?），再是等你回答、失败的个数，没有就不出。
    public static func groups(running: Int, waiting: Int, failed: Int, allDone: Bool, unknown: Bool) -> [Group] {
        if unknown { return [Group(text: "?", tone: .idle)] }
        if allDone { return [Group(text: "✓", tone: .done)] }
        var result = [Group(text: text(running), tone: running > 0 ? .running : .idle)]
        if waiting > 0 { result.append(Group(text: text(waiting), tone: .waiting)) }
        if failed > 0 { result.append(Group(text: text(failed), tone: .failed)) }
        return result
    }

    static func text(_ count: Int) -> String { count > 99 ? "99+" : String(max(0, count)) }

    public static func layout(_ groups: [Group]) -> Layout {
        let groupWidths = groups.map { CGFloat($0.text.count) * 16 - 4 }
        let inner = groupWidths.reduce(0, +) + CGFloat(max(0, groups.count - 1)) * 8
        // 宽度 = 9 + 4k，让一圈灯在两条直边上正好落在 4 点一格的整数位置；最窄 45。
        let steps = max(9, Int(((inner + 11) / 4).rounded(.up)))
        let width = 9 + 4 * CGFloat(steps)
        var dots: [Dot] = [], dividers: [CGRect] = []
        var x = ((width - inner) / 2).rounded()
        for (index, group) in groups.enumerated() {
            if index > 0 { dividers.append(CGRect(x: x - 5, y: digitTop, width: 1, height: 19)) }
            for (column, character) in group.text.enumerated() {
                let bits = Array(glyphs[character] ?? glyphs["0"]!)
                for cell in 0..<15 {
                    let rect = CGRect(x: x + CGFloat(column) * 16 + CGFloat(cell % 3) * pitch,
                                      y: digitTop + CGFloat(cell / 3) * pitch, width: dotSize, height: dotSize)
                    dots.append(Dot(rect: rect, tone: group.tone, lit: bits[cell] == "1"))
                }
            }
            x += groupWidths[index] + 8
        }
        return Layout(width: width, dots: dots, dividers: dividers, ring: ring(width: width))
    }

    /// 灯圈的圆心线：左右离边 4.5、上下离边 4.5。直边每 4 点一颗；每个角只放 1 颗、往里收 1 点，仍在整数位置。
    static func ring(width: CGFloat) -> [CGRect] {
        let left: CGFloat = 4.5, right = width - 4.5, top: CGFloat = 4.5, bottom: CGFloat = 40.5
        var centers: [CGPoint] = []
        for x in stride(from: left + 4, through: right - 4, by: 4) { centers.append(CGPoint(x: x, y: top)) }
        centers.append(CGPoint(x: right - 1, y: top + 1))
        for y in stride(from: top + 4, through: bottom - 4, by: 4) { centers.append(CGPoint(x: right, y: y)) }
        centers.append(CGPoint(x: right - 1, y: bottom - 1))
        for x in stride(from: right - 4, through: left + 4, by: -4) { centers.append(CGPoint(x: x, y: bottom)) }
        centers.append(CGPoint(x: left + 1, y: bottom - 1))
        for y in stride(from: bottom - 4, through: top + 4, by: -4) { centers.append(CGPoint(x: left, y: y)) }
        centers.append(CGPoint(x: left + 1, y: top + 1))
        return centers.map { CGRect(x: $0.x - dotSize / 2, y: $0.y - dotSize / 2, width: dotSize, height: dotSize) }
    }
}
