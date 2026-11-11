#include "codex/desktop_reply_receipt_source.h"
#include "codex/local_codex_source.h"

#include <QCryptographicHash>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QTest>
#include <QThread>
#include <QTimeZone>
#include <QUuid>
#include <QtEndian>
#include <cstring>
#include <future>
#include <stdexcept>
#include <thread>

#ifdef Q_OS_WIN
#include <qt_windows.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#endif

using namespace codextop;
namespace {
QByteArray frame(const QJsonObject &object)
{
    const auto body = QJsonDocument(object).toJson(QJsonDocument::Compact);
    QByteArray bytes(4, Qt::Uninitialized);
    qToLittleEndian<quint32>(body.size(), bytes.data());
    return bytes + body;
}

// 仅在独立临时目录和对应该目录的本机管道接收连接，不读任何登录用户数据。
class ReceiptSocketServer {
public:
    ReceiptSocketServer(QHash<QString,QByteArray> replies, bool split = false, bool reject = false, int connections = 1)
#ifdef Q_OS_WIN
        : directory_(QDir::tempPath() + "/codex-receipt-XXXXXX")
#else
        : directory_("/tmp/codex-receipt-XXXXXX")
#endif
        , replies_(std::move(replies)), split_(split), reject_(reject), connections_(connections)
    {
        if (!directory_.isValid()) throw std::runtime_error("temporary receipt directory");
        root = QFileInfo(directory_.path()).canonicalFilePath();
        if (!QDir(root).mkdir("ipc")) throw std::runtime_error("create fixture IPC directory");
#ifdef Q_OS_WIN
        name_ = "codextop-receipt-fixture-" + QString::fromLatin1(
            QCryptographicHash::hash(root.toUtf8(), QCryptographicHash::Sha256).toHex());
        listener_ = makePipe(true);
        if (listener_ == INVALID_HANDLE_VALUE) throw std::runtime_error("create fixture pipe");
        event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!event_) {
            CloseHandle(listener_);
            throw std::runtime_error("create fixture pipe event");
        }
#else
        const auto ipc = QFile::encodeName(root + "/ipc");
        const auto name = ipc + "/ipc.sock";
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
#ifdef Q_OS_DARWIN
        address.sun_len = sizeof(address);
#endif
        if (name.size() >= qsizetype(sizeof(address.sun_path)) || ::chmod(ipc.constData(),0700))
            throw std::runtime_error("unsafe fixture socket directory");
        std::memcpy(address.sun_path,name.constData(),name.size());
        listener_ = ::socket(AF_UNIX,SOCK_STREAM,0);
        if (listener_ < 0) throw std::runtime_error("create fixture socket");
        if (::fcntl(listener_,F_SETFL,O_NONBLOCK) || ::bind(listener_,reinterpret_cast<sockaddr *>(&address),sizeof(address))
            || ::listen(listener_,4)) {
            ::close(listener_);
            throw std::runtime_error("listen on fixture socket");
        }
#endif
    }

    ~ReceiptSocketServer()
    {
        wait();
#ifdef Q_OS_WIN
        CloseHandle(event_);
        CloseHandle(listener_);
#else
        ::close(listener_);
#endif
    }

    void setReply(const QString &id, const QByteArray &reply) { replies_.insert(id, reply); }

    QString root;
    QList<QJsonObject> messages;
    bool timedOut = false;

    std::shared_ptr<DesktopReplyReceiptSource> source(DesktopReceiptLimits limits = {}) const
    {
#ifdef Q_OS_WIN
        return std::make_shared<DesktopReplyReceiptSource>(root,limits,name_);
#else
        return std::make_shared<DesktopReplyReceiptSource>(root,limits);
#endif
    }

    void start() { worker_ = std::thread([this] { serve(); }); }
    void wait() { if (worker_.joinable()) worker_.join(); }

private:
    QTemporaryDir directory_;
    QHash<QString,QByteArray> replies_;
    bool split_, reject_;
    int connections_;
    std::thread worker_;
#ifdef Q_OS_WIN
    using Endpoint = HANDLE;
    Endpoint listener_ = INVALID_HANDLE_VALUE;
    QString name_;
    HANDLE event_ = nullptr;

