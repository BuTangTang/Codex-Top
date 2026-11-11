#include "models.h"

#include <QUuid>
#include <QRegularExpression>
#include <QTimeZone>
#include <cmath>
#include <limits>

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

double PreciseTimestamp::referenceSeconds() const {
    constexpr qint64 unixToReference = 978307200; // 1970-01-01 到 2001-01-01 UTC
    const qint64 ms = date.toMSecsSinceEpoch();
    qint64 whole = ms / 1000;
    int remainder = int(ms % 1000);
    if (remainder < 0) { --whole; remainder += 1000; }
    return double(whole - unixToReference) + double(remainder * 1000000 + submillisecondNanoseconds) / 1e9;
}

std::optional<PreciseTimestamp> PreciseTimestamp::fromReferenceSeconds(double seconds) {
    if (!std::isfinite(seconds)) return std::nullopt;
    constexpr qint64 unixToReference = 978307200;
    const double whole = std::floor(seconds);
    if (whole < double(std::numeric_limits<qint64>::min() / 1000 - unixToReference)
        || whole >= double(std::numeric_limits<qint64>::max() / 1000 - unixToReference))
        return std::nullopt;
    const auto base = QDateTime::fromSecsSinceEpoch(qint64(whole) + unixToReference, QTimeZone::UTC);
    const int nanos = int(std::lround((seconds - whole) * 1e9));
    PreciseTimestamp result{base.addMSecs(nanos / 1000000), nanos % 1000000};
    if (!result.date.isValid()) return std::nullopt;
    // Double 存盘会把十进制的整毫秒还原为附近的纳秒值。若与整毫秒同值，
    // 继续给界面原来的那一毫秒；其余小数保留，暖读后仍能正确判断先后。
    const PreciseTimestamp floor{result.date};
    if (floor.referenceSeconds() == seconds) return floor;
    const PreciseTimestamp next{result.date.addMSecs(1)};
    if (next.referenceSeconds() == seconds) return next;
    return result;
}

namespace {
std::optional<PreciseTimestamp> activityTime(const std::optional<QDateTime> &date, int remainder) {
    if (!date) return std::nullopt;
    return PreciseTimestamp{*date, remainder};
}
void setActivityTime(std::optional<QDateTime> &date, int &remainder, const std::optional<PreciseTimestamp> &at) {
    if (at) { date = at->date; remainder = at->submillisecondNanoseconds; }
    else { date.reset(); remainder = 0; }
}
} // namespace

std::optional<PreciseTimestamp> TaskActivity::lastEventTimestamp() const {
    return activityTime(lastEventAt, lastEventSubmillisecondNanoseconds);
}
std::optional<PreciseTimestamp> TaskActivity::startedTimestamp() const {
    return activityTime(startedAt, startedSubmillisecondNanoseconds);
}
std::optional<PreciseTimestamp> TaskActivity::waitingStartedTimestamp() const {
    return activityTime(waitingStartedAt, waitingStartedSubmillisecondNanoseconds);
}
void TaskActivity::setLastEventTimestamp(const std::optional<PreciseTimestamp> &at) {
    setActivityTime(lastEventAt, lastEventSubmillisecondNanoseconds, at);
}
void TaskActivity::setStartedTimestamp(const std::optional<PreciseTimestamp> &at) {
    setActivityTime(startedAt, startedSubmillisecondNanoseconds, at);
}
void TaskActivity::setWaitingStartedTimestamp(const std::optional<PreciseTimestamp> &at) {
    setActivityTime(waitingStartedAt, waitingStartedSubmillisecondNanoseconds, at);
}
bool TaskActivity::operator==(const TaskActivity &other) const {
    return phase == other.phase && detail == other.detail && turnID == other.turnID
        && isTeamChatImport == other.isTeamChatImport && lastEventTimestamp() == other.lastEventTimestamp()
        && startedTimestamp() == other.startedTimestamp() && waitingStartedTimestamp() == other.waitingStartedTimestamp();
}
TaskActivity TaskActivity::teamChatImport() {
    TaskActivity activity;
    activity.phase = TaskPhase::Idle;
    activity.detail = QStringLiteral("团队同步副本，尚无本机执行记录");
    activity.isTeamChatImport = true;
    return activity;
}

