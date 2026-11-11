#include "claude_transcript_reducer.h"
#include "codex/tool_activity_text.h"
#include <QJsonDocument>
#include <QJsonArray>
#include <algorithm>

namespace codextop {
namespace {
/// 对应 JSONSerialization 后的 as? Bool，原生也将 JSON 数字 1 识别为 true。
bool trueValue(const QJsonValue &v) {
    return v.toBool() || (v.isDouble() && v.toDouble() == 1.0);
}
/// 仅接受全为对象的段数组，与 Swift 的 [[String: Any]] 转换一致。
QJsonArray items(const QJsonValue &content) {
    const auto array = content.toArray();
    return std::all_of(array.begin(), array.end(), [](const QJsonValue &item) { return item.isObject(); }) ? array : QJsonArray{};
}
/// 只在判断中断、正式输入或特殊合成消息时临时读取首个文本段，不保存正文。
QString firstText(const QJsonValue &content) {
    if (content.isString()) return content.toString();
    for (const auto &item : items(content)) {
        const QJsonValue text = item.toObject().value("text");
        if (text.isString()) return text.toString();
    }
    return {};
}
}

void ClaudeTranscriptReducer::consume(const QByteArray &line) {
    const auto row = QJsonDocument::fromJson(line).object();
    const auto kind = row["type"].toString();
    if (kind == "custom-title" || kind == "agent-name") {
        const bool custom = kind == "custom-title";
        const auto text = row[custom ? "customTitle" : "agentName"].toString().trimmed();
        if (!text.isEmpty()) (custom ? customTitle : agentName) = text;
        return;
    }
    if ((kind != "user" && kind != "assistant") || trueValue(row["isSidechain"])) return;
    const auto at = parsePreciseTimestamp(row["timestamp"].toString());
    const auto last = activity.lastEventTimestamp();
    if (at && last && at->referenceSeconds() < last->referenceSeconds()) return;
    if (at && !firstEventAt) firstEventAt = at->date;
    const auto cwd = row["cwd"].toString();
    if (!cwd.isEmpty()) workingDirectory = cwd;
    const auto message = row["message"].toObject();
    if (kind == "user") consumeUser(row, message["content"], at);
    else consumeAssistant(row, message, message["content"], at);
}

void ClaudeTranscriptReducer::consumeUser(const QJsonObject &row, const QJsonValue &content, const Time &at) {
    const auto text = firstText(content);
    if (text.startsWith("[Request interrupted by user")) {
        finish(TaskPhase::Stopped, QStringLiteral("本轮执行已停止"), at);
        return;
    }
    bool sawToolResult = false;
    for (const auto &item : items(content)) {
        const auto object = item.toObject();
        if (object["type"].toString() != "tool_result") continue;
        sawToolResult = true;
        const auto id = object["tool_use_id"];
        if (id.isString()) {
            openToolCalls.remove(id.toString());
            waitingCalls.remove(id.toString());
        }
    }
    if (sawToolResult) {
        if (isFinished(activity.phase) || activity.phase == TaskPhase::Failed) return;
        if (waitingCalls.isEmpty()) running(at, QStringLiteral("收到输入，正在继续"));
        else if (at) activity.setLastEventTimestamp(at);
        return;
    }
    if (trueValue(row["isMeta"])) {
        if (activity.phase == TaskPhase::Completed && text.startsWith("Stop hook feedback:")) running(at, QStringLiteral("正在继续"));
        return;
    }
    if (text.trimmed().isEmpty()) return;
    activity = TaskActivity{};
    activity.phase = TaskPhase::Running;
    activity.detail = QStringLiteral("正在执行");
    activity.setLastEventTimestamp(at);
    activity.setStartedTimestamp(at);
    openToolCalls.clear();
    waitingCalls.clear();
    endsWithQuestion = false;
}

void ClaudeTranscriptReducer::consumeAssistant(const QJsonObject &row, const QJsonObject &message, const QJsonValue &content, const Time &at) {
    if (trueValue(row["isApiErrorMessage"])) {
        finish(TaskPhase::Failed, QStringLiteral("执行遇到问题，请回到 Claude Code 查看"), at);
        return;
    }
    std::optional<QString> question, tool;
    bool thinking = false;
    for (const auto &item : items(content)) {
        const auto object = item.toObject();
        const auto type = object["type"].toString();
        if (type == "thinking" || type == "redacted_thinking") thinking = true;
        if (type != "tool_use" || !object["id"].isString()) continue;
        const auto id = object["id"].toString();
        openToolCalls.insert(id);
        const auto name = object["name"].toString();
        if (name == "AskUserQuestion") {
            waitingCalls.insert(id);
            question = QStringLiteral("等待你的回答");
        } else if (name == "ExitPlanMode") {
            waitingCalls.insert(id);
            if (!question) question = QStringLiteral("等待你的确认");
        } else if (name == "mcp__ccd_turn__wrap_up") {
            // 每次收尾都覆盖之前的结论，避免先带提问后不带提问时仍误报待答。
            endsWithQuestion = !object["input"].toObject()["ask"].toString().trimmed().isEmpty();
        } else if (object["name"].isString()) tool = name;
    }
    if (question) {
        activity.phase = TaskPhase::Waiting;
        activity.detail = *question;
        if (at) activity.setLastEventTimestamp(at);
        if (!activity.waitingStartedAt) activity.setWaitingStartedTimestamp(at);
        return;
    }
    if (message["stop_reason"].toString() == "end_turn" &&
        !(message["model"].toString() == "<synthetic>" && firstText(content) == "No response requested.")) {
        if (!waitingCalls.isEmpty()) return;
        if (endsWithQuestion) {
            activity.phase = TaskPhase::Waiting;
            activity.detail = QStringLiteral("等待你确认");
            if (at) activity.setLastEventTimestamp(at);
            if (!activity.waitingStartedAt) activity.setWaitingStartedTimestamp(at);
        } else finish(TaskPhase::Completed, QStringLiteral("本轮执行已结束"), at);
        return;
    }
    if (waitingCalls.isEmpty() && !isFinished(activity.phase) && activity.phase != TaskPhase::Failed)
        running(at, tool ? ToolActivityText::detail(*tool) : thinking ? QStringLiteral("正在思考") : QStringLiteral("正在处理任务"));
}

void ClaudeTranscriptReducer::running(const Time &at, const QString &detail) {
    activity.phase = TaskPhase::Running;
    activity.detail = detail;
    activity.setWaitingStartedTimestamp(std::nullopt);
    if (at) activity.setLastEventTimestamp(at);
}

void ClaudeTranscriptReducer::finish(TaskPhase phase, const QString &detail, const Time &at) {
    activity.phase = phase;
    activity.detail = detail;
    activity.setWaitingStartedTimestamp(std::nullopt);
    if (at) activity.setLastEventTimestamp(at);
    openToolCalls.clear();
    waitingCalls.clear();
    endsWithQuestion = false;
}
}