    Endpoint makePipe(bool first) const {
        const auto path = (QStringLiteral("\\\\.\\pipe\\") + name_).toStdWString();
        const DWORD access = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | (first ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0);
        return CreateNamedPipeW(path.c_str(), access, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_REJECT_REMOTE_CLIENTS,
                                DWORD(connections_), 1024 * 1024, 65536, 0, nullptr);
    }

    // 只由单个服务线程使用，同一时刻只有一次内核 I/O。超时后先回收异步请求再释放栈上的结构。
    bool awaitIO(Endpoint pipe, OVERLAPPED &op, QDeadlineTimer deadline, DWORD &count) {
        if (GetOverlappedResultEx(pipe, &op, &count, DWORD(std::max<qint64>(0, deadline.remainingTime())), FALSE))
            return true;
        if (GetLastError() == WAIT_TIMEOUT) {
            timedOut = true;
            CancelIoEx(pipe, &op);
            GetOverlappedResult(pipe, &op, &count, TRUE);
        }
        return false;
    }
    Endpoint acceptClient(QDeadlineTimer deadline) {
        ResetEvent(event_);
        OVERLAPPED op{};
        op.hEvent = event_;
        if (ConnectNamedPipe(listener_, &op))
            return listener_;
        const DWORD error = GetLastError();
        if (error == ERROR_PIPE_CONNECTED)
            return listener_;
        DWORD count = 0;
        return error == ERROR_IO_PENDING && awaitIO(listener_, op, deadline, count) ? listener_ : INVALID_HANDLE_VALUE;
    }
    qsizetype transfer(Endpoint client, char *buffer, qsizetype n, bool writing, QDeadlineTimer deadline) {
        ResetEvent(event_);
        OVERLAPPED op{};
        op.hEvent = event_;
        DWORD count = 0;
        const auto size = DWORD(std::min<qsizetype>(n, 65536));
        const BOOL ok = writing ? WriteFile(client, buffer, size, &count, &op) : ReadFile(client, buffer, size, &count, &op);
        if (ok || (GetLastError() == ERROR_IO_PENDING && awaitIO(client, op, deadline, count)))
            return count;
        return -1;
    }
#else
    using Endpoint = int;
    Endpoint listener_ = -1;

    Endpoint acceptClient(QDeadlineTimer deadline)
    {
        while (!deadline.hasExpired()) {
            auto fd = ::accept(listener_, nullptr, nullptr);
            if (fd >= 0) {
                ::fcntl(fd,F_SETFL,O_NONBLOCK);
#ifdef SO_NOSIGPIPE
                int one = 1;
                ::setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#endif
                return fd;
            }
            if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) break;
            QThread::msleep(1);
        }
        return -1;
    }

    qsizetype transfer(Endpoint client, char *buffer, qsizetype n, bool writing, QDeadlineTimer)
    {
#ifdef MSG_NOSIGNAL
        constexpr int flags = MSG_NOSIGNAL;
#else
        constexpr int flags = 0;
#endif
        pollfd entry{client, short(writing ? POLLOUT : POLLIN), 0};
        if (::poll(&entry,1,10) <= 0) return 0;
        const auto count = writing ? ::send(client,buffer,n,flags) : ::read(client,buffer,n);
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return 0;
        return count > 0 ? count : -1;
    }
