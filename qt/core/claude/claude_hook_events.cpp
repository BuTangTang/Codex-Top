#include "claude/claude_hook_events.h"
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>

namespace codextop::ClaudeHookEvents {
namespace {
/// 会话编号直接成为文件名，只允许 1 到 128 个 ASCII 字母、数字、横线与下划线。
bool safeSession(const QString &session) {
    static const QRegularExpression pattern(QStringLiteral("\\A[A-Za-z0-9_-]{1,128}\\z"));
    return pattern.match(session).hasMatch();
}
/// 通知名必须出自明确支持的两种 Claude Code 事件。
bool supported(const QString &kind) { return kind == "permission_prompt" || kind == "elicitation_dialog"; }
} // namespace
void record(const QByteArray &input, const QString &directory, const QDateTime &now) {
    const auto event = QJsonDocument::fromJson(input).object();
    const auto session = event.value("session_id").toString(), kind = event.value("notification_type").toString();
    if (event.value("hook_event_name").toString() != "Notification" || !supported(kind) || !safeSession(session))
        return;
    if (!QDir().mkpath(directory))
        return;
    const QString path = QDir(directory).filePath(session + ".jsonl");
    QByteArray data;
    QFile previous(path);
    if (previous.open(QIODevice::ReadOnly)) {
        data = previous.readAll();
        previous.close();
    }
    // 类型已在白名单中，不把输入所携带的正文、工作目录或记录路径写出。
    data +=
        "{\"t\":\"" + kind.toLatin1() + "\",\"at\":\"" + now.toUTC().toString(Qt::ISODateWithMs).toLatin1() + "\"}\n";
    if (data.size() > 256 * 1024) {
        const auto cut = data.indexOf('\n', data.size() / 2);
        if (cut >= 0)
            data.remove(0, cut + 1);
    }
    QSaveFile file(path);
    if (file.open(QIODevice::WriteOnly) && file.write(data) == data.size())
        file.commit();
}
std::optional<ClaudeHookEvent> latest(const QString &directory, const QString &session) {
    if (!safeSession(session))
        return {};
    QFile file(QDir(directory).filePath(session + ".jsonl"));
    if (!file.open(QIODevice::ReadOnly))
        return {};
    auto lines = file.readAll().split('\n');
    for (auto i = lines.crbegin(); i != lines.crend(); ++i) {
        const auto event = QJsonDocument::fromJson(*i).object();
        const auto kind = event.value("t").toString(), text = event.value("at").toString();
        // 原始事件文件的时间由带小数秒的 ISO 格式器写入和读取。
        if (!supported(kind) || !text.contains('.'))
            continue;
        if (auto at = parseTimestamp(text))
            return ClaudeHookEvent{kind, *at};
    }
    return {};
}
TaskActivity apply(const std::optional<ClaudeHookEvent> &event, const TaskActivity &activity) {
    if (!event || activity.phase != TaskPhase::Running)
        return activity;
    const PreciseTimestamp at{event->at, 0};
    if (auto last = activity.lastEventTimestamp(); last && at.referenceSeconds() <= last->referenceSeconds())
        return activity;
    TaskActivity waiting = activity;
    waiting.phase = TaskPhase::Waiting;
    waiting.detail = event->kind == "permission_prompt" ? QStringLiteral("等待你批准") : QStringLiteral("等待你填写");
    waiting.setLastEventTimestamp(at);
    waiting.setWaitingStartedTimestamp(at);
    return waiting;
}
} // namespace codextop::ClaudeHookEvents
