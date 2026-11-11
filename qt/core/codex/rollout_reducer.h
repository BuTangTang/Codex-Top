#pragma once

#include "models/models.h"
#include <QByteArray>
#include <QFile>
#include <QHash>
#include <QJsonObject>
#include <QSet>
#include <memory>

namespace codextop {

struct QuestionReplyReceipt;
class RolloutTimingRecovery;

/// 每次只处理一条记录，跨行仅保留活动、额度和核对回复所需的编号。
class RolloutReducer {
public:
    TaskActivity activity;
    std::optional<QuotaSnapshot> quota;
    bool isAutomaticTeamChatCopy = false;

    /// 只认 session_meta 中类型严格为布尔真值的自动副本标记。
    static bool isAutomaticCopyHeader(const QJsonObject &record);
    /// 只有非负整数序号才能证明该副本内的一行来自远端导入。
    static bool hasImportedOrdinal(const QJsonObject &record);
    /// 已确认本机执行时，较长的本机事件沿用已有的压缩行摘要规则。
    bool acceptsNativeLineSummary() const;
    /// 中途跳过、无法解析或遇到本机行时撤销纯导入结论。
    void noteUninspectedRecord();
    /// 追平且没有未完成的行后才发布纯导入状态。
    void publishImportIfComplete(bool complete);

    /// 消化一条完整 JSON 行，忽略格式未知、时间倒退或属于旧轮次的记录。
    void consume(const QByteArray &line);
    /// 保守估算当前元数据占用，供压缩记录限制内存。
    qsizetype retainedMetadataBytes() const;
    /// 返回可向桌面核对的最早活动提问时间。
    std::optional<QDateTime> awaitingReplySince() const;
    /// 投影已核实的回执，不改变归约器的阶段、时间或问题集合。
    TaskActivity activityAcknowledging(const QList<QuestionReplyReceipt> &receipts,
                                      const QString &threadID, const QDateTime &now) const;
private:
    friend class IncrementalRollout;
    struct ReplyQuestion { PreciseTimestamp askedAt; QSet<int> items; };
    QSet<QString> waitingCallIDs;
    QHash<QString, ReplyQuestion> replyQuestions;
    bool asynchronousQuestion = false;
    bool untrackedWait = false;
    bool turnEnded = false;
    bool expectsFileHeader = true;
    bool hasNativePagination = false;
    bool onlyImportedRecords = false;

    /// 清空上一次提问的回执匹配状态。
    void clearReplyQuestions();
    /// 从异步提问参数中仅保留调用编号和问题序号。
    void rememberReplyQuestion(const QJsonObject &payload, const std::optional<PreciseTimestamp> &at);
    /// 进入运行态；旧轮已结束时重新建立开始锚点。
    void active(const std::optional<PreciseTimestamp> &at, const QString &detail);
    /// 进入等待态；连续等待保留首次进入时刻，包括首次时刻缺失的情形。
    void waiting(const std::optional<PreciseTimestamp> &at, const QString &detail);
    /// 只在轮次、状态和末次事件兼容时补回开始时间。
    void recoverTiming(const TaskActivity &recovered);
    /// 保留本次记录中可识别的 Codex 额度窗口。
    void updateQuota(const QJsonObject &limits, const QDateTime &at);
};

/// 文件本身的身份和精确修改时间，同时供普通记录和压缩记录核验。
struct RolloutFileMetadata {
    quint64 device = 0, inode = 0;
    qint64 size = 0, seconds = 0, nanoseconds = 0;
    bool regular = false;
    bool operator==(const RolloutFileMetadata &) const = default;
    /// 读取末级路径本身，不跟随符号链接。失败抛出 std::system_error。
    static RolloutFileMetadata read(const QString &path);
    /// 核对已打开文件句柄的身份，避免路径替换使历史回查跨代。
    static RolloutFileMetadata read(QFile &openFile);
};

/// 首次有界读尾部，后续按游标顺序追读；独立回查仅补齐本轮开始时间。
class IncrementalRollout {
public:
    /// 冷读至少 1 KiB；每轮追读预算至少容得下一个块。
    explicit IncrementalRollout(int maximumRead = 65536, int maximumCatchUpRead = 4 * 1024 * 1024);
    RolloutReducer reducer;
    qint64 offset = 0;
    bool isCaughtUp = false;

    /// 返回本轮实读字节数；文件未变返回零，读取失败抛 std::system_error。
    int refresh(const QString &path);
    /// 回查同一代文件的最近明确开始记录，不移动主游标。
    int recoverTiming(const QString &path, int maximumBytes = 4 * 1024 * 1024);
private:
    int maximumRead;
    int maximumCatchUpRead;
    std::optional<RolloutFileMetadata> observed;
    QByteArray pending;
    bool skippingLongLine = false;
    // 在共享游标副本继续回查前独立复制；普通快照复制无需复制回放缓冲。
    std::shared_ptr<RolloutTimingRecovery> timingRecovery;
};
} // namespace codextop
