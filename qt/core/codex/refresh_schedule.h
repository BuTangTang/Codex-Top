#pragma once
#include "codex/rollout_change_monitor.h"
#include "models/models.h"
#include <QHash>
#include <QTimer>

namespace codextop {
// M2 的任务仓库收到请求后异步读快照，并用同一个编号回报完成。
// 两秒轮询与文件事件共用一个在途请求；额度查询有自己的节奏。
class RefreshSchedule final : public QObject {
    Q_OBJECT
  public:
    explicit RefreshSchedule(QObject *parent = nullptr);
    void start();
    void stop();
    void setPaused(bool paused);
    void resetSource();
    void updateWatches(const QList<CodexTask> &tasks, const QHash<QString, QString> &roots,
                       const QSet<QString> &selected);
    void refreshManually();
    bool finish(quint64 request);
  signals:
    void refreshRequested(quint64 request);

  private:
    void requestFastRefresh();
    void scheduleFastRefresh();
    void begin(bool regular);
    void refreshWatches();
    QTimer periodic_, fast_;
    RolloutChangeMonitor changes_;
    QSet<QUrl> watching_;
    bool running_ = false, paused_ = false, pending_ = false, regularScan_ = false;
    quint64 generation_ = 0, requestGeneration_ = 0, sequence_ = 0, active_ = 0;
};
} // namespace codextop
