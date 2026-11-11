#include "claude_session_registry.h"
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <filesystem>
#include <limits>
#include <cmath>
#ifdef Q_OS_WIN
#include <qt_windows.h>
#elif defined(Q_OS_MACOS)
#include <sys/sysctl.h>
#endif

namespace codextop {
namespace {
/// 可选字符串保留空串与字段缺失的区别。
std::optional<QString> optionalString(const QJsonValue &value) {
    return value.isString() ? std::optional{value.toString()} : std::nullopt;
}
/// NSNumber.int32Value 截去小数并保留低 32 位；格式不对时拒绝登记。
qint32 registryPID(const QJsonValue &value) {
    if (value.isBool()) return value.toBool() ? 1 : 0;
    if (!value.isDouble()) return 0;
    const auto integer = value.toInteger(std::numeric_limits<qint64>::min());
    if (integer != std::numeric_limits<qint64>::min()) return static_cast<qint32>(integer);
    const double low = std::fmod(std::trunc(value.toDouble()),4294967296.0);
    return static_cast<qint32>(static_cast<qint64>(low));
}
}

ClaudeSessionRegistry ClaudeSessionRegistry::read(const QString &root, const IsAlive &isAlive) {
    const auto directory = QDir(root).filePath("sessions");
    std::error_code error;
    const auto end = std::filesystem::directory_iterator{};
    auto file = std::filesystem::directory_iterator(QFile(directory).filesystemFileName(), error);
    if (error) return {};
    QHash<QString,Entry> entries;
    for (; file != end; file.increment(error)) {
        if (error) return {};
        if (file->path().extension() != ".json") continue;
        QFile input(file->path());
        if (!input.open(QIODevice::ReadOnly)) continue;
        // 先限量读取，拒绝大于原生上限的登记。
        const auto data = input.read(64*1024+1);
        if (data.size() > 64*1024 || input.error() != QFileDevice::NoError) continue;
        const auto row = QJsonDocument::fromJson(data).object();
        const auto id = row["sessionId"].toString();
        const auto pid = registryPID(row["pid"]);
        if (id.isEmpty() || pid <= 0 || !row["procStart"].isString()) continue;
        Entry entry{id,pid,row["procStart"].toString(),optionalString(row["entrypoint"]),
                    optionalString(row["hostSessionId"]),optionalString(row["name"]),false};
        entry.alive = isAlive(pid,entry.processStart);
        const auto old = entries.constFind(id);
        if (old != entries.cend() && old->alive && !entry.alive) continue;
        entries.insert(id,entry);
    }
    return error ? ClaudeSessionRegistry{} : ClaudeSessionRegistry{entries};
}

bool ClaudeSessionRegistry::processMatches(qint32 pid, const QString &processStart) {
    if (pid <= 0) return false;
    QDateTime started;
#ifdef Q_OS_WIN
    HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, DWORD(pid));
    if (!handle) return false;
    FILETIME creation{}, exit{}, kernel{}, user{};
    DWORD status = 0;
    const bool ok = GetExitCodeProcess(handle,&status) && status == STILL_ACTIVE && GetProcessTimes(handle,&creation,&exit,&kernel,&user);
    CloseHandle(handle);
    if (!ok) return false;
    const quint64 ticks = (quint64(creation.dwHighDateTime) << 32) | creation.dwLowDateTime;
    started = QDateTime::fromSecsSinceEpoch(qint64(ticks / 10000000) - 11644473600LL,QTimeZone::UTC);
#elif defined(Q_OS_MACOS)
    int mib[]{CTL_KERN,KERN_PROC,KERN_PROC_PID,int(pid)};
    kinfo_proc info{};
    size_t length = sizeof(info);
    if (sysctl(mib,4,&info,&length,nullptr,0) != 0 || length == 0 || info.kp_proc.p_pid != pid) return false;
    started = QDateTime::fromSecsSinceEpoch(info.kp_proc.p_starttime.tv_sec,QTimeZone::UTC);
#else
    return false;
#endif
    return startMatches(started,processStart);
}

bool ClaudeSessionRegistry::startMatches(const QDateTime &started, const QString &processStart, const QTimeZone &localZone) {
    const auto recorded = processStart.split(' ',Qt::SkipEmptyParts).join(' ');
    return processStartText(started,QTimeZone::UTC) == recorded || processStartText(started,localZone) == recorded;
}

QString ClaudeSessionRegistry::processStartText(const QDateTime &started, const QTimeZone &zone) {
    return QLocale::c().toString(started.toTimeZone(zone),QStringLiteral("ddd MMM d HH:mm:ss yyyy"));
}
}
