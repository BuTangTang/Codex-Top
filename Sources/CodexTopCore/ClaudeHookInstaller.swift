import Foundation

/// REQ-003 层 C：在 Claude Code 的 settings.json 里登记/移除 Codex Top 自己那一条通知钩子。
/// 只在原文里插入或删掉自己那一段，其它内容一个字节都不动（包括手写的缩进和空行）；
/// 认自己的条目只看命令里是否含固定的小程序路径。
public enum ClaudeHookInstaller {
    public enum Failure: Error, Equatable { case invalidJSON, changedWhileEditing }

    public static let matcher = "permission_prompt|elicitation_dialog"

    /// settings.json 里登记的命令：小程序还在才运行，不在就直接成功退出，不影响 cc。
    public static func command(helper: URL) -> String {
        let path = helper.path.replacingOccurrences(of: "\"", with: "\\\"")
        return "h=\"\(path)\"; [ -x \"$h\" ] && \"$h\"; exit 0"
    }

    /// 文件里是否已有自己的条目；文件没有时为 false，读不懂时为 nil。
    public static func isInstalled(settings: URL, helper: URL) -> Bool? {
        guard let data = try? Data(contentsOf: settings) else { return false }
        if isBlank(data) { return false }
        guard let root = try? parse(data) else { return nil }
        return !ownEntries(root, text: data, helper: helper).isEmpty
    }

    public static func install(settings: URL, helper: URL, backups: URL) throws {
        let original = try? Data(contentsOf: settings)
        guard let original, !isBlank(original) else {
            let text = "{\n  \"hooks\": " + hooksBlock(helper: helper, indent: "  ") + "\n}\n"
            try write(Data(text.utf8), to: settings, original: original, backups: backups)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            try Data().write(to: backups.appendingPathComponent("created-settings"))
            return
        }
        var data = original
        var root = try parse(data)
        guard ownEntries(root, text: data, helper: helper).isEmpty else { return }
        // 小程序路径变过的旧条目先拿掉，再加新的。
        for span in ownEntries(root, text: data, helper: helper, anyHelper: true).reversed() { data = removing(span, from: data) }
        root = try parse(data)
        let indentation = indent(of: root.start, in: data) + "  "
        if let hooks = root.member("hooks"), case .object = hooks.value.kind {
            if let list = hooks.value.member("Notification"), case .array = list.value.kind {
                let inner = indent(of: hooks.value.start, in: data) + "    "
                data = inserting(entry(helper: helper, indent: inner), into: list.value, of: data, indent: inner)
            } else {
                let inner = indent(of: hooks.value.start, in: data) + "  "
                data = inserting("\"Notification\": " + notificationList(helper: helper, indent: inner), into: hooks.value, of: data, indent: inner)
            }
        } else {
            data = inserting("\"hooks\": " + hooksBlock(helper: helper, indent: indentation), into: root, of: data, indent: indentation)
        }
        _ = try parse(data)
        try write(data, to: settings, original: original, backups: backups)
    }

    public static func remove(settings: URL, helper: URL, backups: URL) throws {
        guard let original = try? Data(contentsOf: settings), !isBlank(original) else { return }
        var data = original
        let spans = ownEntries(try parse(data), text: data, helper: helper, anyHelper: true)
        guard !spans.isEmpty else { return }
        for span in spans.reversed() { data = removing(span, from: data) }
        // 只因自己而存在的空 Notification、空 hooks 一并拿掉。
        var root = try parse(data)
        if let hooks = root.member("hooks"), let list = hooks.value.member("Notification"), list.value.children.isEmpty {
            data = removing(list.span, from: data); root = try parse(data)
        }
        if let hooks = root.member("hooks"), case .object = hooks.value.kind, hooks.value.children.isEmpty {
            data = removing(hooks.span, from: data); root = try parse(data)
        }
        let marker = backups.appendingPathComponent("created-settings")
        if root.children.isEmpty, FileManager.default.fileExists(atPath: marker.path) {
            try backup(original, backups: backups)
            try FileManager.default.removeItem(at: settings)
            try? FileManager.default.removeItem(at: marker)
            return
        }
        try write(data, to: settings, original: original, backups: backups)
    }

    // MARK: - 写入

