#pragma once
#include "models/models.h"
#include <QJsonObject>
#include <QSet>

namespace codextop {
/// 逐行提取主会话的活动、标题和目录，不保留消息正文、提问内容及工具参数。
class ClaudeTranscriptReducer {
public:
    TaskActivity activity;
    std::optional<QString> workingDirectory;
    std::optional<QDateTime> firstEventAt;
    /// 自定义标题优先，其次使用会话名。
    std::optional<QString> title() const { return customTitle ? customTitle : agentName; }
    /// 读取完整的单行 JSON；不认识的事件、子代理和旧消息不改变主状态。
    void consume(const QByteArray &line);
private:
    std::optional<QString> customTitle, agentName;
    QSet<QString> openToolCalls, waitingCalls;
    bool endsWithQuestion = false;
    using Time = std::optional<PreciseTimestamp>;
    /// 按中断、工具返回、元信息、正式提问的既有顺序消费用户行。
    void consumeUser(const QJsonObject &row, const QJsonValue &content, const Time &at);
    /// 处理接口错误、思考与工具、待答和结束事件。
    void consumeAssistant(const QJsonObject &row, const QJsonObject &message, const QJsonValue &content, const Time &at);
    /// 继续当前轮，清除等待锚点并保留已知开始时间。
    void running(const Time &at, const QString &detail);
    /// 结束当前轮并清理其所有工具编号与收尾提问。
    void finish(TaskPhase phase, const QString &detail, const Time &at);
};
}
