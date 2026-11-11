#include "desktop_reply_receipt_source.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QThread>
#include <QUuid>
#include <QtEndian>
#include <algorithm>
#include <cmath>
#include <limits>

#ifdef Q_OS_WIN
#include <qt_windows.h>
#else
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#endif

namespace codextop {
namespace {

enum class ReadError { Unavailable, Invalid, TimedOut, Cancelled };

void check(QDeadlineTimer until, std::stop_token cancellation)
{
    if (cancellation.stop_requested())
        throw ReadError::Cancelled;
    if (until.hasExpired())
        throw ReadError::TimedOut;
}

bool objectsOnly(const QJsonValue &value)
{
    if (!value.isArray())
        return false;
    const auto array = value.toArray();
    return std::all_of(array.begin(), array.end(), [](const QJsonValue &v) { return v.isObject(); });
}

#ifdef Q_OS_WIN
class WinHandle {
public:
    HANDLE value = INVALID_HANDLE_VALUE;
    ~WinHandle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    WinHandle() = default;
    WinHandle(const WinHandle &) = delete;
    WinHandle &operator=(const WinHandle &) = delete;
};

QByteArray processUser(HANDLE process)
{
    WinHandle token;
    if (!OpenProcessToken(process, TOKEN_QUERY, &token.value))
        throw ReadError::Unavailable;
    DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    if (!size || GetLastError() != ERROR_INSUFFICIENT_BUFFER)
        throw ReadError::Unavailable;
    QByteArray data(size, Qt::Uninitialized);
    if (!GetTokenInformation(token.value, TokenUser, data.data(), size, &size))
        throw ReadError::Unavailable;
    return data;
}
#endif

// 传输只接受本地、同用户的现存端点。所有等待都检查调用者的总时限和取消标记。
class LocalTransport {
public:
    LocalTransport() = default;
    LocalTransport(const LocalTransport &) = delete;
    LocalTransport &operator=(const LocalTransport &) = delete;

#ifdef Q_OS_WIN
    void open(const QString &root, const QString &fixturePipe, QDeadlineTimer until, std::stop_token cancellation)
    {
        // 正式桌面进程共享本机命名管道；每份快照还要核对数据库给出的任务记录路径。
        const auto digest = QCryptographicHash::hash(root.toUtf8(), QCryptographicHash::Sha256).toHex();
        const QString expected = QStringLiteral("codextop-receipt-fixture-") + QString::fromLatin1(digest);
        if (root.isEmpty() || (!fixturePipe.isEmpty() && fixturePipe != expected))
            throw ReadError::Unavailable;
        const auto path = (QStringLiteral("\\\\.\\pipe\\") + (fixturePipe.isEmpty() ? QStringLiteral("codex-ipc") : fixturePipe)).toStdWString();
        check(until, cancellation);
        while (true) {
            handle_.value = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                                        SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
            if (handle_.value != INVALID_HANDLE_VALUE) break;
            if (GetLastError() != ERROR_PIPE_BUSY) throw ReadError::Unavailable;
            check(until, cancellation);
            QThread::msleep(1);
        }
        ULONG serverPid = 0;
        if (!GetNamedPipeServerProcessId(handle_.value, &serverPid))
            throw ReadError::Unavailable;
        WinHandle server;
        server.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, serverPid);
        if (!server.value)
            throw ReadError::Unavailable;
        const auto ours = processUser(GetCurrentProcess());
        const auto theirs = processUser(server.value);
        if (!EqualSid(reinterpret_cast<const TOKEN_USER *>(ours.constData())->User.Sid,
                      reinterpret_cast<const TOKEN_USER *>(theirs.constData())->User.Sid))
            throw ReadError::Unavailable;
        DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
        if (!SetNamedPipeHandleState(handle_.value, &mode, nullptr, nullptr))
            throw ReadError::Unavailable;
    }

