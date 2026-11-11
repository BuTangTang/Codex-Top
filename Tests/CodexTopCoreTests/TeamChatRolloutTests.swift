import Foundation
import XCTest
@testable import CodexTopCore

final class TeamChatRolloutTests: XCTestCase {
    private let header = #"{"ordinal":0,"payload":{"teamchat_copy":{"automatic":true}},"type":"session_meta"}"#
    private let timestamp = "2027-01-15T08:00:00Z"

    /// 生成带源时间和可选导入序号的合成事件。
    private func event(_ type: String, ordinal: Int? = nil, turn: String = "local") -> String {
        let sequence = ordinal.map { #""ordinal":\#($0),"# } ?? ""
        return #"{\#(sequence)"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"\#(type)","turn_id":"\#(turn)"}}"#
    }

    /// 每次测试使用独立临时目录，写入的每一行均为合成记录。
    private func file(_ rows: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.jsonl")
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    /// 模拟原记录的追加，不替换 inode，以便覆盖已关注任务的暖刷新。
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// 同步开始、答复、结束和后续导入均不改本机状态；本机启动、待答、结束立即生效。
    func testImportedRecordsAndBookkeepingDoNotDriveLocalLifecycle() throws {
        let url = try file([header, event("task_started", ordinal: 1), event("agent_message", ordinal: 2),
                            event("task_complete", ordinal: 3), event("thread_settings_applied"), event("thread_name_updated")])
        var reader = IncrementalRollout()
        _ = try reader.refresh(url: url)
        XCTAssertEqual(reader.reducer.activity, .teamChatImport)
        XCTAssertEqual(try reader.refresh(url: url), 0)
        let native = event("task_started")
        try append(String(native.dropLast()), to: url)
        _ = try reader.refresh(url: url)
        XCTAssertFalse(reader.reducer.activity.isTeamChatImport, "未完成行不能证明只有导入历史")
        try append("}\n", to: url)
        _ = try reader.refresh(url: url)
        XCTAssertEqual(reader.reducer.activity.phase, .running)
        XCTAssertFalse(reader.reducer.activity.isTeamChatImport)
        try append(event("request_user_input") + "\n" + event("task_complete", ordinal: 4) + "\n", to: url)
        _ = try reader.refresh(url: url)
        XCTAssertEqual(reader.reducer.activity.phase, .waiting)
        try append(event("task_complete") + "\n" + event("task_started", ordinal: 5) + "\n", to: url)
        _ = try reader.refresh(url: url)
        XCTAssertEqual(reader.reducer.activity.phase, .completed)
    }

    /// 带序号的原生续聊以本机专用起点或上下文为界，此后的普通分页事件都参与归约。
    func testNumberedNativeContinuationCanStartAndComplete() throws {
        let context = #"{"type":"turn_context","ordinal":12,"payload":{"turn_id":"local"}}"#
        let nativeStart = event("task_started", ordinal: 13)
        let nativeStartWithEvidence = nativeStart.replacingOccurrences(of: #""turn_id":"local""#, with: #""turn_id":"local","started_at":1800000000"#)
        for boundary in [[context, nativeStart], [nativeStartWithEvidence]] {
            let url = try file([header, event("task_started", ordinal: 1, turn: "remote")] + boundary)
            var reader = IncrementalRollout()
            _ = try reader.refresh(url: url)
            XCTAssertEqual(reader.reducer.activity.phase, .running)
            XCTAssertEqual(reader.reducer.activity.turnID, "local")
            try append(event("task_complete", ordinal: 14) + "\n", to: url)
            _ = try reader.refresh(url: url)
            XCTAssertEqual(reader.reducer.activity.phase, .completed)
            XCTAssertFalse(reader.reducer.activity.isTeamChatImport)
        }
    }

    /// 手动副本、普通分页记录及嵌入其他线程的头，都不能触发文件级来源识别。
    func testOnlyAutomaticBooleanInFileHeaderMarksImportedEvents() throws {
        for flag in ["false", "1", "\"true\""] {
            let url = try file([header.replacingOccurrences(of: ":true", with: ":\(flag)"), event("task_started", ordinal: 1)])
            var reader = IncrementalRollout()
            _ = try reader.refresh(url: url)
            XCTAssertEqual(reader.reducer.activity.phase, .running)
        }
        let url = try file([event("task_started", ordinal: 1), header, event("task_complete", ordinal: 2)])
        var reader = IncrementalRollout()
        _ = try reader.refresh(url: url)
        XCTAssertEqual(reader.reducer.activity.phase, .completed)
        for ordinal in [nil, 2] as [Int?] {
            let unknown = try file([header, event("future_native_event", ordinal: ordinal)])
            _ = try reader.refresh(url: unknown)
            XCTAssertEqual(reader.reducer.activity.phase, .unknown)
            XCTAssertFalse(reader.reducer.activity.isTeamChatImport)
        }
    }

    /// 大副本从头有限追赶，夹在历史中间的本机活动不会被冷尾截断，也不会借用导入时间。
    func testLargeCopyResumesBoundedScanAndIsNeverRetiredBeforeEOF() throws {
        let imports = (1...70).map { event("task_started", ordinal: $0, turn: "remote") }
        for hasLocal in [false, true] {
            var rows = [header] + imports
            if hasLocal { rows.insert(event("agent_message"), at: 20) }
            let url = try file(rows)
            var reader = IncrementalRollout(maximumRead: 1_024, maximumCatchUpRead: 2_048)
            XCTAssertEqual(try reader.refresh(url: url), 1_024)
            XCTAssertFalse(reader.isCaughtUp)
            XCTAssertFalse(reader.reducer.activity.isTeamChatImport)
            while !reader.isCaughtUp {
                let bytes = try reader.refresh(url: url)
                XCTAssertGreaterThan(bytes, 0)
                XCTAssertLessThanOrEqual(bytes, 2_048)
            }
            if hasLocal {
                XCTAssertEqual(reader.reducer.activity.phase, .running)
                XCTAssertEqual(try reader.recoverTiming(url: url), 0)
                XCTAssertNil(reader.reducer.activity.startedAt)
                XCTAssertNil(reader.reducer.activity.turnID)
            } else { XCTAssertEqual(reader.reducer.activity, .teamChatImport) }
        }
    }
}