#endif

    void serve()
    {
        QDeadlineTimer deadline(3000, Qt::PreciseTimer);
        for (int i = 0; i < connections_; ++i) {
            auto client = acceptClient(deadline);
#ifdef Q_OS_WIN
            if (client == INVALID_HANDLE_VALUE) { timedOut = true; return; }
            if (i + 1 < connections_) {
                // 像 Unix 的监听队列一样预留后续入口，第二个客户无需等第一个实例重置。
                const auto next = makePipe(false);
                if (next == INVALID_HANDLE_VALUE) { timedOut = true; return; }
                listener_ = next;
            }
#else
            if (client < 0) { timedOut = true; return; }
#endif
            exchange(client, deadline);
#ifdef Q_OS_WIN
            DisconnectNamedPipe(client);
            if (client != listener_) CloseHandle(client);
#else
            ::close(client);
#endif
        }
    }

    void exchange(Endpoint client, QDeadlineTimer deadline)
    {
        QByteArray buffer;
        char bytes[4096];
        while (!deadline.hasExpired()) {
            const auto n = transfer(client,bytes,sizeof(bytes),false,deadline);
            if (n < 0) return;
            if (!n) { QThread::msleep(1); continue; }
            buffer.append(bytes,n);
            while (buffer.size() >= 4) {
                const auto size = qFromLittleEndian<quint32>(buffer.constData());
                if (size > 65536) return;
                if (buffer.size() < 4 + size) break;
                const auto message = QJsonDocument::fromJson(buffer.mid(4,size)).object();
                buffer.remove(0,4 + size);
                messages.append(message);
                QByteArray outgoing;
                if (message.value("method") == "initialize") {
                    outgoing = frame({{"type","response"},{"requestId",message.value("requestId")},{"method","initialize"},
                                     {"resultType",reject_ ? "error" : "success"},
                                     {"result",QJsonObject{{"clientId","00000000-0000-4000-8000-000000000009"}}}});
                } else if (message.value("method") == "thread-stream-following-changed") {
                    const auto params = message.value("params").toObject();
                    if (params.value("following").toBool())
                        outgoing = replies_.value(params.value("conversationId").toString());
                }
                qsizetype offset = 0;
                while (offset < outgoing.size() && !deadline.hasExpired()) {
                    auto amount = outgoing.size() - offset;
                    if (split_) amount = std::min<qsizetype>(3,amount);
                    const auto written = transfer(client,outgoing.data() + offset,amount,true,deadline);
                    if (written < 0) return;
                    if (written == 0) QThread::msleep(1);
                    offset += written;
                }
            }
        }
        timedOut = true;
    }
};
} // namespace

class DesktopReplyReceiptSourceTests : public QObject {
    Q_OBJECT
    const QString thread = "00000000-0000-4000-8000-000000000001";
    const QString turn = "00000000-0000-4000-8000-000000000002";
    const QString reply = "00000000-0000-4000-8000-000000000003";
    const QDateTime started = QDateTime::fromSecsSinceEpoch(1800000000,QTimeZone::UTC);

    QString message() const
    {
        const auto key = QJsonDocument(QJsonArray{"request_user_input_async","call_synthetic",0}).toJson(QJsonDocument::Compact);
        const auto answer = QJsonObject{{"questionItemId",QString::fromUtf8(key)},{"question","合成问题"},{"answer","合成回答"}};
        return "<send_user_message_question_reply>\n"
            + QString::fromUtf8(QJsonDocument(QJsonArray{answer}).toJson(QJsonDocument::Compact))
            + "\n</send_user_message_question_reply>";
    }

    QJsonObject item(const QString &status = "accepted", const QJsonObject &overrides = {}) const
    {
        auto value = QJsonObject{{"type","steeringUserMessage"},{"id","synthetic-local-item"},{"status",status},
            {"targetTurnId",turn},{"clientUserMessageId",reply},
            {"input",QJsonArray{QJsonObject{{"type","text"},{"text",message()},{"text_elements",QJsonArray{}}}}},
            {"restoreMessage",QJsonObject{{"id",reply},{"createdAt",started.addSecs(20).toMSecsSinceEpoch()}}}};
        for (auto it = overrides.begin(); it != overrides.end(); ++it) value.insert(it.key(),it.value());
        return value;
    }

    QJsonObject state(const QJsonArray &items, QString threadID = {}, QString status = "inProgress",
                      bool canonical = true) const
    {
        const QJsonObject t{{"turnId",turn},{"status",status},{"items",items}};
        const auto id = threadID.isEmpty() ? thread : threadID;
        if (!canonical)
            return {{"id",id},{"hostId","local"},{"turns",QJsonArray{t}},{"turnHistory",QJsonObject{{"kind","legacy"}}}};
        const auto island = QJsonObject{{"entries",QJsonArray{QJsonObject{{"value","entity-one"}}}}};
        const auto history = QJsonObject{{"islands",QJsonArray{island}},{"entitiesByKey",QJsonObject{{"entity-one",t}}}};
        return {{"id",id},{"hostId","local"},{"turns",QJsonArray{}},
                {"turnHistory",QJsonObject{{"kind","canonical"},{"history",history}}}};
    }

