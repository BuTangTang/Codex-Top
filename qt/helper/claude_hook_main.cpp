#include "claude/claude_hook_events.h"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <cstdio>
#ifdef Q_OS_WIN
#include <fcntl.h>
#include <io.h>
#endif

/// Claude Code 在批准或填写时通过标准输入发送通知。始终成功退出，避免干扰原操作。
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
#ifdef Q_OS_WIN
    _setmode(_fileno(stdin), _O_BINARY);
#endif
    QFile input;
    if (!input.open(stdin, QIODevice::ReadOnly))
        return 0;
    auto path = QFileInfo(QCoreApplication::applicationFilePath()).canonicalFilePath();
    QDir state = QFileInfo(path).absoluteDir();
    if (path.isEmpty() || !state.cdUp())
        return 0;
    // 只解析前 64 KiB，事件文件跟随已安装小程序所在的应用状态目录。
    codextop::ClaudeHookEvents::record(input.read(64 * 1024), state.filePath("claude-events"));
    return 0;
}
