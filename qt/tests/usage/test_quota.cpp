#include "usage/account_usage_client.h"
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QTest>
#include <QThread>
#include <QTimeZone>
#include <array>
#include <atomic>
#include <cstdio>
#include <iostream>
#include <string>
#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <csignal>
#include <cerrno>
#endif

using namespace codextop;

namespace {
const QByteArray successful = R"({"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000300}}}})";
const QByteArray failed = R"({"id":2,"error":{"code":-1,"message":"synthetic-token-do-not-display","data":{"secret":"synthetic-secret"}}})";

/// 合成服务仅在测试自己创建并留下标记的临时根下运行和写文件。
bool writeFile(const QString &path, const QByteArray &data, bool append = false) {
    QFile f(path);
    return f.open(QIODevice::WriteOnly | (append ? QIODevice::Append : QIODevice::Truncate))
        && f.write(data) == data.size() && f.flush();
}

QByteArray readFile(const QString &path) {
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray{};
}

/// 同一测试二进制扮演 CLI，使用真正的进程、stdio、当前目录和环境，兼容 Windows。
int serve() {
    const auto root = qEnvironmentVariable("CODEX_HOME");
    const QDir dir(root);
    if (root.isEmpty() || !dir.exists("synthetic-fixture") || dir.canonicalPath() != QDir::current().canonicalPath()) return 2;
    const auto mode = readFile(dir.filePath("synthetic-fixture")).trimmed();
#ifndef Q_OS_WIN
    if (mode == "hang") std::signal(SIGTERM, SIG_IGN);
#endif
    if (!writeFile(dir.filePath("root"), root.toUtf8()) || !writeFile(dir.filePath("attempts"), "attempt\n", true)
            || !writeFile(dir.filePath("pid"), QByteArray::number(QCoreApplication::applicationPid()))) return 3;
    for (int i = 0; i < 3; ++i) {
        std::string line;
        if (!std::getline(std::cin, line)) return 4;
        if (!writeFile(dir.filePath("requests"), QByteArray::fromStdString(line) + '\n', true)) return 5;
        if (i == 0 && mode == "closed-input") {
            std::fclose(stdin);
            std::cout << R"({"id":1,"result":{}})" << '\n' << successful.toStdString() << std::endl;
            QThread::sleep(60);
            return 6;
        }
        if (i == 0) std::cout << R"({"id":1,"result":{}})" << std::endl;
    }
    if (mode == "hang") {
        QThread::sleep(60);
        return 6;
    }
    if (mode == "unrelated") std::cout << R"({"method":"unrelated","params":{"ignored":"synthetic"}})" << std::endl;
    std::cout << readFile(dir.filePath("account-response")).toStdString() << std::endl;
    return 0;
}

struct Fixture {
    QTemporaryDir dir;
    bool ready = false;
    /// 每个用例用独立目录和相同协议；可在两次实际启动之间替换合成账户响应。
    explicit Fixture(const QByteArray &mode = {}) {
        ready = dir.isValid() && writeFile(dir.filePath("synthetic-fixture"), mode) && response(successful);
    }
    bool response(const QByteArray &value) { return writeFile(dir.filePath("account-response"), value); }
    QString executable() const { return QCoreApplication::applicationFilePath(); }
    int attempts() const { return readFile(dir.filePath("attempts")).count('\n'); }
    QStringList methods() const {
        QStringList result;
        for (const auto &line : readFile(dir.filePath("requests")).split('\n')) {
            if (!line.trimmed().isEmpty()) result << QJsonDocument::fromJson(line).object().value("method").toString();
        }
        return result;
    }
    /// 用原始进程标识查证返回时自有 CLI 已退出；Unix 同时检查子进程已被回收。
    bool reaped() const {
        bool ok;
        const auto pid = readFile(dir.filePath("pid")).trimmed().toUInt(&ok);
        if (!ok || !pid) return false;
#ifdef Q_OS_WIN
        HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
        if (!process) return GetLastError() == ERROR_INVALID_PARAMETER;
        const bool exited = WaitForSingleObject(process, 0) == WAIT_OBJECT_0;
        CloseHandle(process);
        return exited;
#else
        return ::kill(pid_t(pid), 0) == -1 && errno == ESRCH;
#endif
    }
};

/// 对错误码本身作断言，确保通用错误提示不泄露后端字段。
template<class Operation>
void expectError(AccountUsageClientError expected, Operation operation) {
    try {
        operation();
        QFAIL("应返回额度错误");
    } catch (AccountUsageClientError actual) {
        QCOMPARE(actual, expected);
        QVERIFY(!errorDescription(actual).contains("synthetic"));
    }
}

