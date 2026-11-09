import Foundation
import Darwin
import CZstd

/// 压缩来源指纹同时用于描述符和路径复核，避免发布跨文件代次的状态。
struct CompressedFingerprint: Equatable, Codable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let seconds: Int
    let nanos: Int

    /// 读取路径或已打开描述符的元数据，只接受普通文件。
    init(url: URL, descriptor: Int32? = nil) throws {
        var value = stat()
        let result = descriptor.map { fstat($0, &value) } ?? url.path.withCString { lstat($0, &value) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard value.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        seconds = value.st_mtimespec.tv_sec; nanos = value.st_mtimespec.tv_nsec
    }
}

/// 单解码器、有限缓存的压缩历史读取器；由 LocalCodexSource actor 串行调用，解码放在后台队列。
final class CompressedRolloutReader {
    struct Result {
        var activity: TaskActivity
        var quota: QuotaSnapshot?
        var category: Category
        var bytes = 0
    }
    enum Category { case reading, ready, unavailable, limited }
    private struct Cached {
        let fingerprint: CompressedFingerprint
        let result: Result
        var reducer: RolloutReducer? = nil
    }
    /// 创建后整个交给一个后台任务独占使用。
    private final class Stream: @unchecked Sendable {
        let id: String
        let url: URL
        let fingerprint: CompressedFingerprint
        let handle: FileHandle
        let decoder: OpaquePointer
        var input = Data()
        var position = 0
        var output = [UInt8](repeating: 0, count: 65_536)
        var line = Data()
        /// 超长行只留开头，用来判断它是什么记录（2026-11-08 用户同意的规则）。
        var longPrefix = Data()
        var skipped = false
        var hasGap = false
        var produced = 0
        var frameComplete = false
        var reducer = RolloutReducer()

        /// 打开后核对文件身份，失败时立即释放上下文和描述符。
        init(id: String, url: URL, fingerprint: CompressedFingerprint) throws {
            self.id = id; self.url = url; self.fingerprint = fingerprint
            handle = try FileHandle(forReadingFrom: url)
            do {
                guard try CompressedFingerprint(url: url, descriptor: handle.fileDescriptor) == fingerprint else { throw POSIXError(.ESTALE) }
            } catch { try? handle.close(); throw error }
            guard let decoder = ctz_create() else { try? handle.close(); throw POSIXError(.ENOMEM) }
            self.decoder = decoder
        }
        deinit { ctz_destroy(decoder); try? handle.close() }

        /// 后台全速解码到文件末尾；每 64 KiB 检查一次是否被取消，并更新已读字节数。
        func run(maximumOutput: Int, job: Job) throws -> Outcome {
            while true {
                if job.isCancelled { throw CancellationError() }
                if position == input.count {
                    input = try handle.read(upToCount: 65_536) ?? Data()
                    position = 0; job.addInput(input.count)
                    if input.isEmpty && frameComplete {
                        guard try CompressedFingerprint(url: url) == fingerprint,
                              try CompressedFingerprint(url: url, descriptor: handle.fileDescriptor) == fingerprint else { throw POSIXError(.ESTALE) }
                        // 缺少末尾换行同样属于证据缺口，不将历史部分状态当成完整结果。
                        let incomplete = hasGap || !line.isEmpty || skipped || (reducer.activity.turnID?.utf8.count ?? 0) > 4_096 || reducer.retainedMetadataBytes > 12_288
                        let result = Result(activity: incomplete ? TaskActivity(detail: "压缩记录含超长或不完整行，状态未确认") : reducer.activity,
                                            quota: incomplete ? nil : reducer.quota, category: incomplete ? .limited : .ready)
                        return Outcome(result: result, reducer: incomplete ? nil : reducer)
                    }
                }
                var consumed = 0, written = 0
                let available = input.count - position
                let code = input.withUnsafeBytes { buffer in
                    output.withUnsafeMutableBytes { out in
                        ctz_step(decoder, buffer.baseAddress?.advanced(by: position), available, &consumed,
                                 out.baseAddress, min(65_536, maximumOutput - produced + 1), &written)
                    }
                }
                position += consumed; produced += written
                if code < 0 { throw POSIXError(code == -2 ? .ENOMEM : .EBADMSG) }
                if produced > maximumOutput {
                    return Outcome(result: Result(activity: TaskActivity(detail: "压缩记录超过读取上限，状态未确认"), category: .limited), reducer: nil)
                }
                try consume(written); frameComplete = code == 1
                if consumed == 0 && written == 0 && available == 0 { throw POSIXError(.EBADMSG) }
            }
        }

