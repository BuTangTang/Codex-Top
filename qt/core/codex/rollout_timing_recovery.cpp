#include "rollout_timing_recovery.h"
#include <QJsonDocument>
#include <algorithm>

namespace codextop {
namespace {
/// 时间戳无效的开始事件依然是边界，不能据此越过它借用旧轮次的开始时间。
bool isStart(const QByteArray &line) {
    const auto record = QJsonDocument::fromJson(line).object();
    if (record["type"].toString() != "event_msg") return false;
    const auto type = record["payload"].toObject()["type"].toString();
    return type == "task_started" || type == "turn_started";
}
}

int RolloutTimingRecovery::advance(QFile &file, qint64 end, int blockSize, int budget) {
    int bytesRead = 0;
    while (bytesRead < budget && stage != Stage::Finished) {
        if (stage == Stage::Search && searchOffset == 0) {
            finishSearchAtBeginning();
            continue;
        }
        if (stage == Stage::Replay && replayOffset >= end) {
            recovered = replay.activity;
            stage = Stage::Finished;
            break;
        }
        const int count = int(std::min<qint64>({blockSize, budget - bytesRead,
                                                stage == Stage::Search ? searchOffset : end - replayOffset}));
        const qint64 base = stage == Stage::Search ? searchOffset - count : replayOffset;
        if (!file.seek(base)) {
            stage = Stage::Finished;
            break;
        }
        auto data = file.read(count);
        bytesRead += int(data.size());
        if (data.size() != count) {
            stage = Stage::Finished;
            break;
        }
        if (stage == Stage::Search) {
            searchOffset = base;
            search(data, base, blockSize);
        } else {
            replayOffset += count;
            pending.append(data);
            qsizetype begin = 0, newline;
            while ((newline = pending.indexOf('\n', begin)) >= 0) {
                const auto length = newline - begin;
                if (!skippingLongLine && length > 0 && length <= blockSize)
                    replay.consume(QByteArray::fromRawData(pending.constData() + begin, length));
                skippingLongLine = false;
                begin = newline + 1;
            }
            pending.remove(0, begin);
            if (pending.size() > blockSize) {
                pending.clear();
                skippingLongLine = true;
            }
        }
    }
    if (stage == Stage::Replay && replayOffset == end) {
        recovered = replay.activity;
        stage = Stage::Finished;
    }
    return bytesRead;
}

void RolloutTimingRecovery::search(const QByteArray &data, qint64 base, int maximumLine) {
    qsizetype end = data.size();
    while (end > 0) {
        const auto newline = data.lastIndexOf('\n', end - 1);
        if (newline < 0) break;
        const auto length = end - newline - 1;
        if (!skippingReverseLine && length + reverseSuffix.size() <= maximumLine
            && isStart(data.mid(newline + 1, length) + reverseSuffix)) {
            beginReplay(base + newline + 1);
            return;
        }
        reverseSuffix.clear();
        skippingReverseLine = false;
        end = newline;
    }
    if (!skippingReverseLine) {
        if (end + reverseSuffix.size() <= maximumLine) reverseSuffix.prepend(data.constData(), end);
        else {
            reverseSuffix.clear();
            skippingReverseLine = true;
        }
    }
    if (searchOffset == 0) finishSearchAtBeginning();
}

void RolloutTimingRecovery::finishSearchAtBeginning() {
    if (!skippingReverseLine && isStart(reverseSuffix)) beginReplay(0);
    else {
        reverseSuffix.clear();
        stage = Stage::Finished;
    }
}

void RolloutTimingRecovery::beginReplay(qint64 offset) {
    reverseSuffix.clear();
    replayOffset = offset;
    stage = Stage::Replay;
}
} // namespace codextop
