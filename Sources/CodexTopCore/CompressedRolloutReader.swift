import Foundation
import Darwin
import CZstd

/// 压缩来源指纹同时用于描述符和路径复核，避免发布跨文件代次的状态。
struct CompressedFingerprint: Equatable {
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

/// 单解码器、有限缓存的压缩历史读取器；仅由 LocalCodexSource actor 串行使用。
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
    private final class Stream {
        let id: String
        let url: URL
        let fingerprint: CompressedFingerprint
        let handle: FileHandle
        let decoder: OpaquePointer
        var input = Data()
        var position = 0
        var output = [UInt8](repeating: 0, count: 65_536)
        var line = Data()
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

        /// 按换行归约，超长行不持有正文，记录证据缺口以防错误终态。
        func consume(_ count: Int) throws {
            for byte in output.prefix(count) {
                if byte == 10 {
                    if !skipped && !line.isEmpty { reducer.consume(line)
                        if reducer.retainedMetadataBytes > 1_024 * 1_024 { throw POSIXError(.ENOMEM) }
                    }
                    line.removeAll(keepingCapacity: true); skipped = false
                } else if !skipped {
                    if line.count < 65_536 { line.append(byte) }
                    else { line.removeAll(keepingCapacity: true); skipped = true; hasGap = true }
                }
            }
        }
    }
    private var stream: Stream?
    private var cache: [String: Cached] = [:]
    private var usedThisCycle = false
    private let maximumOutput: Int

    /// 测试可降低累计扫描上限，正式读取固定为 256 MiB。
    init(maximumOutput: Int = 256 * 1_024 * 1_024) { self.maximumOutput = maximumOutput }

    /// 每轮清理已取消关注的状态，并重置全局本轮工作预算。
    func beginCycle(ids: Set<String>) {
        usedThisCycle = false
        cache = cache.filter { ids.contains($0.key) }
        if let stream, !ids.contains(stream.id) { self.stream = nil }
    }

    /// 只对完整缓存暴露待答依据，不使用半段历史的提问。
    func awaitingReplySince(_ id: String) -> Date? { cache[id]?.reducer?.awaitingReplySince }

    /// 关联只读回执，不对压缩来源重新打开不存在的普通文件。
    func projectedActivity(_ id: String, receipts: [QuestionReplyReceipt], now: Date) -> TaskActivity? {
        cache[id]?.reducer?.activity(acknowledging: receipts, for: id, at: now)
    }

    /// 普通来源恢复或文件不再有效时，不复用压缩结果。
    func forget(_ id: String) {
        cache.removeValue(forKey: id)
        if stream?.id == id { stream = nil }
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
        if let stream, stream.id == id && (stream.url != url || stream.fingerprint != fingerprint) { self.stream = nil }
        guard cache.count < 256 else { return Result(activity: TaskActivity(detail: "尚未读取（资源限制）"), category: .limited) }
        guard !usedThisCycle, stream == nil || stream?.id == id else {
            return Result(activity: TaskActivity(detail: stream?.id == id ? "正在读取压缩记录" : "等待读取压缩记录"), category: .reading)
        }
        usedThisCycle = true
        var bytes = 0
        do {
            if stream == nil { stream = try Stream(id: id, url: url, fingerprint: fingerprint) }
            guard let current = stream else { throw POSIXError(.EIO) }
            let start = ContinuousClock.now
            var outputThisCycle = 0
            while bytes < 256 * 1_024 && outputThisCycle < 1_024 * 1_024 {
                if current.position == current.input.count {
                    current.input = try current.handle.read(upToCount: 65_536) ?? Data()
                    current.position = 0; bytes += current.input.count
                    if current.input.isEmpty && current.frameComplete {
                        guard try CompressedFingerprint(url: url) == fingerprint,
                              try CompressedFingerprint(url: url, descriptor: current.handle.fileDescriptor) == fingerprint else { throw POSIXError(.ESTALE) }
                        // 缺少末尾换行同样属于证据缺口，不将历史部分状态当成完整结果。
                        let incomplete = current.hasGap || !current.line.isEmpty || current.skipped || (current.reducer.activity.turnID?.utf8.count ?? 0) > 4_096 || current.reducer.retainedMetadataBytes > 12_288
                        let result = Result(activity: incomplete ? TaskActivity(detail: "压缩记录含超长或不完整行，状态未确认") : current.reducer.activity,
                                            quota: incomplete ? nil : current.reducer.quota, category: incomplete ? .limited : .ready)
                        cache[id] = Cached(fingerprint: fingerprint, result: result, reducer: incomplete ? nil : current.reducer); stream = nil
                        var returned = result; returned.bytes = bytes; returned.activity = returned.activity.effective(at: now); return returned
                    }
                }
                var consumed = 0, written = 0
                let available = current.input.count - current.position
                let code = current.input.withUnsafeBytes { input in
                    current.output.withUnsafeMutableBytes { output in
                        ctz_step(current.decoder, input.baseAddress?.advanced(by: current.position), available, &consumed,
                                 output.baseAddress, min(65_536, maximumOutput - current.produced + 1), &written)
                    }
                }
                current.position += consumed; current.produced += written; outputThisCycle += written
                if code < 0 { throw POSIXError(code == -2 ? .ENOMEM : .EBADMSG) }
                if current.produced > maximumOutput {
                    let result = Result(activity: TaskActivity(detail: "压缩记录超过读取上限，状态未确认"), category: .limited)
                    cache[id] = Cached(fingerprint: fingerprint, result: result); stream = nil
                    var returned = result; returned.bytes = bytes; return returned
                }
                try current.consume(written); current.frameComplete = code == 1
                if consumed == 0 && written == 0 && available == 0 { throw POSIXError(.EBADMSG) }
                if start.duration(to: .now) >= .milliseconds(5) { break }
            }
            return Result(activity: TaskActivity(detail: "正在读取压缩记录"), category: .reading, bytes: bytes)
        } catch {
            stream = nil
            var result = failure(error)
            // 文件在解码期间变化时，下轮重新检测，不能缓存为损坏。
            if (error as? POSIXError)?.code != .ESTALE { cache[id] = Cached(fingerprint: fingerprint, result: result) }
            result.bytes = bytes; return result
        }
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