        /// 按连续字节段归约，避免逐字节扩容；跨块长行仍按原上限标记证据缺口。
        func consume(_ count: Int) throws {
            try output.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let newline = memchr(base.advanced(by: offset), 10, count - offset)
                    let end = newline.map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? count
                    let length = end - offset
                    if !skipped {
                        if line.count + length <= 65_536 {
                            line.append(base.advanced(by: offset), count: length)
                        } else {
                            line.append(base.advanced(by: offset), count: min(length, CompressedRolloutReader.longLinePrefix))
                            longPrefix = line.prefix(CompressedRolloutReader.longLinePrefix)
                            line.removeAll(keepingCapacity: true); skipped = true
                        }
                    }
                    if newline != nil {
                        if !skipped && !line.isEmpty {
                            reducer.consume(line)
                        } else if skipped {
                            // 与状态无关的超长行直接跳过；有关的只把能读到的顶层字段交给归约器；读不出时仍按证据缺口处理。
                            switch CompressedRolloutReader.summarizeLongLine(longPrefix) {
                            case .ignore: break
                            case .line(let summary): reducer.consume(summary)
                            case .gap: hasGap = true
                            }
                            longPrefix.removeAll(keepingCapacity: true)
                        }
                        if reducer.retainedMetadataBytes > 1_024 * 1_024 { throw POSIXError(.ENOMEM) }
                        line.removeAll(keepingCapacity: true); skipped = false
                    }
                    offset = end + 1
                }
            }
        }
    }
    fileprivate struct Outcome {
        let result: Result
        let reducer: RolloutReducer?
    }
    /// 一次后台解码。解码器、文件句柄和归约器只在后台线程里用，actor 只读取进度和结果。
    final class Job: @unchecked Sendable {
        let id: String
        let url: URL
        let fingerprint: CompressedFingerprint
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var cancelled = false
        private var inputBytes = 0
        private var reportedBytes = 0
        private var outcome: Swift.Result<Outcome, Error>?
        fileprivate init(id: String, url: URL, fingerprint: CompressedFingerprint) { self.id = id; self.url = url; self.fingerprint = fingerprint }
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
        func addInput(_ count: Int) { lock.withLock { inputBytes += count } }
        /// 上次汇报以来新读入的压缩字节，只用于读取量统计。
        func takeInputDelta() -> Int { lock.withLock { defer { reportedBytes = inputBytes }; return inputBytes - reportedBytes } }
        fileprivate func finish(_ value: Swift.Result<Outcome, Error>) { lock.withLock { outcome = value }; done.signal() }
        fileprivate func takeOutcome() -> Swift.Result<Outcome, Error>? { lock.withLock { outcome } }
        /// 仅测试用：等后台解码结束。
        func wait() { done.wait(); done.signal() }
    }
    private var job: Job?
    private var cache: [String: Cached] = [:]
    private var usedThisCycle = false
    private let maximumOutput: Int
    private let store: CompressedStatusStore?
    private let queue = DispatchQueue(label: "dev.butang.codextop.compressed", qos: .utility)

    static let longLinePrefix = 4_096

    /// 不再设累计上限（解码边读边丢，内存不随文件增长）；测试可传小值验证上限分支。
    /// `cacheURL` 为空时不落盘；正式应用放在 Codex Top 自己的状态目录，不写 Codex 数据目录。
    init(maximumOutput: Int = 1 << 46, cacheURL: URL? = nil) {
        self.maximumOutput = maximumOutput
        store = cacheURL.map(CompressedStatusStore.init(url:))
        for (id, entry) in store?.load() ?? [:] {
            cache[id] = Cached(fingerprint: entry.fingerprint, result: Result(activity: entry.activity, category: entry.limited ? .limited : .ready))
        }
    }

    /// 每轮清理已取消关注的状态，并重置本轮启动名额；取消关注的任务停止后台解码。
    func beginCycle(ids: Set<String>) {
        usedThisCycle = false
        cache = cache.filter { ids.contains($0.key) }
        if let job, !ids.contains(job.id) { stopJob() }
    }

    /// 仅测试用：等当前后台解码结束。
    func waitForBackgroundRead() { job?.wait() }

    private func stopJob() { job?.cancel(); job = nil }

    /// 只对完整缓存暴露待答依据，不使用半段历史的提问。
    func awaitingReplySince(_ id: String) -> Date? { cache[id]?.reducer?.awaitingReplySince }

    /// 关联只读回执，不对压缩来源重新打开不存在的普通文件。
    func projectedActivity(_ id: String, receipts: [QuestionReplyReceipt], now: Date) -> TaskActivity? {
        cache[id]?.reducer?.activity(acknowledging: receipts, for: id, at: now)
    }

    /// 普通来源恢复或文件不再有效时，不复用压缩结果。
    func forget(_ id: String) {
        cache.removeValue(forKey: id)
        if job?.id == id { stopJob() }
    }

    /// 读取一个有界切片，只有物理 EOF、完整帧和元数据复核都通过才发布状态。
    func read(id: String, url: URL, now: Date) -> Result {
        let fingerprint: CompressedFingerprint
        do { fingerprint = try CompressedFingerprint(url: url) }
        catch { forget(id); return failure(error) }
        if let cached = cache[id], cached.fingerprint == fingerprint {
            var result = cached.result; result.activity = result.activity.effective(at: now); return result
        }
        cache.removeValue(forKey: id)
        if let job, job.id == id && (job.url != url || job.fingerprint != fingerprint) { stopJob() }
        guard cache.count < 256 else { return Result(activity: TaskActivity(detail: "尚未读取（资源限制）"), category: .limited) }
        if let job {
            guard job.id == id else { return Result(activity: TaskActivity(detail: "等待读取压缩记录"), category: .reading) }
            let bytes = job.takeInputDelta()
            guard let outcome = job.takeOutcome() else {
                return Result(activity: TaskActivity(detail: "正在读取压缩记录"), category: .reading, bytes: bytes)
            }
            self.job = nil
            switch outcome {
            case .success(let value):
                cache[id] = Cached(fingerprint: fingerprint, result: value.result, reducer: value.reducer)
                persist()
                var returned = value.result; returned.bytes = bytes; returned.activity = returned.activity.effective(at: now); return returned
            case .failure(let error):
                var result = failure(error)
                // 文件在解码期间变化时，下轮重新检测，不能缓存为损坏。
                if (error as? POSIXError)?.code != .ESTALE { cache[id] = Cached(fingerprint: fingerprint, result: result) }
                result.bytes = bytes; return result
            }
        }
        guard !usedThisCycle else { return Result(activity: TaskActivity(detail: "等待读取压缩记录"), category: .reading) }
        usedThisCycle = true
        // 第一次读取改为后台全速一次读完（2026-11-09 用户同意）：同一时间只解一个文件，刷新只取结果。
        let stream: Stream
        do { stream = try Stream(id: id, url: url, fingerprint: fingerprint) }
        catch {
            let result = failure(error)
            if (error as? POSIXError)?.code != .ESTALE { cache[id] = Cached(fingerprint: fingerprint, result: result) }
            return result
        }
        let job = Job(id: id, url: url, fingerprint: fingerprint)
        self.job = job
        let limit = maximumOutput
        queue.async { [stream] in
            job.finish(Swift.Result { try stream.run(maximumOutput: limit, job: job) })
        }
        return Result(activity: TaskActivity(detail: "正在读取压缩记录"), category: .reading)
    }

    /// 读完的结果按文件身份落盘：压缩记录不再改动，重启后直接用，不再从头解压。
    /// 只存状态文字和时间；等待中的结果要配合答复回执核对，不落盘，每次重读。
    private func persist() {
        guard let store else { return }
        var entries: [String: CompressedStatusStore.Entry] = [:]
        for (id, cached) in cache where cached.result.category == .ready || cached.result.category == .limited {
            guard cached.result.activity.phase != .waiting else { continue }
            entries[id] = CompressedStatusStore.Entry(fingerprint: cached.fingerprint, activity: cached.result.activity,
                                                      limited: cached.result.category == .limited)
        }
        store.save(entries)
    }

    /// 超长行的处理结果：与状态无关、可用摘要代替、或读不出关键字段。
    enum LongLine: Equatable { case ignore, line(Data), gap }

    /// 只看行首 4 KiB 里的顶层字段（Codex 记录固定以 timestamp、type、payload 开头）。
    /// 归约器只用到这些字段的记录类型改用摘要行，其余仍按证据缺口处理，规则保守。
    static func summarizeLongLine(_ prefix: Data) -> LongLine {
        guard let header = LongLineHeader(prefix) else { return .gap }
        // 归约器只认 event_msg 和 response_item，其他类型（压缩摘要、上下文等）不影响状态。
        guard header.kind == "event_msg" || header.kind == "response_item" else { return .ignore }
        var payload: [String: Any] = [:]
        let fields = header.payload
        guard let type = fields["type"] else { return .gap }
        payload["type"] = type
        if header.kind == "event_msg" {
            switch type {
            case "task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted", "task_cancelled",
                 "turn_cancelled", "task_failed", "turn_failed", "request_user_input", "user_input_requested",
                 "exec_approval_request", "apply_patch_approval_request", "user_message", "user_input",
                 "approval_resolved", "agent_message", "agent_reasoning":
                if let turn = fields["turn_id"] { payload["turn_id"] = turn }
            case "item_completed":
                guard let item = header.itemType else { return .gap }
                payload["item"] = ["type": item]
            case "token_count": return .gap
            default: return .ignore
            }
        } else {
            switch type {
            case "message":
                guard let role = fields["role"] else { return .gap }
                payload["role"] = role
            case "function_call", "custom_tool_call":
                guard let name = fields["name"] else { return .gap }
                // 提问类调用要靠编号和参数判断等待，读不全就不猜。
                if name.contains("request_user_input") { return .gap }
                payload["name"] = name
            case "function_call_output", "custom_tool_call_output":
                guard let call = fields["call_id"] else { return .gap }
                payload["call_id"] = call
            default: return .ignore
            }
        }
        var value: [String: Any] = ["type": header.kind, "payload": payload]
        if let timestamp = header.timestamp { value["timestamp"] = timestamp }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return .gap }
        return .line(data)
    }

    /// 对外仅返回原因类别，不暴露路径、原始错误或记录正文。
    private func failure(_ error: Error) -> Result {
        let code = (error as? POSIXError)?.code
        if code == .ENOMEM { return Result(activity: TaskActivity(detail: "压缩记录暂不支持或超过资源上限，状态未确认"), category: .limited) }
        if code == .ESTALE { return Result(activity: TaskActivity(detail: "记录已变化，等待重新读取"), category: .reading) }
        let text = code == .EACCES || code == .EPERM ? "无权读取任务记录" : code == .ENOENT ? "任务记录缺失" : "压缩记录损坏或不完整"
        return Result(activity: TaskActivity(detail: text), category: .unavailable)
    }
}

