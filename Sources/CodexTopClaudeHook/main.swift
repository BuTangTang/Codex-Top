import CodexTopCore
import Foundation

// REQ-003 层 C：Claude Code 弹出“需要你批准／填写”时调用。只记会话编号、通知类型和时间，
// 写到小程序所在 bin 目录旁边的 claude-events；任何情况都返回 0，不影响 Claude Code。
let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
let events = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("claude-events", isDirectory: true)
ClaudeHookEvents.record(input: FileHandle.standardInput.readDataToEndOfFile().prefix(64 * 1024), directory: events)
exit(0)
