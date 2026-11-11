#include "refresh_schedule.h"
namespace codextop {
// 普通轮询在上一轮结束后两秒再读；文件变化在 200 毫秒内合并。
RefreshSchedule::RefreshSchedule(QObject *parent)
    : QObject(parent), changes_([this] { requestFastRefresh(); }) {
    periodic_.setSingleShot(true);
    periodic_.setInterval(2000);
    fast_.setSingleShot(true);
    fast_.setInterval(200);
    connect(&periodic_, &QTimer::timeout, this, [this] {
        if (!paused_ && !active_)
            begin(true);
        else if (running_)
            periodic_.start();
    });
    connect(&fast_, &QTimer::timeout, this, [this] {
        if (pending_ && !active_ && running_ && !paused_) {
            pending_ = false;
            begin(false);
        }
    });
}
// 启动时先读取一轮；已暂停时等待恢复。
void RefreshSchedule::start() {
    if (running_)
        return;
    running_ = true;
    refreshWatches();
    if (!paused_ && !active_)
        begin(true);
    else
        periodic_.start();
}
// 退出后取消所有监听和待发请求；过时的在途结果不能用于发布。
void RefreshSchedule::stop() {
    running_ = false;
    periodic_.stop();
    resetSource();
}
// 暂停不打断在途扫描；恢复时合并为一次快速读取。
void RefreshSchedule::setPaused(bool value) {
    if (paused_ == value)
        return;
    paused_ = value;
    if (paused_) {
        pending_ = false;
        fast_.stop();
    }
    refreshWatches();
    if (!paused_)
        requestFastRefresh();
}
// 切换数据目录时撤销旧文件的通知，并使旧目录的结果作废。
void RefreshSchedule::resetSource() {
    ++generation_;
    fast_.stop();
    pending_ = false;
    changes_.stop();
    watching_.clear();
}
// 实际监听等回答的任务；若等待来自子任务，用子任务的记录路径。
void RefreshSchedule::updateWatches(const QList<CodexTask> &tasks, const QHash<QString, QString> &roots,
                                    const QSet<QString> &selected) {
    watching_.clear();
    for (const auto &task : tasks)
        if (task.activity.phase == TaskPhase::Waiting && selected.contains(roots.value(task.id, task.id)))
            watching_.insert(QUrl::fromLocalFile(task.rolloutPath));
    refreshWatches();
}
// 暂停或关闭时释放系统监听，之后可从当前关注集合恢复。
void RefreshSchedule::refreshWatches() {
    if (running_ && !paused_)
        changes_.update(watching_);
    else
        changes_.stop();
}
// 同一轮扫描期间的多次写入只保留一次待办。
void RefreshSchedule::requestFastRefresh() {
    if (!running_ || paused_)
        return;
    pending_ = true;
    scheduleFastRefresh();
}
// 忙碌时保留待办，到 finish 后才启动延时。
void RefreshSchedule::scheduleFastRefresh() {
    if (pending_ && running_ && !paused_ && !active_ && !fast_.isActive())
        fast_.start();
}
// 手动刷新仍可在暂停自动刷新期间执行。
void RefreshSchedule::refreshManually() {
    if (running_ && !active_)
        begin(false);
}
// 发出带唯一编号的读取请求，记录发起时的数据源代次。
void RefreshSchedule::begin(bool regular) {
    regularScan_ = regular;
    active_ = ++sequence_;
    requestGeneration_ = generation_;
    emit refreshRequested(active_);
}
// 返回该结果是否仍属于当前数据源，并接续定时读取和扫描期间积累的写入。
bool RefreshSchedule::finish(quint64 request) {
    if (!active_ || active_ != request)
        return false;
    active_ = 0;
    if (!running_)
        return false;
    if (regularScan_)
        periodic_.start();
    scheduleFastRefresh();
    return requestGeneration_ == generation_;
}
} // namespace codextop