    QByteArray snapshot(const QJsonObject &value, QJsonValue version = 11, QString envelopeThread = {},
                        QString host = "local") const
    {
        const auto change = QJsonObject{{"type","snapshot"},{"revision",1},{"conversationState",value}};
        const auto params = QJsonObject{{"hostId",host},{"conversationId",envelopeThread.isEmpty() ? thread : envelopeThread},
                                        {"change",change}};
        return frame({{"type","broadcast"},{"method","thread-stream-state-changed"},{"sourceClientId","synthetic-owner"},
                      {"version",version},{"params",params}});
    }

    static DesktopReceiptLimits limits() { DesktopReceiptLimits l; l.timeout = 0.15; return l; }

    QList<QuestionReplyReceipt> query(ReceiptSocketServer &server, DesktopReceiptLimits budget) const
    {
        server.start();
        auto found = server.source(budget)->receipts({{thread,started.addSecs(10)}},started.addSecs(21));
        server.wait();
        return found;
    }

    QByteArray rollout(const QString &type, int seconds, QString kind = "event_msg", QJsonObject payload = {}) const
    {
        payload.insert("type",type);
        return QJsonDocument(QJsonObject{{"timestamp",started.addSecs(seconds).toString(Qt::ISODate)},{"type",kind},
                                         {"payload",payload}}).toJson(QJsonDocument::Compact) + '\n';
    }

    QByteArray ask() const
    {
        return rollout("function_call",10,"response_item",{{"name","request_user_input_async"},{"call_id","call_synthetic"},
            {"arguments",QStringLiteral(R"({"questions":[{"title":"合成问题"}]})")}});
    }

    static void write(const QString &path, const QByteArray &data, QIODevice::OpenMode mode = QIODevice::WriteOnly)
    {
        QFile file(path);
        if (!file.open(mode) || file.write(data) != data.size()) throw std::runtime_error("write fixture");
    }

    static QByteArray bytes(const QString &path)
    {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) throw std::runtime_error("read fixture");
        return file.readAll();
    }

    void database(const QString &path, const QString &log, const QString &ancestor = {}, const QString &ancestorLog = {}) const
    {
        const auto connectionName = QUuid::createUuid().toString(QUuid::WithoutBraces);
        {
            auto db = QSqlDatabase::addDatabase("QSQLITE",connectionName);
            db.setDatabaseName(path);
            if (!db.open()) throw std::runtime_error("open fixture DB");
            QSqlQuery q(db);
            if (!q.exec("CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER)"))
                throw std::runtime_error("create fixture threads");
            const auto insert = [&](const QString &id,const QString &title,const QString &file) {
                q.prepare("INSERT INTO threads VALUES(?,?,'/synthetic',?,1,2,0)");
                q.addBindValue(id); q.addBindValue(title); q.addBindValue(file);
                if (!q.exec()) throw std::runtime_error("insert fixture thread");
            };
            insert(thread,"Synthetic",log);
            if (!ancestor.isEmpty()) {
                insert(ancestor,"Synthetic parent",ancestorLog);
                if (!q.exec("CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT)"))
                    throw std::runtime_error("create fixture edges");
                q.prepare("INSERT INTO thread_spawn_edges VALUES (?,?)");
                q.addBindValue(ancestor); q.addBindValue(thread);
                if (!q.exec()) throw std::runtime_error("insert fixture edge");
            }
        }
        QSqlDatabase::removeDatabase(connectionName);
    }

