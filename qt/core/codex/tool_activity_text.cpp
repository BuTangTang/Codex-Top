#include "tool_activity_text.h"

#include <QStringList>

namespace codextop::ToolActivityText {
QString detail(const QString &name) {
    const QString tool = name.toLower();
    if (tool.startsWith("mcp__")) return QStringLiteral("正在调用工具");
    static const QStringList shell{"shell", "exec_command", "local_shell", "container.exec", "write_stdin",
                                   "bash", "bashoutput", "killshell", "killbash"};
    static const QStringList edit{"apply_patch", "edit", "multiedit", "write", "notebookedit"};
    static const QStringList read{"read", "glob", "grep", "ls", "notebookread", "view_image"};
    static const QStringList web{"webfetch", "websearch", "web_search", "web.run"};
    static const QStringList child{"task", "agent", "spawn_agent"};
    if (shell.contains(tool)) return QStringLiteral("正在运行命令");
    if (edit.contains(tool)) return QStringLiteral("正在编辑文件");
    if (read.contains(tool)) return QStringLiteral("正在查看文件");
    if (web.contains(tool)) return QStringLiteral("正在查资料");
    if (child.contains(tool)) return QStringLiteral("正在派子任务");
    if (tool == "todowrite" || tool == "update_plan") return QStringLiteral("正在整理计划");
    return QStringLiteral("正在执行任务");
}
}
