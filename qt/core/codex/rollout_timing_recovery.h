#pragma once

#include "rollout_reducer.h"

namespace codextop {
/// 先向前寻找最近的明确开始记录，再按正常规则顺向重放。
class RolloutTimingRecovery {
public:
    /// 从已由主游标采样的尾部开始搜索。
    explicit RolloutTimingRecovery(qint64 end) : searchOffset(end) {}
    /// 反查和重放共用本次字节预算；读取问题只结束辅助回查。
    int advance(QFile &file, qint64 end, int blockSize, int budget);
    /// 本次文件代次是否已得到结论（包括无法回查）。
    bool isFinished() const { return stage == Stage::Finished; }
    std::optional<TaskActivity> recovered;
private:
    enum class Stage { Search, Replay, Finished };
    Stage stage = Stage::Search;
    qint64 searchOffset;
    QByteArray reverseSuffix;
    bool skippingReverseLine = true;
    qint64 replayOffset = 0;
    QByteArray pending;
    bool skippingLongLine = false;
    RolloutReducer replay;
    /// 从块尾逐行反查，跨块只保留有界行片段。
    void search(const QByteArray &data, qint64 base, int maximumLine);
    /// 在文件开头核对首行后结束搜索或转入重放。
    void finishSearchAtBeginning();
    /// 清掉反查缓冲并从找到的开始行正向重放。
    void beginReplay(qint64 offset);
};
} // namespace codextop