    /// 写前再读一遍，和开始时不一样就放弃（别的程序刚改过）；原子写入并保留原来的权限；旧内容备份最近 3 份。
    static func write(_ data: Data, to url: URL, original: Data?, backups: URL) throws {
        if (try? Data(contentsOf: url)) != original { throw Failure.changedWhileEditing }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        if let original { try backup(original, backups: backups) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    static func backup(_ data: Data, backups: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        try data.write(to: backups.appendingPathComponent("settings-\(stamp).json"), options: .atomic)
        let old = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? []).filter { $0.hasPrefix("settings-") }.sorted()
        for name in old.dropLast(3) { try? fm.removeItem(at: backups.appendingPathComponent(name)) }
    }

    // MARK: - 自己的那一段

    static func entry(helper: URL, indent: String) -> String {
        let i = indent
        return "{\n\(i)  \"matcher\": \(quoted(matcher)),\n\(i)  \"hooks\": [\n\(i)    {\n"
            + "\(i)      \"type\": \"command\",\n\(i)      \"command\": \(quoted(command(helper: helper))),\n"
            + "\(i)      \"async\": true,\n\(i)      \"timeout\": 5\n\(i)    }\n\(i)  ]\n\(i)}"
    }

    static func notificationList(helper: URL, indent: String) -> String {
        "[\n\(indent)  " + entry(helper: helper, indent: indent + "  ") + "\n\(indent)]"
    }

    static func hooksBlock(helper: URL, indent: String) -> String {
        "{\n\(indent)  \"Notification\": " + notificationList(helper: helper, indent: indent + "  ") + "\n\(indent)}"
    }

    static func quoted(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    /// hooks.Notification 里属于 Codex Top 的条目。anyHelper 为真时，凡是命令指向 Codex Top 小程序名字的都算（路径换过的旧条目）。
    static func ownEntries(_ root: Node, text: Data, helper: URL, anyHelper: Bool = false) -> [Range<Int>] {
        guard let list = root.member("hooks")?.value.member("Notification")?.value, case .array = list.kind else { return [] }
        return list.children.compactMap { element in
            guard let value = try? JSONSerialization.jsonObject(with: text[element.value.start..<element.value.end]) as? [String: Any],
                  let hooks = value["hooks"] as? [[String: Any]] else { return nil }
            let own = hooks.contains { hook in
                guard let command = hook["command"] as? String else { return false }
                return anyHelper ? command.contains("/Codex Top/bin/" + helper.lastPathComponent) || command.contains(helper.path)
                                 : command == self.command(helper: helper)
            }
            return own ? element.span : nil
        }
    }

    // MARK: - 只记位置的 JSON 解析

    struct Node {
        enum Kind { case object, array, scalar }
        var kind: Kind
        var start: Int
        var end: Int
        var children: [Child] = []
        func member(_ key: String) -> Child? { kind == .object ? children.first { $0.key == key } : nil }
    }

    struct Child {
        var key: String?
        /// 键（或数组元素）开始到值结束。
        var span: Range<Int>
        var value: Node
    }

    static func isBlank(_ data: Data) -> Bool { data.allSatisfy { [9, 10, 13, 32].contains($0) } }

    static func parse(_ data: Data) throws -> Node {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw Failure.invalidJSON }
        let bytes = [UInt8](data)
        var index = 0
        let root = try value(bytes, &index)
        return root
    }

    private static func skip(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private static func value(_ bytes: [UInt8], _ index: inout Int) throws -> Node {
        skip(bytes, &index)
        guard index < bytes.count else { throw Failure.invalidJSON }
        let start = index
        switch bytes[index] {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            let isObject = bytes[index] == UInt8(ascii: "{")
            let close = isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")
            var node = Node(kind: isObject ? .object : .array, start: start, end: start)
            index += 1; skip(bytes, &index)
            if index < bytes.count, bytes[index] == close { index += 1; node.end = index; return node }
            while true {
                skip(bytes, &index)
                let childStart = index
                var key: String?
                if isObject {
                    let keyStart = index; try string(bytes, &index)
                    key = try JSONSerialization.jsonObject(with: Data(bytes[keyStart..<index]), options: .fragmentsAllowed) as? String
                    skip(bytes, &index); index += 1 // 冒号
                }
                let child = try value(bytes, &index)
                node.children.append(Child(key: key, span: childStart..<child.end, value: child))
                skip(bytes, &index)
                guard index < bytes.count else { throw Failure.invalidJSON }
                if bytes[index] == close { index += 1; node.end = index; return node }
                index += 1 // 逗号
            }
        case UInt8(ascii: "\""):
            try string(bytes, &index)
            return Node(kind: .scalar, start: start, end: index)
        default:
            while index < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 9, 10, 13, 32].contains(bytes[index]) { index += 1 }
            return Node(kind: .scalar, start: start, end: index)
        }
    }

    private static func string(_ bytes: [UInt8], _ index: inout Int) throws {
        index += 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") { index += 2; continue }
            if bytes[index] == UInt8(ascii: "\"") { index += 1; return }
            index += 1
        }
        throw Failure.invalidJSON
    }

    // MARK: - 原文拼接

    /// 某个位置所在行开头的空格。
    static func indent(of position: Int, in data: Data) -> String {
        let bytes = [UInt8](data)
        var lineStart = position
        while lineStart > 0, bytes[lineStart - 1] != 10 { lineStart -= 1 }
        var end = lineStart
        while end < bytes.count, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
        return String(decoding: bytes[lineStart..<end], as: UTF8.self)
    }

    /// 在对象或数组的最后加一项：有内容就接在最后一项后面加逗号，空的就展开成多行。
    static func inserting(_ text: String, into container: Node, of data: Data, indent: String) -> Data {
        var bytes = [UInt8](data)
        if let last = container.children.last {
            bytes.insert(contentsOf: Array((",\n" + indent + text).utf8), at: last.span.upperBound)
        } else {
            let closing = String(indent.dropLast(2))
            bytes.replaceSubrange((container.start + 1)..<(container.end - 1), with: Array(("\n" + indent + text + "\n" + closing).utf8))
        }
        return Data(bytes)
    }

    /// 删掉一项和它旁边的一个逗号：不是第一项就连前面的逗号一起删，是第一项就删到下一项开头。
    static func removing(_ span: Range<Int>, from data: Data) -> Data {
        var bytes = [UInt8](data)
        var lower = span.lowerBound, upper = span.upperBound
        var back = lower - 1
        while back >= 0, [9, 10, 13, 32].contains(bytes[back]) { back -= 1 }
        if back >= 0, bytes[back] == UInt8(ascii: ",") {
            lower = back
        } else {
            var forward = upper
            while forward < bytes.count, [9, 10, 13, 32].contains(bytes[forward]) { forward += 1 }
            if forward < bytes.count, bytes[forward] == UInt8(ascii: ",") {
                forward += 1
                while forward < bytes.count, [9, 10, 13, 32].contains(bytes[forward]) { forward += 1 }
                upper = forward
            } else {
                // 唯一一项：连同前后空白清掉，留下 {} 或 []。
                lower = back + 1
                upper = forward
            }
        }
        bytes.removeSubrange(lower..<upper)
        return Data(bytes)
    }
}
