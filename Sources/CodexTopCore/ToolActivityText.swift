import Foundation

/// 面板副标题：只按工具名说正在干什么，不读参数和对话正文（REQ-003 R-23）。
/// Codex 的 function_call 和 Claude Code 的 tool_use 都用这一份对照，认不出的工具说“正在执行任务”。
public enum ToolActivityText {
    public static func detail(forTool name: String) -> String {
        let tool = name.lowercased()
        if tool.hasPrefix("mcp__") { return "正在调用工具" }
        switch tool {
        case "shell", "exec_command", "local_shell", "container.exec", "write_stdin", "bash", "bashoutput", "killshell", "killbash":
            return "正在运行命令"
        case "apply_patch", "edit", "multiedit", "write", "notebookedit":
            return "正在编辑文件"
        case "read", "glob", "grep", "ls", "notebookread", "view_image":
            return "正在查看文件"
        case "webfetch", "websearch", "web_search", "web.run":
            return "正在查资料"
        case "task", "agent", "spawn_agent":
            return "正在派子任务"
        case "todowrite", "update_plan":
            return "正在整理计划"
        default:
            return "正在执行任务"
        }
    }
}
