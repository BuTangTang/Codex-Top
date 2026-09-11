import Foundation

/// A bounded, two-pass search. Only the nearest explicit start is a candidate;
/// replay uses the normal reducer. Only bounded line buffers survive reads;
/// parsed message bodies are discarded.
struct RolloutTimingRecovery: Sendable {
    private enum Stage: Sendable { case search, replay, finished }
    private var stage = Stage.search
    private var searchOffset: UInt64
    private var reverseSuffix = Data()
    // The sampled EOF may end in a partial line. Ignore it until its first newline.
    private var skippingReverseLine = true
    private var replayOffset: UInt64 = 0
    private var pending = Data()
    private var skippingLongLine = false
    private var replay = RolloutReducer()
    private(set) var recovered: TaskActivity?
    var isFinished: Bool { stage == .finished }

    init(end: UInt64) { searchOffset = end }

    /// Both reverse search and forward replay share this call's byte budget.
    mutating func advance(handle: FileHandle, through end: UInt64, blockSize: Int, budget: Int) -> Int {
        var bytesRead = 0
        do {
            while bytesRead < budget, stage != .finished {
                if stage == .search {
                    guard searchOffset > 0 else {
                        finishSearchAtBeginning()
                        continue
                    }
                    let count = min(blockSize, budget - bytesRead, Int(min(UInt64(blockSize), searchOffset)))
                    let base = searchOffset - UInt64(count)
                    try handle.seek(toOffset: base)
                    let data = try handle.read(upToCount: count) ?? Data()
                    bytesRead += data.count
                    guard data.count == count else { stage = .finished; break }
                    searchOffset = base
                    search(data, base: base, maximumLine: blockSize)
                } else {
                    guard replayOffset < end else {
                        recovered = replay.activity; stage = .finished
                        break
                    }
                    let count = min(blockSize, budget - bytesRead, Int(min(UInt64(blockSize), end - replayOffset)))
                    try handle.seek(toOffset: replayOffset)
                    let data = try handle.read(upToCount: count) ?? Data()
                    bytesRead += data.count
                    guard data.count == count else { stage = .finished; break }
                    replayOffset += UInt64(data.count)
                    pending.append(data)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending[..<newline]
                        if !skippingLongLine, !line.isEmpty, line.count <= blockSize { replay.consume(Data(line)) }
                        pending.removeSubrange(...newline)
                        skippingLongLine = false
                    }
                    if pending.count > blockSize { pending.removeAll(); skippingLongLine = true }
                }
            }
            if stage == .replay, replayOffset == end {
                recovered = replay.activity; stage = .finished
            }
        } catch {
            // The primary reader retains ownership of source errors and status.
            // Failed optional recovery is cached for this file generation.
            stage = .finished
        }
        return bytesRead
    }

    private mutating func search(_ data: Data, base: UInt64, maximumLine: Int) {
        var end = data.endIndex
        while let newline = data[..<end].lastIndex(of: 10) {
            let fragment = data[data.index(after: newline)..<end]
            if !skippingReverseLine, fragment.count + reverseSuffix.count <= maximumLine {
                var line = Data(fragment); line.append(reverseSuffix)
                if isStart(line) {
                    beginReplay(at: base + UInt64(newline - data.startIndex + 1))
                    return
                }
            }
            reverseSuffix.removeAll(); skippingReverseLine = false
            end = newline
        }
        if !skippingReverseLine {
            let prefix = data[..<end]
            if prefix.count + reverseSuffix.count <= maximumLine {
                var combined = Data(prefix); combined.append(reverseSuffix); reverseSuffix = combined
            } else {
                reverseSuffix.removeAll(); skippingReverseLine = true
            }
        }
        if searchOffset == 0 { finishSearchAtBeginning() }
    }

    private mutating func finishSearchAtBeginning() {
        if !skippingReverseLine, isStart(reverseSuffix) { beginReplay(at: 0) }
        else { reverseSuffix.removeAll(); stage = .finished }
    }

    private mutating func beginReplay(at offset: UInt64) {
        reverseSuffix.removeAll(); replayOffset = offset; stage = .replay
    }

    private func isStart(_ line: Data) -> Bool {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return false }
        // A start with no valid timestamp is still a boundary. Never borrow an older start.
        return type == "task_started" || type == "turn_started"
    }
}