/// 从超长行开头按顺序读出顶层的简单字段；遇到嵌套值或过长的字符串就停，不猜后面的内容。
struct LongLineHeader {
    var timestamp: String?
    var kind = ""
    var payload: [String: String] = [:]
    /// item_completed 的 item.type，只读 item 对象开头的简单字段。
    var itemType: String?

    init?(_ data: Data) {
        var scanner = Scanner(bytes: [UInt8](data))
        guard scanner.take("{") else { return nil }
        var sawPayload = false
        while let key = scanner.key() {
            if key == "payload" {
                guard scanner.take("{") else { return nil }
                sawPayload = true
                while let inner = scanner.key() {
                    if inner == "item", scanner.peek("{") {
                        _ = scanner.take("{")
                        while let itemKey = scanner.key() {
                            guard let value = scanner.simpleValue() else { break }
                            if itemKey == "type" { itemType = value }
                            guard scanner.take(",") else { break }
                        }
                        break
                    }
                    guard let value = scanner.simpleValue() else { break }
                    payload[inner] = value
                    guard scanner.take(",") else { break }
                }
                break
            }
            guard let value = scanner.simpleValue() else { return nil }
            if key == "timestamp" { timestamp = value } else if key == "type" { kind = value }
            guard scanner.take(",") else { return nil }
        }
        guard sawPayload, !kind.isEmpty else { return nil }
    }

