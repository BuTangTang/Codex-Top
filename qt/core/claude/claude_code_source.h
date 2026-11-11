#pragma once

#include "claude_session_registry.h"
#include "claude_transcript_reducer.h"
#include <QSet>

namespace codextop {
/// 指定数据根下的 Claude 会话来源。由采集线程串行刷新同一实例。
class ClaudeCodeSource {
public:
    using ReadRegistry = std::function<ClaudeSessionRegistry(const QString &)>;
    /// 优先使用 CLAUDE_CONFIG_DIR，否则使用用户目录下的 .claude。
    static QString defaultRoot();
    /// 可注入合成目录、独立的钩子事件目录和进程登记来源。
    explicit ClaudeCodeSource(QString root = defaultRoot(), QString hookEvents = {}, ReadRegistry readRegistry = {});
    /// 数据根目录存在时视为已安装。
    bool installed() const;
    /// 遍历直接项目子目录，保留已关注或进程存活的会话，并合并同编号副本。
    SourceSnapshot snapshot(QSet<QString> keepIDs = {}, QDateTime now = QDateTime::currentDateTimeUtc());
private:
    struct Tail { qint64 size,offset; ClaudeTranscriptReducer reducer; };
    QString root, hookEvents;
    ReadRegistry readRegistry;
    QHash<QString,Tail> tails;
    /// 从上次完整行后接着读；冷读逐级扩大尾部窗口直到遇见对话行。
    std::pair<ClaudeTranscriptReducer,qint64> advance(const QString &path, qint64 size);
    /// 只消化完整行，分别报告已消费和实读字节数，保留后续可能写完的半行。
    static std::pair<qint64,qint64> consume(const QString &path, qint64 offset, ClaudeTranscriptReducer &reducer, bool dropFirstLine);
};
}