    qsizetype transfer(char *data, qsizetype size, bool writing, QDeadlineTimer until, std::stop_token cancellation)
    {
        while (true) {
            check(until, cancellation);
            DWORD amount = 0;
            const auto chunk = static_cast<DWORD>(std::min<qsizetype>(size, 65536));
            const BOOL ok = writing ? WriteFile(handle_.value, data, chunk, &amount, nullptr)
                                    : ReadFile(handle_.value, data, chunk, &amount, nullptr);
            if (ok && amount > 0)
                return amount;
            if (!ok && GetLastError() != ERROR_NO_DATA)
                throw ReadError::Unavailable;
            QThread::msleep(1);
        }
    }
private:
    WinHandle handle_;
#else
    ~LocalTransport() { if (fd_ >= 0) ::close(fd_); }
    void open(const QString &root, const QString &, QDeadlineTimer until, std::stop_token cancellation)
    {
        if (root.isEmpty())
            throw ReadError::Unavailable;
        const auto directory = QDir(root).filePath("ipc");
        if (QFileInfo(directory).canonicalFilePath() != directory)
            throw ReadError::Unavailable;
        const auto ipc = QFile::encodeName(directory);
        const auto path = ipc + "/ipc.sock";
        struct stat folder{}, endpoint{};
        if (::lstat(ipc.constData(), &folder) || !S_ISDIR(folder.st_mode) || folder.st_uid != ::getuid()
            || (folder.st_mode & (S_IWGRP | S_IWOTH)) || ::lstat(path.constData(), &endpoint)
            || !S_ISSOCK(endpoint.st_mode) || endpoint.st_uid != ::getuid())
            throw ReadError::Unavailable;
        sockaddr_un address{};
        if (path.size() >= qsizetype(sizeof(address.sun_path)))
            throw ReadError::Unavailable;
        address.sun_family = AF_UNIX;
#ifdef Q_OS_DARWIN
        address.sun_len = sizeof(address);
#endif
        std::memcpy(address.sun_path, path.constData(), path.size());
        fd_ = ::socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd_ < 0 || ::fcntl(fd_, F_SETFD, FD_CLOEXEC) < 0 || ::fcntl(fd_, F_SETFL, O_NONBLOCK) < 0)
            throw ReadError::Unavailable;
#ifdef SO_NOSIGPIPE
        int enabled = 1;
        if (::setsockopt(fd_, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)))
            throw ReadError::Unavailable;
#endif
        check(until, cancellation);
        if (::connect(fd_, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
            if (errno != EINPROGRESS)
                throw ReadError::Unavailable;
            wait(POLLOUT, until, cancellation);
            int error = 0;
            socklen_t length = sizeof(error);
            if (::getsockopt(fd_, SOL_SOCKET, SO_ERROR, &error, &length) || error)
                throw ReadError::Unavailable;
        }
#ifdef Q_OS_LINUX
        struct ucred peer{};
        socklen_t length = sizeof(peer);
        if (::getsockopt(fd_, SOL_SOCKET, SO_PEERCRED, &peer, &length) || peer.uid != ::getuid())
            throw ReadError::Unavailable;
#else
        uid_t user;
        gid_t group;
        if (::getpeereid(fd_, &user, &group) || user != ::getuid())
            throw ReadError::Unavailable;
#endif
    }

    qsizetype transfer(char *data, qsizetype size, bool writing, QDeadlineTimer until, std::stop_token cancellation)
    {
        while (true) {
            wait(writing ? POLLOUT : POLLIN, until, cancellation);
#ifdef MSG_NOSIGNAL
            constexpr int sendFlags = MSG_NOSIGNAL;
#else
            constexpr int sendFlags = 0;
#endif
            const auto n = writing ? ::send(fd_, data, size, sendFlags) : ::read(fd_, data, size);
            if (n > 0) return n;
            if (n == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK))
                throw ReadError::Unavailable;
        }
    }
private:
    int fd_ = -1;
    void wait(short events, QDeadlineTimer until, std::stop_token cancellation)
    {
        while (true) {
            check(until, cancellation);
            pollfd entry{fd_, events, 0};
            const int result = ::poll(&entry, 1, int(std::clamp<qint64>(until.remainingTime(), 1, 10)));
            if (result < 0 && errno == EINTR) continue;
            if (result < 0) throw ReadError::Unavailable;
            if (entry.revents & events) return;
            if (entry.revents & (POLLERR | POLLHUP | POLLNVAL)) throw ReadError::Unavailable;
        }
    }
#endif
};

class ReceiptConnection {
public:
    ReceiptConnection(const DesktopReceiptLimits &limits, std::stop_token cancellation)
        : limits_(limits), cancellation_(cancellation)
    {
        const auto ms = static_cast<qint64>(std::ceil(limits.timeout * 1000));
        deadline_ = QDeadlineTimer(ms, Qt::PreciseTimer);
        readDeadline_ = deadline_ - std::min<qint64>(20, ms / 10);
    }

