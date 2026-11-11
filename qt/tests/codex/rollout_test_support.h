#pragma once
#include "codex/rollout_reducer.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QTest>
#include <QTimeZone>

namespace rolloutFixture {
using namespace codextop;

/// 单元测试在固定 UTC 时钟上推进；不依赖当前系统时间。
inline QDateTime instant(int seconds = 0) {
    return QDateTime::fromSecsSinceEpoch(1800000000 + qint64(seconds), QTimeZone::UTC);
}
/// 生成合成 JSON 记录；有意缺少时间时完全省略 timestamp 字段。
inline QByteArray recordEvent(const QString &type, std::optional<int> seconds = 0, QJsonObject extra = {},
                        const QString &kind = "event_msg") {
    extra["type"] = type;
    QJsonObject record{{"type", kind}, {"payload", extra}};
    if (seconds) record["timestamp"] = instant(*seconds).toString(Qt::ISODate);
    return QJsonDocument(record).toJson(QJsonDocument::Compact);
}
/// 生成写入用户记录之前的 response_item 工具调用或回复。
inline QByteArray response(const QString &type, std::optional<int> seconds, const QJsonObject &extra) {
    return recordEvent(type, seconds, extra, "response_item");
}
/// 将独立的合成记录按真实格式逐行写入。
inline QByteArray lines(const QList<QByteArray> &items) {
    QByteArray data;
    for (const auto &item : items) data += item + '\n';
    return data;
}
/// 在首尾事件之间隔一条超长历史行，使冷读窗口看不到开头。
inline QByteArray contents(const QList<QByteArray> &prefix, const QList<QByteArray> &suffix, int padding = 8192) {
    return lines(prefix) + QByteArray(padding, 'x') + '\n' + lines(suffix);
}
/// 覆盖临时记录本身并截断，保留文件身份。
inline void overwrite(const QString &path, const QByteArray &data) {
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    QCOMPARE(file.write(data), data.size());
    QVERIFY(file.flush());
}
/// 添加真实字节到临时记录，用于清楚地区分追加和重写。
inline void append(const QString &path, const QByteArray &data) {
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Append));
    QCOMPARE(file.write(data), data.size());
    QVERIFY(file.flush());
}
/// 用显式时刻测试文件重写，不依赖写入速度或文件系统时钟间隔。
inline void setModified(const QString &path, QDateTime at) {
    QFile file(path);
    QVERIFY(file.open(QIODevice::ReadWrite));
    QVERIFY(file.setFileTime(at, QFileDevice::FileModificationTime));
}
/// 生成带编号的工具调用。
inline QByteArray call(const QString &name, const QString &id, std::optional<int> seconds) {
    return response("function_call", seconds, {{"name", name}, {"call_id", id}});
}
/// 生成指定提问或普通工具的返回记录。
inline QByteArray output(const QString &id, int seconds) {
    return response("function_call_output", seconds, {{"call_id", id}});
}
/// 构造一个刚开始的轮次，用于旧轮编号冲突与计时核对。
inline QByteArray startTurn(const QString &id, std::optional<int> seconds = 0) {
    return recordEvent("task_started", seconds, {{"turn_id", id}});
}
/// 增量与集成测试共用的当前轮次和待答事件。
inline QByteArray initialQuestion(int seconds = 0, const QString &id = "question") {
    return lines({startTurn("current"), call("request_user_input_async", id, seconds)});
}
} // namespace rolloutFixture
