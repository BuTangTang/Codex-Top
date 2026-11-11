#include "account_usage_client.h"
#include <QDeadlineTimer>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QProcess>
#include <QProcessEnvironment>
#include <QScopeGuard>
#include <chrono>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <appmodel.h>
#include <vector>
#endif

namespace codextop {

#ifdef Q_OS_MACOS
QString registeredCodexApplication();
#endif

namespace {

/// 只允许可执行的普通文件，目录不能作为进程入口。
bool isExecutable(const QString &path) {
    QFileInfo info(path);
    return info.isFile() && info.isExecutable();
}

#ifdef Q_OS_WIN
/// 用当前用户注册的官方包族获取安装路径，版本变化时重新解析。
std::optional<QString> packagedWindowsExecutable() {
    constexpr auto family = L"OpenAI.Codex_2p2nqsd0c76g0";
    UINT32 count = 0, chars = 0;
    if (GetPackagesByPackageFamily(family, &count, nullptr, &chars, nullptr) != ERROR_INSUFFICIENT_BUFFER)
        return std::nullopt;
    std::vector<PWSTR> names(count);
    std::vector<wchar_t> storage(chars);
    if (GetPackagesByPackageFamily(family, &count, names.data(), &chars, storage.data()) != ERROR_SUCCESS)
        return std::nullopt;
    for (UINT32 i = 0; i < count; ++i) {
        UINT32 length = 0;
        if (GetPackagePathByFullName(names[i], &length, nullptr) != ERROR_INSUFFICIENT_BUFFER) continue;
        std::vector<wchar_t> path(length);
        if (GetPackagePathByFullName(names[i], &length, path.data()) != ERROR_SUCCESS) continue;
        const auto cli = QDir(QString::fromWCharArray(path.data())).filePath("app/resources/codex.exe");
        if (isExecutable(cli)) return cli;
    }
    return std::nullopt;
}
#endif

/// 优先使用正式桌面应用的 CLI，然后检查原生独立安装位置及 PATH 里的绝对目录。
std::optional<QString> findExecutable() {
    QStringList candidates;
#ifdef Q_OS_MACOS
    if (auto bundled = AccountUsageClient::findBundledExecutable(registeredCodexApplication())) return bundled;
    candidates << "/opt/homebrew/bin/codex" << "/usr/local/bin/codex";
#elif defined(Q_OS_WIN)
    if (auto bundled = packagedWindowsExecutable()) return bundled;
#endif
#ifdef Q_OS_WIN
    const auto name = QStringLiteral("codex.exe");
#else
    const auto name = QStringLiteral("codex");
#endif
    const auto entries = qEnvironmentVariable("PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
    for (const auto &entry : entries)
        if (QDir::isAbsolutePath(entry)) candidates << QDir(entry).filePath(name);
    for (const auto &candidate : candidates)
        if (isExecutable(candidate)) return candidate;
    return std::nullopt;
}

/// 单调时钟只用于连接限频，不会受系统时间调整影响。
double uptime() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

/// 轮询只读 stdout 时保持原生 50 毫秒的取消粒度，并使用一次性绝对期限。
int waitSlice(const std::stop_token &stop, const QDeadlineTimer &deadline) {
    if (stop.stop_requested()) throw AccountUsageCancelled{};
    const auto remaining = deadline.remainingTime();
    if (!remaining) throw AccountUsageClientError::TimedOut;
    return int(std::min<qint64>(50, remaining));
}

/// 不转发后端错误，写入失败统一显示账户不可用。
void send(QProcess &process, const QByteArray &message) {
    if (process.write(message) != message.size()) throw AccountUsageClientError::Unavailable;
}

/// 按行握手。成功请求只产出数值模型，其他消息在当前行解析后立即丢弃。
std::optional<QuotaSnapshot> consumeMessage(const QByteArray &line, bool &initialized, QProcess &process,
                                            const std::stop_token &stop) {
    if (line.isEmpty()) return std::nullopt;
    const auto document = QJsonDocument::fromJson(line);
    if (!document.isObject()) throw AccountUsageClientError::InvalidResponse;
    const auto message = document.object();
    if (message.contains("method")) return std::nullopt;
    const auto id = message.value("id");
    // Foundation 的 NSNumber 桥接让 true 也能转成 Int(1)，保留同一解析行为。
    const auto identifier = id.isBool() ? qint64(id.toBool()) : id.toInteger(-1);
    const bool initialReply = identifier == 1 && !initialized;
    const bool quotaReply = identifier == 2 && initialized;
    if (!initialReply && !quotaReply) return std::nullopt;
    if (message.contains("error") || !message.value("result").isObject())
        throw AccountUsageClientError::Unavailable;
    if (initialReply) {
        initialized = true;
        send(process, AccountUsageProtocol::read());
        return std::nullopt;
    }
    if (stop.stop_requested()) throw AccountUsageCancelled{};
    return AccountUsageProtocol::decodeResult(message.value("result").toObject(), QDateTime::currentDateTimeUtc());
}

/// 此函数独占并回收 QProcess，在返回成功、失败、超时或取消之前关闭连接。
QuotaSnapshot runProcess(const QString &root, const std::optional<QString> &injected,
                         double timeout, const std::stop_token &stop) {
    if (stop.stop_requested()) throw AccountUsageCancelled{};
    const auto executable = injected ? injected : findExecutable();
    if (!executable || !isExecutable(*executable)) throw AccountUsageClientError::CliUnavailable;
    QProcess process;
    process.setProgram(*executable);
    process.setArguments({"app-server", "--stdio"});
    process.setWorkingDirectory(root);
    auto environment = QProcessEnvironment::systemEnvironment();
    environment.insert("CODEX_HOME", root);
    process.setProcessEnvironment(environment);
    process.setStandardErrorFile(QProcess::nullDevice());
    QDeadlineTimer deadline(std::chrono::duration<double>(timeout), Qt::PreciseTimer);
    process.start();
    const auto cleanup = qScopeGuard([&] {
        process.closeWriteChannel();
        if (process.state() == QProcess::NotRunning) return;
        process.terminate();
        if (!process.waitForFinished(250) && process.state() != QProcess::NotRunning) {
            process.kill();
            process.waitForFinished(-1);
        }
    });
    while (process.state() == QProcess::Starting) process.waitForStarted(waitSlice(stop, deadline));
    if (process.state() == QProcess::NotRunning) throw AccountUsageClientError::Unavailable;
    send(process, AccountUsageProtocol::initialize());
    QByteArray buffer;
    bool initialized = false;
    qsizetype bytesRead = 0;
    while (true) {
        const auto slice = waitSlice(stop, deadline);
        if (!process.bytesAvailable()) {
            if (process.state() == QProcess::NotRunning) throw AccountUsageClientError::Unavailable;
            process.waitForReadyRead(slice);
        }
        if (!process.bytesAvailable()) continue;
        const auto chunk = process.read(16384);
        if (chunk.isEmpty()) throw AccountUsageClientError::Unavailable;
        bytesRead += chunk.size();
        if (bytesRead > 1048576) throw AccountUsageClientError::InvalidResponse;
        buffer.append(chunk);
        qsizetype begin = 0, end;
        while ((end = buffer.indexOf('\n', begin)) >= 0) {
            if (auto value = consumeMessage(buffer.mid(begin, end - begin), initialized, process, stop)) return *value;
            begin = end + 1;
        }
        buffer.remove(0, begin);
    }
}

}

std::optional<QString> AccountUsageClient::findBundledExecutable(const QString &application) {
    if (application.isEmpty()) return std::nullopt;
    for (const auto &path : {"Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"}) {
        const auto executable = QDir(application).filePath(path);
        if (isExecutable(executable)) return executable;
    }
    return std::nullopt;
}

AccountUsageClient::AccountUsageClient(QString selectedRoot, std::optional<QString> selectedExecutable,
                                       double timeout, Clock selectedClock)
    : root(QDir::cleanPath(QFileInfo(selectedRoot).absoluteFilePath())), executable(std::move(selectedExecutable)),
      timeoutSeconds(std::max(0.05, timeout)), clock(selectedClock ? std::move(selectedClock) : Clock(uptime)) {}

QuotaSnapshot AccountUsageClient::snapshot(bool force, std::stop_token stop) {
    if (stop.stop_requested()) throw AccountUsageCancelled{};
    bool ownsProcess = false;
    std::shared_ptr<Request> request;
    {
        const std::lock_guard guard(mutex);
        request = pending;
        if (!request) {
            const double now = clock();
            if (lastAttempt && now - *lastAttempt < (force ? 5 : 60)) {
                if (!cached) throw AccountUsageClientError::Unavailable;
                if (auto *error = std::get_if<AccountUsageClientError>(&*cached)) throw *error;
                return std::get<QuotaSnapshot>(*cached);
            }
            request = pending = std::make_shared<Request>();
            lastAttempt = now;
            ownsProcess = true;
        }
    }
    std::stop_callback onCancel(stop, [&] { request->stop.request_stop(); });
    if (ownsProcess) {
        try {
            auto value = runProcess(root, executable, timeoutSeconds, request->stop.get_token());
            const std::lock_guard guard(mutex);
            cached = value;
            request->promise.set_value(std::move(value));
            pending.reset();
        } catch (...) {
            const auto exception = std::current_exception();
            const std::lock_guard guard(mutex);
            try { std::rethrow_exception(exception); }
            catch (const AccountUsageCancelled &) { /* 原生取消不覆盖最近一次缓存。 */ }
            catch (AccountUsageClientError error) { cached = error; }
            catch (...) { cached = AccountUsageClientError::Unavailable; }
            request->promise.set_exception(exception);
            pending.reset();
        }
    }
    return request->future.get();
}

void AccountUsageClient::cancel() {
    const std::lock_guard guard(mutex);
    if (pending) pending->stop.request_stop();
}

}