    ~ReceiptConnection()
    {
        // 使用剩下的同一个时限，取消后也尽力撤销已成功发送的关注。
        for (const auto &thread : followed_) {
            try { follow(thread, false, deadline_, {}); }
            catch (ReadError) { break; }
        }
    }

    QList<QuestionReplyReceipt> read(const QString &root, const QString &pipe,
                                     const QMap<QString,QDateTime> &threads, const QDateTime &now,
                                     const QHash<QString,QString> &rolloutPaths)
    {
        transport_.open(root, pipe, readDeadline_, cancellation_);
        const auto requestID = QUuid::createUuid().toString(QUuid::WithoutBraces);
        send({{"type","request"},{"requestId",requestID},{"sourceClientId","initializing-client"},
              {"version",0},{"method","initialize"},{"params",QJsonObject{{"clientType","codex-top-reply-observer"}}}},
             readDeadline_, cancellation_);
        while (clientID_.isEmpty()) {
            const auto message = receive();
            if (message.value("type") != "response" || message.value("requestId") != requestID)
                continue;
            const auto id = message.value("result").toObject().value("clientId").toString();
            if (message.value("method") != "initialize" || message.value("resultType") != "success"
                || !QuestionReplyReceipt::isUUID(id))
                throw ReadError::Invalid;
            clientID_ = id;
        }
        for (auto it = threads.begin(); it != threads.end(); ++it) {
            follow(it.key(), true, readDeadline_, cancellation_);
            followed_.append(it.key());
        }

        auto remaining = threads;
        QList<QuestionReplyReceipt> result;
        while (!remaining.empty()) {
            QJsonObject message;
            try { message = receive(); }
            catch (ReadError error) {
                if (error == ReadError::TimedOut) break;
                throw;
            }
            const auto params = message.value("params").toObject();
            const auto thread = params.value("conversationId").toString();
            if (message.value("type") != "broadcast" || message.value("method") != "thread-stream-state-changed"
                || params.value("hostId") != "local" || !remaining.contains(thread))
                continue;
            if (message.value("version").toDouble(-1) != 11)
                throw ReadError::Invalid;
            if (message.contains("targetClientIds")) {
                const auto targets = message.value("targetClientIds");
                const auto array = targets.toArray();
                if (!targets.isArray() || !std::all_of(array.begin(), array.end(), [](const auto &v){ return v.isString(); }))
                    throw ReadError::Invalid;
                if (!array.contains(clientID_)) continue;
            }
            if (!params.value("change").isObject())
                throw ReadError::Invalid;
            const auto change = params.value("change").toObject();
            if (change.value("type") != "snapshot") continue;
            const auto state = change.value("conversationState").toObject();
            if (!rolloutPaths.isEmpty()) {
                // 同一用户可能有多份历史，线程号和轮次相同也不能串用回执。
                // 只比较选中库已验证过的记录路径，绝不打开快照传来的文件。
                const auto reported = QDir::fromNativeSeparators(state.value("rolloutPath").toString());
                QString path = reported;
#ifdef Q_OS_WIN
                if (path.startsWith("//?/UNC/", Qt::CaseInsensitive)) path = "//" + path.mid(8);
                else if (path.startsWith("//?/")) path.remove(0, 4);
#endif
                const QString expected = rolloutPaths.value(thread);
                const auto rootPrefix = root.endsWith('/') ? root : root + '/';
                if (path.isEmpty() || !QDir::isAbsolutePath(path) || path.split('/').contains("..")
                    || !expected.startsWith(rootPrefix) || QDir::cleanPath(path) != expected) {
                    remaining.remove(thread);
                    continue;
                }
            }
            auto found = DesktopReceiptProtocol::receipts(state, thread,
                                                         remaining.value(thread), now, limits_, readDeadline_, cancellation_);
            if (!found || result.size() + found->size() > limits_.maximumReceipts)
                throw ReadError::Invalid;
            result.append(*found);
            remaining.remove(thread);
        }
        if (cancellation_.stop_requested())
            throw ReadError::Cancelled;
        std::sort(result.begin(), result.end(), [](const auto &a, const auto &b) {
            if (a.receivedReferenceSeconds() != b.receivedReferenceSeconds())
                return a.receivedReferenceSeconds() < b.receivedReferenceSeconds();
            return std::tie(a.threadID, a.clientID) < std::tie(b.threadID, b.clientID);
        });
        return result;
    }

private:
    const DesktopReceiptLimits &limits_;
    std::stop_token cancellation_;
    LocalTransport transport_;
    QDeadlineTimer deadline_, readDeadline_;
    QString clientID_;
    QStringList followed_;
    int framesRead_ = 0, bytesRead_ = 0;

