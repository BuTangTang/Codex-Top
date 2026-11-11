#include "rollout_change_monitor.h"
#include <QDir>
#include <QFileInfo>
#include <algorithm>

namespace codextop {
// 回调在监听器所在线程执行，销毁监视器会一并清理系统监听。
RolloutChangeMonitor::RolloutChangeMonitor(std::function<void()> onChange, QObject *parent)
    : QObject(parent), onChange_(std::move(onChange)) {}

// 撤销当前代次；即便删除/换名信号已经入队，也不能通知新的监听器。
void RolloutChangeMonitor::stop() {
    if (!watcher_)
        return;
    auto *old = std::exchange(watcher_, nullptr);
    old->disconnect(this);
    const auto paths = old->files();
    if (!paths.isEmpty())
        old->removePaths(paths);
    old->deleteLater();
}

// 规范化并选取字典序最前的 64 个本地文件；删除或重命名后可在下轮重新绑定。
void RolloutChangeMonitor::update(const QSet<QUrl> &urls) {
    QSet<QString> unique;
    for (const auto &url : urls) {
        if (url.isLocalFile())
            unique.insert(QDir::cleanPath(QFileInfo(url.toLocalFile()).absoluteFilePath()));
    }
    auto desired = unique.values();
    std::sort(desired.begin(), desired.end());
    desired = desired.mid(0, 64);
    if (desired.isEmpty()) {
        stop();
        return;
    }
    if (watcher_) {
        const auto watched = watcher_->files();
        if (std::any_of(watched.cbegin(), watched.cend(),
                        [&](const QString &path) { return !desired.contains(path); }))
            stop();
    }
    if (!watcher_) {
        auto *current = watcher_ = new QFileSystemWatcher(this);
        connect(current, &QFileSystemWatcher::fileChanged, this, [this, current](const QString &) {
            if (watcher_ == current)
                onChange_();
        });
    }
    const auto watched = watcher_->files();
    for (const auto &path : desired) {
        if (!watched.contains(path) && QFileInfo(path).isFile())
            watcher_->addPath(path);
    }
}
} // namespace codextop