    /// 只认 JSON 里的字符串、数字、布尔和 null；字符串超过 512 字节或读到片段末尾即放弃。
    struct Scanner {
        let bytes: [UInt8]
        var index = 0
        init(bytes: [UInt8]) { self.bytes = bytes }
        mutating func skipSpaces() { while index < bytes.count, [32, 9, 10, 13].contains(bytes[index]) { index += 1 } }
        mutating func peek(_ character: Character) -> Bool { skipSpaces(); return index < bytes.count && bytes[index] == character.asciiValue }
        mutating func take(_ character: Character) -> Bool { guard peek(character) else { return false }; index += 1; return true }
        mutating func string() -> String? {
            guard take("\"") else { return nil }
            var output: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return String(bytes: output, encoding: .utf8) }
                if byte == 92 {
                    guard index < bytes.count else { return nil }
                    let escaped = bytes[index]; index += 1
                    switch escaped {
                    case 34, 92, 47: output.append(escaped)
                    case 110: output.append(10)
                    case 116: output.append(9)
                    default: return nil
                    }
                } else { output.append(byte) }
                if output.count > 512 { return nil }
            }
            return nil
        }
        mutating func key() -> String? {
            let saved = index
            guard let name = string(), take(":") else { index = saved; return nil }
            return name
        }
        mutating func simpleValue() -> String? {
            skipSpaces()
            guard index < bytes.count else { return nil }
            if bytes[index] == 34 { return string() }
            let start = index
            while index < bytes.count, !(bytes[index] == 44 || bytes[index] == 125 || bytes[index] == 93 || [32, 9, 10, 13].contains(bytes[index])) {
                guard (45...57).contains(bytes[index]) || (97...122).contains(bytes[index]) || bytes[index] == 43 || bytes[index] == 69 else { return nil }
                index += 1
            }
            guard index < bytes.count, index > start else { return nil }
            return String(bytes: bytes[start..<index], encoding: .utf8)
        }
    }
}

/// 压缩记录读取结果的本地缓存文件：键为任务编号，值带文件身份，身份不符即作废。
final class CompressedStatusStore {
    struct Entry: Codable {
        var fingerprint: CompressedFingerprint
        var phase: TaskPhase
        var detail: String
        var lastEventAt: Date?
        var startedAt: Date?
        var limited: Bool
        init(fingerprint: CompressedFingerprint, activity: TaskActivity, limited: Bool) {
            self.fingerprint = fingerprint; phase = activity.phase; detail = activity.detail
            lastEventAt = activity.lastEventAt; startedAt = activity.startedAt; self.limited = limited
        }
        var activity: TaskActivity { TaskActivity(phase: phase, detail: detail, lastEventAt: lastEventAt, startedAt: startedAt) }
    }
    private struct File: Codable { var version = 1; var entries: [String: Entry] }
    let url: URL
    init(url: URL) { self.url = url }

    /// 读不到或格式不对就当没有缓存，照常重新解压。
    func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return [:] }
        return file.entries
    }

    /// 原子写入；失败不影响当前显示，下次启动重新读取。
    func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(File(entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