std::optional<qint64> TaskActivity::waitingElapsedSeconds() const {
    if (phase != TaskPhase::Waiting || !startedAt || !waitingStartedAt || !startedAt->isValid() || !waitingStartedAt->isValid()) return std::nullopt;
    const double elapsed = waitingStartedTimestamp()->referenceSeconds() - startedTimestamp()->referenceSeconds();
    if (elapsed < 0 || elapsed >= double(std::numeric_limits<qint64>::max())) return std::nullopt;
    return qint64(elapsed);
}

TaskActivity TaskActivity::effective(const QDateTime &now, double staleAfter, const QString &sourceName) const {
    TaskActivity copy = *this;
    if (phase == TaskPhase::Running && lastEventAt && lastEventAt->isValid() && now.isValid()
        && PreciseTimestamp{now}.referenceSeconds() - lastEventTimestamp()->referenceSeconds() > staleAfter) {
        copy.phase = TaskPhase::Unknown;
        copy.detail = QStringLiteral("较久未收到新活动，请回到 %1 查看").arg(sourceName);
    }
    return copy;
}

namespace {
// Foundation 接受语法正确的全零 UUID，不能用 QUuid::isNull() 判断语法。
bool isUuid(const QString &text) {
    static const QRegularExpression uuid(QStringLiteral("^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"));
    return text.size() == 36 && uuid.match(text).hasMatch();
}
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

std::optional<PreciseTimestamp> parsePreciseTimestamp(const QString &text) {
    // 记录必须给出秒和时区。Qt 默认会把仅日期或无时区的时间当本地时间。
    // Foundation 的 parse 消费有效前缀，支持 1～9 位小数和有/无冒号的时区。
    static const QRegularExpression iso(QStringLiteral(
        R"(^([0-9]{1,4})-([0-9]{1,2})-([0-9]{1,2})T([0-9]{1,3}):([0-9]{1,3}):([0-9]{1,3})(?:\.([0-9]{1,9}))?([Zz]|(?:(?i:GMT|UTC))?([+-])([0-9]{1,2}):?([0-9]{1,2})(?::?([0-9]{2}))?|(?i:GMT|UTC)))"));
    const auto match = iso.match(text);
    if (!match.hasMatch()) return std::nullopt;
    const auto field = [&](int index) { return match.capturedView(index).toInt(); };
    const QDate firstOfMonth(field(1), field(2), 1);
    if (!firstOfMonth.isValid() || field(3) < 1 || field(3) > 31) return std::nullopt;
    qint64 offset = field(10) * 3600 + field(11) * 60 + field(12);
    if (offset > 18 * 3600) return std::nullopt;
    if (match.capturedView(9) == u"-") offset = -offset;
    const auto day = firstOfMonth.addDays(field(3) - 1);
    const int nanos = match.captured(7).leftJustified(9, u'0').toInt();
    const auto base = QDateTime(day, QTime(0, 0), QTimeZone::UTC).addSecs(field(4) * 3600 + field(5) * 60 + field(6) - offset);
    const PreciseTimestamp result{base.addMSecs(nanos / 1000000), nanos % 1000000};
    if (result.submillisecondNanoseconds != 0) {
        const auto seconds = result.referenceSeconds();
        const PreciseTimestamp floor{result.date};
        if (seconds == floor.referenceSeconds()) return floor;
        const PreciseTimestamp next{result.date.addMSecs(1)};
        if (seconds == next.referenceSeconds()) return next;
    }
    return result;
}

std::optional<QDateTime> parseTimestamp(const QString &text) {
    const auto time = parsePreciseTimestamp(text);
    return time ? std::optional{time->date} : std::nullopt;
}

} // namespace codextop
