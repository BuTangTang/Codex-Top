#pragma once

#include "account_usage_protocol.h"
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <stop_token>
#include <variant>

namespace codextop {

/// 单个选定目录独享缓存和进行中的只读连接。采集线程同步调用 snapshot。
class AccountUsageClient {
public:
    using Clock = std::function<double()>;
    /// 默认用单调时钟，实际请求期限为 15 秒。测试可注入 CLI、时限及时钟。
    explicit AccountUsageClient(QString root, std::optional<QString> executable = std::nullopt,
                                double timeoutSeconds = 15, Clock clock = {});
    /// 自动请求至少相隔 60 秒，手动至少 5 秒。并发读取同一进程的结果。
    QuotaSnapshot snapshot(bool force = false, std::stop_token stop = {});
    /// 通知本实例启动的额度进程退出，所有等待者在进程回收后返回。
    void cancel();
    /// 从定位到的 macOS 应用依次检查新版、旧版内置 CLI 的实际可执行文件。
    static std::optional<QString> findBundledExecutable(const QString &application);
private:
    struct Request {
        std::stop_source stop;
        std::promise<QuotaSnapshot> promise;
        std::shared_future<QuotaSnapshot> future = promise.get_future().share();
    };
    using Result = std::variant<QuotaSnapshot, AccountUsageClientError>;
    const QString root;
    const std::optional<QString> executable;
    const double timeoutSeconds;
    const Clock clock;
    std::mutex mutex;
    std::optional<double> lastAttempt;
    std::optional<Result> cached;
    std::shared_ptr<Request> pending;
};

}
