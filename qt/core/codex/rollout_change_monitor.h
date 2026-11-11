#pragma once
#include <QObject>
#include <QFileSystemWatcher>
#include <QSet>
#include <QUrl>
#include <functional>

namespace codextop {
// 在所属事件线程上监听已选文件，不打开或解析对话内容。
class RolloutChangeMonitor final : public QObject {
  public:
    explicit RolloutChangeMonitor(std::function<void()> onChange, QObject *parent = nullptr);
    void update(const QSet<QUrl> &urls);
    void stop();

  private:
    std::function<void()> onChange_;
    QFileSystemWatcher *watcher_ = nullptr;
};
} // namespace codextop
