import XCTest
@testable import CodexTopCore

/// 面板副标题按工具名说正在干什么，两种来源用同一份对照，不读参数和正文。
final class ToolActivityTextTests: XCTestCase {
    private func line(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    func testMapping() {
        XCTAssertEqual(ToolActivityText.detail(forTool: "shell"), "正在运行命令")
        XCTAssertEqual(ToolActivityText.detail(forTool: "Bash"), "正在运行命令")
        XCTAssertEqual(ToolActivityText.detail(forTool: "apply_patch"), "正在编辑文件")
        XCTAssertEqual(ToolActivityText.detail(forTool: "Edit"), "正在编辑文件")
        XCTAssertEqual(ToolActivityText.detail(forTool: "Grep"), "正在查看文件")
        XCTAssertEqual(ToolActivityText.detail(forTool: "mcp__github__create_issue"), "正在调用工具")
        XCTAssertEqual(ToolActivityText.detail(forTool: "something_new"), "正在执行任务")
    }

    func testCodexFunctionCallUsesToolName() {
        var reducer = RolloutReducer()
        reducer.consume(line(["timestamp": "2027-01-15T08:00:00Z", "type": "event_msg", "payload": ["type": "task_started", "turn_id": "t"]]))
        reducer.consume(line(["timestamp": "2027-01-15T08:00:01Z", "type": "response_item", "payload": ["type": "function_call", "name": "apply_patch", "call_id": "c1", "arguments": "secret"]]))
        XCTAssertEqual(reducer.activity.detail, "正在编辑文件")
        reducer.consume(line(["timestamp": "2027-01-15T08:00:02Z", "type": "event_msg", "payload": ["type": "agent_reasoning", "text": "secret"]]))
        XCTAssertEqual(reducer.activity.detail, "正在思考")
    }

    func testClaudeToolUseAndThinking() {
        var reducer = ClaudeTranscriptReducer()
        reducer.consume(line(["type": "user", "timestamp": "2027-01-15T08:00:00Z", "message": ["role": "user", "content": "go"]]))
        reducer.consume(line(["type": "assistant", "timestamp": "2027-01-15T08:00:01Z", "message": ["role": "assistant", "stop_reason": "tool_use",
            "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "secret"]]]]]))
        XCTAssertEqual(reducer.activity.detail, "正在运行命令")
        reducer.consume(line(["type": "assistant", "timestamp": "2027-01-15T08:00:02Z", "message": ["role": "assistant",
            "content": [["type": "thinking", "thinking": "secret"]]]]))
        XCTAssertEqual(reducer.activity.detail, "正在思考")
    }
}
