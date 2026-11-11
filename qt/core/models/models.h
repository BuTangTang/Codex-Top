#pragma once

// 任务模型，逐项对应原生版 Sources/CodexTopCore/Models.swift。中文文字一字不改。
// UTC 的 QDateTime 负责毫秒显示，日志时刻另保留亚毫秒部分。没有时间时用 std::optional。

#include <QDateTime>
#include <QList>
#include <QString>
#include <QUrl>
#include <optional>

namespace codextop {

enum class TaskPhase { Running, Waiting, Completed, Failed, Stopped, Idle, Unknown };

QString phaseRawValue(TaskPhase phase);                 // "running" 等，和原生版存盘用的字符串一致
std::optional<TaskPhase> phaseFromRawValue(const QString &value);
QString phaseLabel(TaskPhase phase);                    // "运行中" 等
int phasePriority(TaskPhase phase);                     // 排序用：等你 0 … 已完成 6
inline bool isActive(TaskPhase phase) { return phase == TaskPhase::Running || phase == TaskPhase::Waiting; }
inline bool isFinished(TaskPhase phase) { return phase == TaskPhase::Completed || phase == TaskPhase::Stopped; }

// QDateTime 负责毫秒表示，额外的小数来自原始时间戳。比较与间隔使用 Swift Date
// 相同的 2001 参考点和 Double 精度：当两条纳秒记录在原生版相等时这里也相等。
struct PreciseTimestamp {
    QDateTime date;
    int submillisecondNanoseconds = 0;
    double referenceSeconds() const;
    static std::optional<PreciseTimestamp> fromReferenceSeconds(double seconds);
    bool operator==(const PreciseTimestamp &other) const {
        return date.isValid() == other.date.isValid() && referenceSeconds() == other.referenceSeconds();
    }
};

struct TaskActivity {
    TaskPhase phase = TaskPhase::Unknown;
    QString detail = QStringLiteral("尚无可识别的活动记录");
    std::optional<QDateTime> lastEventAt;
    std::optional<QDateTime> startedAt;
    std::optional<QDateTime> waitingStartedAt;
    std::optional<QString> turnID;

    bool isTeamChatImport = false;
    static TaskActivity teamChatImport();

    int lastEventSubmillisecondNanoseconds = 0;
    int startedSubmillisecondNanoseconds = 0;
    int waitingStartedSubmillisecondNanoseconds = 0;
    std::optional<PreciseTimestamp> lastEventTimestamp() const;
    std::optional<PreciseTimestamp> startedTimestamp() const;
    std::optional<PreciseTimestamp> waitingStartedTimestamp() const;
    void setLastEventTimestamp(const std::optional<PreciseTimestamp> &at);
    void setStartedTimestamp(const std::optional<PreciseTimestamp> &at);
    void setWaitingStartedTimestamp(const std::optional<PreciseTimestamp> &at);
    bool operator==(const TaskActivity &other) const;
    // 从本轮开始到进入当前等待经过的秒数；不是等待状态或时间不全时没有。
    std::optional<qint64> waitingElapsedSeconds() const;
    // 在跑但超过 staleAfter 秒没有新活动：显示成状态未知。
    TaskActivity effective(const QDateTime &now, double staleAfter = 900, const QString &sourceName = QStringLiteral("Codex")) const;
};

enum class TaskOrigin { Codex, ClaudeCode };
inline QString originDisplayName(TaskOrigin origin) { return origin == TaskOrigin::Codex ? QStringLiteral("Codex") : QStringLiteral("Claude Code"); }
inline QString originMark(TaskOrigin origin) { return origin == TaskOrigin::Codex ? QStringLiteral("CX") : QStringLiteral("CC"); }

struct ClaudeLaunch {
    bool fromDesktopApp = false;
    std::optional<QString> hostSessionID;   // 桌面 App 里的会话编号（local_…）
    bool operator==(const ClaudeLaunch &) const = default;
};

struct CodexTask {
    QString id;
    TaskOrigin origin = TaskOrigin::Codex;
    std::optional<ClaudeLaunch> claudeLaunch;
    QString title;
    QString project;
    QDateTime createdAt;
    QDateTime updatedAt;
    std::optional<QString> parentID;
    QString rolloutPath;          // 记录文件的本机路径
    TaskActivity activity;

    bool operator==(const CodexTask &) const = default;
    // 点任务打开桌面 App 的链接；格式不对时没有。
    std::optional<QUrl> deepLink() const;
    // Claude Code 会话编号（去掉 cc: 前缀）。
    std::optional<QString> claudeSessionID() const;
};

struct QuotaWindow {
    qint64 minutes = 0;
    double usedPercent = 0;
    std::optional<QDateTime> resetsAt;
    bool operator==(const QuotaWindow &) const = default;
    int remainingPercent() const;
};

enum class QuotaOrigin { Log, Account };

struct QuotaSnapshot {
    QDateTime observedAt;
    QList<QuotaWindow> windows;
    QuotaOrigin origin = QuotaOrigin::Log;
    bool operator==(const QuotaSnapshot &) const = default;
    std::optional<QuotaWindow> fiveHour() const;
    std::optional<QuotaWindow> weekly() const;
};

struct SourceSnapshot {
    QList<CodexTask> tasks;
    std::optional<QuotaSnapshot> quota;
    std::optional<QString> warning;
    qint64 bytesRead = 0;
    QDateTime observedAt = QDateTime::currentDateTimeUtc();
};

enum class CodexSourceError { MissingDatabase, IncompatibleDatabase, DatabaseUnavailable, UnreadableLog };
QString errorDescription(CodexSourceError error);

// 原生版各处共用的 ISO 8601 时间解析（带或不带毫秒，带时区）；解析不了返回空。
std::optional<PreciseTimestamp> parsePreciseTimestamp(const QString &text);
std::optional<QDateTime> parseTimestamp(const QString &text);

} // namespace codextop