    void follow(const QString &thread, bool enabled, QDeadlineTimer until, std::stop_token cancellation)
    {
        send({{"type","broadcast"},{"method","thread-stream-following-changed"},{"sourceClientId",clientID_},
              {"version",1},{"params",QJsonObject{{"hostId","local"},{"conversationId",thread},{"following",enabled}}}},
             until, cancellation);
    }

    void send(const QJsonObject &message, QDeadlineTimer until, std::stop_token cancellation)
    {
        const auto body = QJsonDocument(message).toJson(QJsonDocument::Compact);
        if (body.size() > 16384) throw ReadError::Invalid;
        QByteArray frame(4, Qt::Uninitialized);
        qToLittleEndian<quint32>(quint32(body.size()), frame.data());
        frame += body;
        qsizetype offset = 0;
        while (offset < frame.size())
            offset += transport_.transfer(frame.data() + offset, frame.size() - offset, true, until, cancellation);
    }

    QByteArray readExactly(int size)
    {
        if (size > limits_.maximumTotalBytes - bytesRead_)
            throw ReadError::Invalid;
        QByteArray data(size, Qt::Uninitialized);
        qsizetype offset = 0;
        while (offset < size) {
            const auto n = transport_.transfer(data.data() + offset, size - offset, false, readDeadline_, cancellation_);
            offset += n;
            bytesRead_ += int(n);
        }
        return data;
    }

    QJsonObject receive()
    {
        if (framesRead_ >= limits_.maximumFrames) throw ReadError::Invalid;
        const auto header = readExactly(4);
        const auto length = qFromLittleEndian<quint32>(header.constData());
        if (length == 0 || length > quint32(limits_.maximumFrameBytes)
            || length > quint32(limits_.maximumTotalBytes - bytesRead_))
            throw ReadError::Invalid;
        const auto body = readExactly(int(length));
        ++framesRead_;
        check(readDeadline_, cancellation_);
        const auto message = QJsonDocument::fromJson(body);
        if (!message.isObject()) throw ReadError::Invalid;
        check(readDeadline_, cancellation_);
        return message.object();
    }
};
} // namespace

std::optional<QList<QuestionReplyReceipt>> DesktopReceiptProtocol::receipts(
    const QJsonObject &state, const QString &threadID, const QDateTime &askedAt, const QDateTime &now,
    const DesktopReceiptLimits &limits, QDeadlineTimer deadline, std::stop_token cancellation)
{
    const auto expired = [&] { return deadline.hasExpired() || cancellation.stop_requested(); };
    if (expired() || state.value("id") != threadID || state.value("hostId") != "local")
        return std::nullopt;
    QList<QJsonObject> turns;
    const auto history = state.value("turnHistory").toObject();
    if (history.value("kind") == "canonical") {
        const auto data = history.value("history").toObject();
        const auto islands = data.value("islands").toArray();
        const auto entities = data.value("entitiesByKey").toObject();
        if (!data.value("islands").isArray() || !data.value("entitiesByKey").isObject()
            || islands.size() > limits.maximumTurns || entities.size() > limits.maximumTurns)
            return std::nullopt;
        // 只读 canonical 正在引用的实体，不能合并已过期的 turns 镜像。
        for (const auto &island : islands) {
            const auto value = island.toObject().value("entries");
            const auto entries = value.toArray();
            if (expired() || !value.isArray() || entries.size() > limits.maximumTurns)
                return std::nullopt;
            for (const auto &entry : entries) {
                const auto key = entry.toObject().value("value");
                const auto turn = entities.value(key.toString());
                if (!key.isString() || !turn.isObject() || turns.size() >= limits.maximumTurns)
                    return std::nullopt;
                turns.append(turn.toObject());
            }
        }
    } else if (!state.contains("turnHistory") || history.value("kind") == "legacy") {
        const auto array = state.value("turns").toArray();
        if (!state.value("turns").isArray() || array.size() > limits.maximumTurns)
            return std::nullopt;
        for (const auto &turn : array) {
            if (!turn.isObject()) return std::nullopt;
            turns.append(turn.toObject());
        }
    } else {
        return std::nullopt;
    }

    QList<QuestionReplyReceipt> result;
    QSet<QPair<QString,QString>> seen;
    qsizetype count = 0;
    for (const auto &turn : turns) {
        if (expired()) return std::nullopt;
        const auto id = turn.value("turnId").toString();
        if (turn.value("status") != "inProgress" || !QuestionReplyReceipt::isUUID(id)
            || !objectsOnly(turn.value("items")))
            continue;
        const auto items = turn.value("items").toArray();
        count += items.size();
        if (count > limits.maximumItems) return std::nullopt;
        for (const auto &rawItem : items) {
            if (expired()) return std::nullopt;
            const auto item = rawItem.toObject();
            const auto client = item.value("clientUserMessageId").toString();
            const double ms = item.value("restoreMessage").toObject().value("createdAt").toDouble(-1);
            const auto input = item.value("input").toArray();
            if (item.value("type") != "steeringUserMessage" || item.value("status") != "accepted"
                || item.value("targetTurnId") != id || !QuestionReplyReceipt::isUUID(client)
                || !std::isfinite(ms) || ms < 0 || ms < askedAt.toMSecsSinceEpoch() || ms > now.toMSecsSinceEpoch()
                || input.size() != 1 || input.at(0).toObject().value("type") != "text")
                continue;
            auto receipt = QuestionReplyReceipt::parse(input.at(0).toObject().value("text").toString(),
                                                       threadID, id, client, ms);
            if (receipt && !seen.contains({id,client})) {
                seen.insert({id,client});
                result.append(*receipt);
                if (result.size() > limits.maximumReceipts) return std::nullopt;
            }
        }
    }
    if (expired()) return std::nullopt;
    return result;
}