QJsonObject object(const QByteArray &json) { return QJsonDocument::fromJson(json).object(); }
const QDateTime instant = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);
const QStringList requiredMethods{"initialize", "initialized", "account/rateLimits/read"};
}

class QuotaTests : public QObject {
    Q_OBJECT
private slots:
    /// 多桶结果以 codex 为准，窗口类型来自实际分钟数。
    void testMultiBucketCodexOverridesLegacyAndKeepsWindowDurations() {
        auto value = AccountUsageProtocol::decodeResult(object(R"({
          "accountId":"synthetic-account",
          "rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},
          "rateLimitsByLimitId":{"other":{"primary":{"usedPercent":80,"windowDurationMins":300}},
          "codex":{"limitId":"codex","primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1800000100},
                   "secondary":{"usedPercent":61,"windowDurationMins":10080}}}
        })"), instant);
        QCOMPARE(value.origin, QuotaOrigin::Account);
        QCOMPARE(value.observedAt, instant);
        QVERIFY(value.fiveHour() && value.weekly());
        QCOMPARE(value.fiveHour()->usedPercent, 12.5);
        QCOMPARE(value.fiveHour()->remainingPercent(), 88);
        QCOMPARE(value.fiveHour()->resetsAt, instant.addSecs(100));
        QCOMPARE(value.weekly()->remainingPercent(), 39);
        QVERIFY(!value.weekly()->resetsAt);
    }
    /// 明确缺少 codex 桶及无有效额度的响应不得伪造零余额。
    void testMissingCodexBucketAndNullQuotaAreUnavailableNotZero() {
        const QList<QByteArray> values{
            R"({"rateLimitsByLimitId":{},"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300}}})",
            R"({"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":1,"windowDurationMins":300}}}})",
            R"({"rateLimits":{"limitId":"other","primary":{"usedPercent":1,"windowDurationMins":300}}})",
            R"({"rateLimits":{"primary":null,"secondary":null}})",
            R"({"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":300}}})"
        };
        for (const auto &value : values)
            expectError(AccountUsageClientError::Unavailable, [&]{ AccountUsageProtocol::decodeResult(object(value), instant); });
    }
    /// 超额、未知周期、无效重置和布尔值逐窗处理。
    void testLegacyUnknownDurationOverageAndInvalidWindowDoNotInventFiveHours() {
        auto value = AccountUsageProtocol::decodeResult(object(R"({"rateLimitsByLimitId":null,"rateLimits":{
          "primary":{"usedPercent":105,"windowDurationMins":15,"resetsAt":-1},
          "secondary":{"usedPercent":true,"windowDurationMins":300}}})"), instant);
        QCOMPARE(value.windows.size(), 1);
        QCOMPARE(value.windows[0].minutes, 15);
        QCOMPARE(value.windows[0].remainingPercent(), 0);
        QVERIFY(!value.windows[0].resetsAt && !value.fiveHour() && !value.weekly());
        QCOMPARE((QuotaSnapshot{instant,{}}).origin, QuotaOrigin::Log);
    }
    /// 真正通过子进程交换三帧，仅从传入的工作目录取响应。
    void testProtocolHandshakeDirectoryIsolationAndProcessReaping() {
        Fixture fixture("unrelated");
        QVERIFY(fixture.ready);
        AccountUsageClient client(fixture.dir.path(), fixture.executable());
        const auto result = client.snapshot();
        QCOMPARE(result.origin, QuotaOrigin::Account);
        QVERIFY(result.fiveHour());
        QCOMPARE(result.fiveHour()->remainingPercent(), 75);
        QCOMPARE(fixture.methods(), requiredMethods);
        QCOMPARE(QString::fromUtf8(readFile(fixture.dir.filePath("root"))), fixture.dir.path());
        QVERIFY(fixture.reaped());
    }
    /// Swift 的同步管道写入会拒绝已经关闭 stdin 的服务器，即使它提前发了看似有效的余额。
    void testClosedServerInputCannotAcknowledgeUnsentQuotaRequest() {
        Fixture fixture("closed-input");
        QVERIFY(fixture.ready);
        AccountUsageClient client(fixture.dir.path(), fixture.executable(), 2);
        expectError(AccountUsageClientError::Unavailable, [&]{ client.snapshot(); });
        QCOMPARE(fixture.methods(), QStringList{"initialize"});
        QVERIFY(fixture.reaped());
    }
    /// 八个并发刷新只建一次连接，手动五秒、自动六十秒边界以单调时钟判定。
    void testConcurrentRequestsAndAutomaticManualCooldowns() {
        Fixture fixture;
        QVERIFY(fixture.ready);
        std::atomic<int> clock{0};
        AccountUsageClient client(fixture.dir.path(), fixture.executable(), 2, [&]{ return clock.load(); });
        std::array<std::future<QuotaSnapshot>,8> results;
        for (auto &job : results) job = std::async(std::launch::async, [&]{ return client.snapshot(true); });
        for (auto &job : results) {
            const auto window = job.get().fiveHour();
            QVERIFY(window);
            QCOMPARE(window->remainingPercent(), 75);
        }
        QCOMPARE(fixture.attempts(), 1);
        clock += 4;
        client.snapshot(true);
        QCOMPARE(fixture.attempts(), 1);
        clock += 1;
        client.snapshot(true);
        QCOMPARE(fixture.attempts(), 2);
        clock += 59;
        client.snapshot();
        QCOMPARE(fixture.attempts(), 2);
        clock += 1;
        client.snapshot();
        QCOMPARE(fixture.attempts(), 3);
    }
    /// 含敏感占位文本的失败被脱敏，两次刷新只启动一次服务端。
    void testBackendFailureIsRedactedAndRateLimited() {
        Fixture fixture;
        QVERIFY(fixture.ready && fixture.response(failed));
        AccountUsageClient client(fixture.dir.path(), fixture.executable());
        for (int i=0; i<2; ++i)
            expectError(AccountUsageClientError::Unavailable, [&]{ client.snapshot(true); });
        QCOMPARE(fixture.attempts(), 1);
        QVERIFY(fixture.reaped());
    }
    /// 同目录切换账户后下一次自动查询使用新结果，只包含规定三种方法。
    void testNextAutomaticReadUsesNewAccountWithoutAnyTaskMessages() {
        Fixture fixture;
        QVERIFY(fixture.ready && fixture.response(R"({"id":2,"result":{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":300}}}})"));
        int clock = 0;
        AccountUsageClient client(fixture.dir.path(), fixture.executable(), 2, [&]{ return clock; });
        const auto first = client.snapshot().fiveHour();
        QVERIFY(first);
        QCOMPARE(first->remainingPercent(), 10);
        QVERIFY(fixture.response(R"({"id":2,"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}}}})"));
        clock += 60;
        const auto second = client.snapshot().fiveHour();
        QVERIFY(second);
        QCOMPARE(second->remainingPercent(), 90);
        QCOMPARE(fixture.attempts(), 2);
        QCOMPARE(fixture.methods(), requiredMethods + requiredMethods);
        QVERIFY(fixture.reaped());
    }
    /// 新账户查询失败后限频内不能回退到旧账户的余额。
    void testFailedNewAccountReadDoesNotReturnPreviousAccountSnapshot() {
        Fixture fixture;
        QVERIFY(fixture.ready);
        int clock = 0;
        AccountUsageClient client(fixture.dir.path(), fixture.executable(), 2, [&]{ return clock; });
        client.snapshot();
        QVERIFY(fixture.response(R"({"id":2,"error":{"code":-1,"message":"synthetic-signed-out"}})"));
        clock += 5;
        for (int i=0; i<2; ++i)
            expectError(AccountUsageClientError::Unavailable, [&]{ client.snapshot(true); });
        QCOMPARE(fixture.attempts(), 2);
        QVERIFY(fixture.reaped());
    }
    /// 对不肯优雅退出的合成服务执行超时、强杀并回收。
    void testTimeoutKillsAndReapsServerThatIgnoresTerminate() {
        Fixture fixture("hang");
        QVERIFY(fixture.ready);
        AccountUsageClient client(fixture.dir.path(), fixture.executable(), 1);
        QElapsedTimer elapsed;
        elapsed.start();
        expectError(AccountUsageClientError::TimedOut, [&]{ client.snapshot(); });
        QVERIFY(elapsed.elapsed() < 3000);
        QVERIFY(fixture.reaped());
    }
    /// 调用方取消时，仅在自有 CLI 退出后才收到取消。
    void testCancellationReapsServerBeforeReturning() {
        Fixture fixture("hang");
        QVERIFY(fixture.ready);
        AccountUsageClient client(fixture.dir.path(), fixture.executable());
        std::stop_source stop;
        auto job = std::async(std::launch::async, [&]{ return client.snapshot(false, stop.get_token()); });
        QTRY_VERIFY_WITH_TIMEOUT(!readFile(fixture.dir.filePath("pid")).isEmpty(), 1000);
        QElapsedTimer elapsed;
        elapsed.start();
        stop.request_stop();
        QVERIFY_THROWS_EXCEPTION(AccountUsageCancelled, job.get());
        QVERIFY(elapsed.elapsed() < 2000);
        QVERIFY(fixture.reaped());
    }
};

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    if (app.arguments().mid(1) == QStringList{"app-server", "--stdio"}) return serve();
    QuotaTests tests;
    return QTest::qExec(&tests, argc, argv);
}

#include "test_quota.moc"
