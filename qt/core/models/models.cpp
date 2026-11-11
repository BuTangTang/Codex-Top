#include "models.h"

#include <QUuid>
#include <cmath>

namespace codextop {

QString phaseRawValue(TaskPhase phase) {
    switch (phase) {
    case TaskPhase::Running: return QStringLiteral("running");
    case TaskPhase::Waiting: return QStringLiteral("waiting");
    case TaskPhase::Completed: return QStringLiteral("completed");
    case TaskPhase::Failed: return QStringLiteral("failed");
    case TaskPhase::Stopped: return QStringLiteral("stopped");
    case TaskPhase::Idle: return QStringLiteral("idle");
    case TaskPhase::Unknown: return QStringLiteral("unknown");
    }
    return {};
}

std::optional<TaskPhase> phaseFromRawValue(const QString &value) {
    for (auto phase : {TaskPhase::Running, TaskPhase::Waiting, TaskPhase::Completed, TaskPhase::Failed, TaskPhase::Stopped, TaskPhase::Idle, TaskPhase::Unknown}) {
        if (phaseRawValue(phase) == value) return phase;
    }
    return std::nullopt;
}

QString phaseLabel(TaskPhase phase) {
    switch (phase) {
    case TaskPhase::Running: return QStringLiteral("运行中");
    case TaskPhase::Waiting: return QStringLiteral("待处理");
    case TaskPhase::Completed: return QStringLiteral("已完成");
    case TaskPhase::Failed: return QStringLiteral("出错");
    case TaskPhase::Stopped: return QStringLiteral("已停止");
    case TaskPhase::Idle: return QStringLiteral("未运行");
    case TaskPhase::Unknown: return QStringLiteral("状态未知");
    }
    return {};
}

int phasePriority(TaskPhase phase) {
    switch (phase) {
    case TaskPhase::Waiting: return 0;
    case TaskPhase::Failed: return 1;
    case TaskPhase::Running: return 2;
    case TaskPhase::Unknown: return 3;
    case TaskPhase::Idle: return 4;
    case TaskPhase::Stopped: return 5;
    case TaskPhase::Completed: return 6;
    }
    return 7;
}

std::optional<qint64> TaskActivity::waitingElapsedSeconds() const {
    if (phase != TaskPhase::Waiting || !startedAt || !waitingStartedAt || !startedAt->isValid() || !waitingStartedAt->isValid()) return std::nullopt;
    const qint64 elapsed = startedAt->msecsTo(*waitingStartedAt);
    if (elapsed < 0) return std::nullopt;
    return elapsed / 1000;
}

TaskActivity TaskActivity::effective(const QDateTime &now, double staleAfter, const QString &sourceName) const {
    TaskActivity copy = *this;
    if (phase == TaskPhase::Running && lastEventAt && double(lastEventAt->msecsTo(now)) / 1000.0 > staleAfter) {
        copy.phase = TaskPhase::Unknown;
        copy.detail = QStringLiteral("较久未收到新活动，请回到 %1 查看").arg(sourceName);
    }
    return copy;
}

namespace {
bool isUuid(const QString &text) { return !QUuid::fromString(text).isNull() && text.size() == 36; }
}

std::optional<QUrl> CodexTask::deepLink() const {
    if (origin == TaskOrigin::Codex) {
        if (!isUuid(id)) return std::nullopt;
        return QUrl(QStringLiteral("codex://threads/%1").arg(id));
    }
    // 只有桌面 App 的会话能直达；编号来自运行登记，格式不对就不拼链接。
    if (!claudeLaunch || !claudeLaunch->fromDesktopApp || !claudeLaunch->hostSessionID) return std::nullopt;
    const QString host = *claudeLaunch->hostSessionID;
    if (!host.startsWith(QStringLiteral("local_")) || !isUuid(host.mid(6))) return std::nullopt;
    return QUrl(QStringLiteral("claude://claude.ai/epitaxy/%1").arg(host));
}

std::optional<QString> CodexTask::claudeSessionID() const {
    if (origin != TaskOrigin::ClaudeCode) return std::nullopt;
    return id.mid(3);
}

int QuotaWindow::remainingPercent() const {
    return int(std::lround(std::max(0.0, std::min(100.0, 100.0 - usedPercent))));
}

std::optional<QuotaWindow> QuotaSnapshot::fiveHour() const {
    for (const auto &window : windows) if (window.minutes == 300) return window;
    return std::nullopt;
}

std::optional<QuotaWindow> QuotaSnapshot::weekly() const {
    for (const auto &window : windows) if (window.minutes == 10080) return window;
    return std::nullopt;
}

QString errorDescription(CodexSourceError error) {
    switch (error) {
    case CodexSourceError::MissingDatabase: return QStringLiteral("未找到 Codex 任务数据库。请先在 Codex 创建任务，或选择正确的数据目录。");
    case CodexSourceError::IncompatibleDatabase: return QStringLiteral("当前 Codex 数据格式不受支持，请更新 Codex Top。");
    case CodexSourceError::DatabaseUnavailable: return QStringLiteral("暂时无法读取 Codex 数据库，请稍后刷新或检查目录权限。");
    case CodexSourceError::UnreadableLog: return QStringLiteral("部分任务记录无法读取。");
    }
    return {};
}

std::optional<QDateTime> parseTimestamp(const QString &text) {
    QDateTime value = QDateTime::fromString(text, Qt::ISODateWithMs);
    if (!value.isValid()) value = QDateTime::fromString(text, Qt::ISODate);
    if (!value.isValid()) return std::nullopt;
    return value.toUTC();
}

} // namespace codextop