private slots:
    void testAcceptedCanonicalSnapshotAndReadOnlyActionWhitelist()
    {
        ReceiptSocketServer server({{thread,snapshot(state({item()}))}});
        const auto receipts = query(server,limits());
        const QList<QuestionReplyReceipt> expected{{thread,turn,reply,started.addSecs(20),{{"call_synthetic",{0}}}}};
        QCOMPARE(receipts,expected);
        QStringList methods;
        for (const auto &m : server.messages) methods.append(m.value("method").toString());
        QCOMPARE(methods,QStringList({"initialize","thread-stream-following-changed","thread-stream-following-changed"}));
        QCOMPARE(server.messages.at(1).value("params").toObject().value("following"),QJsonValue(true));
        QCOMPARE(server.messages.at(2).value("params").toObject().value("following"),QJsonValue(false));
        QVERIFY(!server.timedOut);
    }

    void testUnacceptedMismatchedAndNestedItemsAreRejected()
    {
        const auto invalid = [&](QJsonObject overrides) { return item("accepted",overrides); };
        QJsonArray items{item("pending"),item("failed"),item("rejected"),
            invalid({{"targetTurnId","00000000-0000-4000-8000-000000000099"}}),invalid({{"clientUserMessageId","not-a-client-id"}}),
            invalid({{"restoreMessage",QJsonObject{{"createdAt",started.addSecs(9).toMSecsSinceEpoch()}}}}),
            invalid({{"restoreMessage",QJsonObject{{"createdAt",started.addSecs(22).toMSecsSinceEpoch()}}}}),
            invalid({{"restoreMessage",QJsonObject{{"createdAt",true}}}}),
            invalid({{"input",QJsonArray{QJsonObject{{"type","text"},{"text","quoted " + message()}}}}}),
            QJsonObject{{"type","agentMessage"},{"text","synthetic"},{"metadata",QJsonObject{{"items",QJsonArray{item()}}}}}};
        ReceiptSocketServer server({{thread,snapshot(state(items))}});
        QVERIFY(query(server,limits()).isEmpty());
        QCOMPARE(server.messages.size(),3);
    }

    void testCanonicalHistoryExcludesStaleLegacyAndUnreferencedItems()
    {
        auto canonical = state({item("pending")});
        const QJsonObject oldTurn{{"turnId",turn},{"status","inProgress"},{"items",QJsonArray{item()}}};
        canonical["turns"] = QJsonArray{oldTurn};
        auto history = canonical.value("turnHistory").toObject();
        auto data = history.value("history").toObject();
        auto entities = data.value("entitiesByKey").toObject();
        entities["unreferenced"] = oldTurn;
        data["entitiesByKey"] = entities; history["history"] = data; canonical["turnHistory"] = history;
        ReceiptSocketServer server({{thread,snapshot(canonical)}});
        QVERIFY(query(server,limits()).isEmpty());
    }

    void testUnknownProtocolWrongSourceAndTerminalTurnFailClosed()
    {
        const auto valid = state({item()});
        const QString other = "00000000-0000-4000-8000-000000000099";
        const auto wrongRecipient = frame({{"type","broadcast"},{"method","thread-stream-state-changed"},{"version",11},
            {"targetClientIds",QJsonArray{"unrelated-client"}},{"params",QJsonObject{{"hostId","local"},
                {"conversationId",thread},{"change",QJsonObject{{"type","snapshot"},{"conversationState",valid}}}}}});
        for (const auto &data : {snapshot(valid,12),snapshot(valid,true),snapshot(state({item()},other)),
                snapshot(valid,11,{},"remote"),snapshot(valid,11,other),snapshot(state({item()},{},"interrupted")),
                snapshot({{"id",thread},{"hostId","local"},{"turns",QJsonArray{}},{"turnHistory",QJsonObject{{"kind","future"}}}}),
                wrongRecipient}) {
            ReceiptSocketServer server({{thread,data}});
            QVERIFY(query(server,limits()).isEmpty());
            QVERIFY(!server.messages.isEmpty());
            QCOMPARE(server.messages.last().value("method").toString(),"thread-stream-following-changed");
        }
        QVERIFY(!DesktopReceiptProtocol::receipts(valid,thread,started,started.addSecs(21),limits(),QDeadlineTimer(0)));
    }

    void testSplitFramesSucceedAndPartialOversizedInvalidFramesFail()
    {
        const auto accepted = snapshot(state({item()},{},"inProgress",false));
        ReceiptSocketServer split({{thread,accepted}}, true);
        QCOMPARE(query(split,limits()).size(),1);
        auto budget = limits(); budget.maximumFrameBytes = 8192;
        QByteArray oversized(4,Qt::Uninitialized);
        qToLittleEndian<quint32>(budget.maximumFrameBytes + 1,oversized.data());
        for (const auto &data : {accepted.left(2),accepted.left(accepted.size()/2),oversized,QByteArray::fromHex("010000007b")}) {
            ReceiptSocketServer server({{thread,data}});
            QVERIFY(query(server,budget).isEmpty());
            QVERIFY(!server.timedOut);
        }
    }

    void testLargeSnapshotAboveEightMiBPreservesAcceptedReceipt()
    {
        auto large = state({item()});
        large["syntheticIgnoredPayload"] = QString(9*1024*1024,'x');
        const auto data = snapshot(large);
        QVERIFY(data.size() > 8*1024*1024);
        ReceiptSocketServer server({{thread,data}});
        auto found = query(server,{});
        QCOMPARE(found.size(),1);
        const QuestionItems expected{{"call_synthetic",{0}}};
        QCOMPARE(found.first().questionItems,expected);
        QVERIFY(!server.timedOut);
    }

    void testTimeoutHandshakeFailureAndAggregateBudgets()
    {
        const auto harmless = frame({{"type","broadcast"},{"method","synthetic-irrelevant"},{"padding",QString(100,'x')}});
        for (int mode = 0; mode < 4; ++mode) {
            auto budget = limits();
            if (mode == 2) budget.maximumTotalBytes = 512;
            if (mode == 3) budget.maximumFrames = 3;
            QHash<QString,QByteArray> frames;
            if (mode >= 2) frames.insert(thread,harmless.repeated(12));
            ReceiptSocketServer server(frames,false,mode == 1);
            server.start();
            QElapsedTimer began; began.start();
            const auto found = server.source(budget)->receipts({{thread,started}},started.addSecs(21));
            QVERIFY(began.elapsed() < 800);
            server.wait();
            QVERIFY(found.isEmpty());
            QVERIFY(!server.timedOut);
        }
    }

    void testCancellationAndMainActorRemainResponsive()
    {
        ReceiptSocketServer server({});
        server.start();
        auto budget = limits(); budget.timeout = 0.8;
        auto source = server.source(budget);
        std::stop_source cancellation;
        auto pending = std::async(std::launch::async,[&] {
            return source->receipts({{thread,started}},started.addSecs(21),cancellation.get_token());
        });
        QTest::qWait(35);
        QElapsedTimer began; began.start();
        cancellation.request_stop();
        QVERIFY(pending.get().isEmpty());
        QVERIFY(began.elapsed() < 250);
        server.wait();
        QVERIFY(!server.messages.isEmpty());
        QCOMPARE(server.messages.last().value("params").toObject().value("following"),QJsonValue(false));
    }

    void sharedEndpointRequiresTheSameRolloutPath() {
        for (const QString &relative : QStringList{"", "/other/root.jsonl", "/matching.jsonl", "/nested/../matching.jsonl"}) {
            ReceiptSocketServer server({});
            const auto expected = server.root + "/matching.jsonl";
            auto desktop = state({item()});
            if (!relative.isEmpty()) desktop.insert("rolloutPath", QDir::toNativeSeparators(server.root + relative));
            server.setReply(thread, snapshot(desktop));
            server.start();
            const auto found = server.source(limits())->receipts({{thread, started.addSecs(10)}},
                started.addSecs(21), {}, {{thread, expected}});
            server.wait();
            QCOMPARE(found.size(), relative == "/matching.jsonl" ? 1 : 0);
        }
    }

    void testThreadBudgetRotatesAndRejectsCrossRootSocket()
    {
        const QString other = "00000000-0000-4000-8000-000000000004";
        ReceiptSocketServer server({},false,false,2);
        server.start();
        auto budget = limits(); budget.maximumThreads = 1; budget.timeout = 0.06;
        auto source = server.source(budget);
        for (int n = 0; n < 2; ++n)
            source->receipts({{thread,started},{other,started}},started.addSecs(21));
        server.wait();
        QSet<QString> followed;
        for (const auto &m : server.messages) {
            const auto params = m.value("params").toObject();
            if (params.value("following").toBool()) followed.insert(params.value("conversationId").toString());
        }
        QCOMPARE(followed,QSet<QString>({thread,other}));
        const auto alternate = server.root + "/alternate";
        QVERIFY(QDir().mkpath(alternate));
#ifdef Q_OS_WIN
        const auto originalPipe = "codextop-receipt-fixture-" + QString::fromLatin1(
            QCryptographicHash::hash(server.root.toUtf8(),QCryptographicHash::Sha256).toHex());
        DesktopReplyReceiptSource crossRoot(alternate,{},originalPipe);
#else
        QVERIFY(QFile::link(server.root + "/ipc",alternate + "/ipc"));
        DesktopReplyReceiptSource crossRoot(alternate);
#endif
        QElapsedTimer began; began.start();
        QVERIFY(crossRoot.receipts({{thread,started}},started.addSecs(21)).isEmpty());
        // 原对端仍存在、没有应答，若错误连接会等待到 1.5 秒。
        QVERIFY(began.elapsed() < 500);
    }

    void testLocalSourceAcceptedProjectionAndAuthoritativeStopWithoutSourceWrites()
    {
        for (const QString &status : QStringList{"accepted","pending","failed"}) {
            ReceiptSocketServer server({});
            const auto log = server.root + "/rollout.jsonl";
            auto desktop = state({item(status)});
            desktop.insert("rolloutPath",log);
            server.setReply(thread,snapshot(desktop));
            const auto db = server.root + "/state_5.sqlite";
            write(log,rollout("task_started",0,"event_msg",{{"turn_id",turn}}) + ask());
            database(db,log);
            const auto originalDB = bytes(db), originalLog = bytes(log);
            LocalCodexSource source(server.root,{},server.source());
            server.start();
            const auto first = source.snapshot(started.addSecs(21),{thread});
            server.wait();
            QCOMPARE(first.tasks.size(),1);
            const auto activity = first.tasks.first().activity;
            QCOMPARE(activity.phase,status == "accepted" ? TaskPhase::Running : TaskPhase::Waiting);
            if (status == "accepted") QCOMPARE(activity.detail,"已回复，等待继续");
            QCOMPARE(activity.startedAt,std::optional{started});
            QCOMPARE(activity.lastEventAt,std::optional{started.addSecs(10)});
            QCOMPARE(bytes(db),originalDB);
            QCOMPARE(bytes(log),originalLog);
            write(log,rollout("turn_aborted",22,"event_msg",{{"turn_id",turn}}),QIODevice::Append);
            const auto stoppedLog = bytes(log);
            const auto stopped = source.snapshot(started.addSecs(23),{thread});
            QCOMPARE(stopped.tasks.size(),1);
            QCOMPARE(stopped.tasks.first().activity.phase,TaskPhase::Stopped);
            QCOMPARE(bytes(log),stoppedLog);
            QCOMPARE(bytes(db),originalDB);
        }
    }

    void testSelectedAncestorRecoversChildTimingAndProjectsItsReceipt()
    {
        ReceiptSocketServer server({{thread,snapshot(state({item()}))}});
        const QString ancestor = "00000000-0000-4000-8000-000000000004";
        const auto childLog = server.root + "/child.jsonl", rootLog = server.root + "/root.jsonl";
        auto desktop = state({item()});
        desktop.insert("rolloutPath",childLog);
        server.setReply(thread,snapshot(desktop));
        write(childLog,rollout("task_started",0,"event_msg",{{"turn_id",turn}}) + QByteArray(70000,'x') + '\n' + ask());
        write(rootLog,rollout("task_complete",0,"event_msg",{{"turn_id","synthetic-root"}}));
        database(server.root + "/state_5.sqlite",childLog,ancestor,rootLog);
        LocalCodexSource source(server.root,{},server.source());
        const auto cold = source.snapshot(started.addSecs(21));
        const auto findChild = [&](const auto &tasks) {
            return std::find_if(tasks.cbegin(),tasks.cend(),[&](const auto &t){return t.id == thread;});
        };
        const auto waiting = findChild(cold.tasks);
        QVERIFY(waiting != cold.tasks.cend());
        QCOMPARE(waiting->activity.phase,TaskPhase::Waiting);
        QVERIFY(!waiting->activity.startedAt);
        QVERIFY(server.messages.isEmpty());
        server.start();
        const auto selected = source.snapshot(started.addSecs(21),{ancestor});
        server.wait();
        const auto child = findChild(selected.tasks);
        QVERIFY(child != selected.tasks.cend());
        QCOMPARE(child->activity.startedAt,std::optional{started});
        QCOMPARE(child->activity.phase,TaskPhase::Running);
        QCOMPARE(child->activity.detail,"已回复，等待继续");
        QCOMPARE(child->activity.lastEventAt,std::optional{started.addSecs(10)});
        QVERIFY(!server.timedOut);
    }
};

QTEST_GUILESS_MAIN(DesktopReplyReceiptSourceTests)
#include "test_desktop_reply_receipt_source.moc"
