#pragma once
#include "models/models.h"
#include <QByteArray>

namespace codextop {
struct ClaudeHookEvent {
    QString kind;
    QDateTime at;
    bool operator==(const ClaudeHookEvent &) const = default;
};

namespace ClaudeHookEvents {
/// 将批准或填写通知投影为只含类型与时间的文件，输入或路径无效时静默退出。
void record(const QByteArray &input, const QString &directory, const QDateTime &now = QDateTime::currentDateTimeUtc());
/// 返回指定会话文件最后一条有效事件，失效或未知时继续使用会话记录。
std::optional<ClaudeHookEvent> latest(const QString &directory, const QString &session);
/// 只有运行状态且通知晚于会话最新活动时才覆盖为等待。
TaskActivity apply(const std::optional<ClaudeHookEvent> &event, const TaskActivity &activity);
} // namespace ClaudeHookEvents
} // namespace codextop