DesktopReplyReceiptSource::DesktopReplyReceiptSource(const QString &root, DesktopReceiptLimits limits)
    : root_(QFileInfo(root).canonicalFilePath()), limits_(limits)
{
    // 首次启动时用户选的目录可能尚不存在，后续查询仍重新核对目录及端点。
    if (root_.isEmpty() && !root.isEmpty())
        root_ = QDir::cleanPath(QFileInfo(root).absoluteFilePath());
}

#ifdef Q_OS_WIN
DesktopReplyReceiptSource::DesktopReplyReceiptSource(const QString &root, DesktopReceiptLimits limits,
                                                       const QString &fixturePipe)
    : DesktopReplyReceiptSource(root, limits)
{
    windowsPipe_ = fixturePipe;
}
#endif

QList<QuestionReplyReceipt> DesktopReplyReceiptSource::receipts(const QHash<QString,QDateTime> &threads,
                                                                const QDateTime &now, std::stop_token cancellation,
                                                                const QHash<QString,QString> &rolloutPaths)
{
    if (!now.isValid() || threads.isEmpty() || cancellation.stop_requested())
        return {};
#ifdef Q_OS_WIN
    if (windowsPipe_.isEmpty() && rolloutPaths.isEmpty()) return {};
#endif
    QStringList keys;
    for (auto it = threads.begin(); it != threads.end(); ++it)
        if ((rolloutPaths.isEmpty() || rolloutPaths.contains(it.key())) && QuestionReplyReceipt::isUUID(it.key()) && it.value().isValid() && it.value() <= now)
            keys.append(it.key());
    keys.sort();
    QMap<QString,QDateTime> selected;
    {
        std::lock_guard lock(rotationMutex_);
        if (keys.isEmpty() || limits_.maximumThreads <= 0) {
            nextThread_ = 0;
            return {};
        }
        const auto count = std::min<qsizetype>(keys.size(), limits_.maximumThreads);
        const auto first = nextThread_ % keys.size();
        for (qsizetype i = 0; i < count; ++i) {
            const auto &key = keys.at((first + i) % keys.size());
            selected.insert(key, threads.value(key));
        }
        nextThread_ = (first + count) % keys.size();
    }
    if (!std::isfinite(limits_.timeout) || limits_.timeout <= 0
        || limits_.timeout >= double(std::numeric_limits<qint64>::max()) / 1000
        || limits_.maximumFrameBytes <= 0 || limits_.maximumTotalBytes < 4 || limits_.maximumFrames <= 0)
        return {};
    try {
        return ReceiptConnection(limits_, cancellation).read(root_, windowsPipe_, selected, now, rolloutPaths);
    } catch (ReadError) {
        return {};
    }
}

} // namespace codextop
