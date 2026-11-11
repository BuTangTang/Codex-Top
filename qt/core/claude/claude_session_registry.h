#pragma once
#include <QDateTime>
#include <QHash>
#include <QTimeZone>
#include <functional>
#include <optional>

namespace codextop {
/// 只读各进程的会话登记，按进程号和真正的启动时间排除 PID 复用。
struct ClaudeSessionRegistry {
    struct Entry {
        QString sessionID;
        qint32 pid = 0;
        QString processStart;
        std::optional<QString> entrypoint, hostSessionID, name;
        bool alive = false;
        /// 桌面入口记录允许沿用原有的直达链接。
        bool fromDesktopApp() const { return entrypoint && entrypoint->startsWith("claude-desktop"); }
    };
    using IsAlive = std::function<bool(qint32,const QString &)>;
    std::optional<QHash<QString,Entry>> entries;
    /// 目录无法枚举时返回无值，能枚举但没有登记时返回空表。
    static ClaudeSessionRegistry read(const QString &root, const IsAlive &isAlive = processMatches);
    /// 核对当前系统的 PID 和创建时刻，失败时不将登记视作活跃。
    static bool processMatches(qint32 pid, const QString &processStart);
    /// 允许 UTC 和本地时区两种英文 ps / lstart 写法，只合并连续空格。
    static bool startMatches(const QDateTime &started, const QString &recorded, const QTimeZone &localZone = QTimeZone::systemTimeZone());
    /// 根据所选时区输出稳定的英文 weekday month day HH:mm:ss year 版式。
    static QString processStartText(const QDateTime &started, const QTimeZone &zone);
};
}
