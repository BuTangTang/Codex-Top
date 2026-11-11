#include "claude/claude_code_source.h"
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QTest>
#include <QUuid>
using namespace codextop;

class ClaudeCodeSourceTests : public QObject {
    Q_OBJECT
    QDateTime clock;
    /// 每条记录只推进合成时钟一秒。
    QByteArray line(const QString &kind, QJsonObject extra = {}) {
        clock = clock.addSecs(1);
        extra["type"] = kind;
        extra["timestamp"] = clock.toString(Qt::ISODate);
        return QJsonDocument(extra).toJson(QJsonDocument::Compact);
    }
    /// 合成普通用户消息。
    QByteArray user(const QString &text, QJsonObject extra = {}) {
        extra["message"] = QJsonObject{{"role","user"},{"content",text}};
        return line("user",extra);
    }
    /// 合成工具请求，附带不会出现在副标题里的参数。
    QByteArray toolUse(const QString &id, const QString &name, QJsonObject input = {{"secret","x"}}) {
        QJsonObject part{{"type","tool_use"},{"id",id},{"name",name},{"input",input}};
        return line("assistant",{{"message",QJsonObject{{"role","assistant"},{"stop_reason","tool_use"},{"content",QJsonArray{part}}}}});
    }
    /// 合成指定调用的工具结果。
    QByteArray toolResult(const QString &id) {
        QJsonObject part{{"type","tool_result"},{"tool_use_id",id},{"content","ok"}};
        return line("user",{{"message",QJsonObject{{"role","user"},{"content",QJsonArray{part}}}}});
    }
    /// 合成完整的助手收尾消息。
    QByteArray endTurn() {
        QJsonObject part{{"type","text"},{"text","done"}};
        return line("assistant",{{"message",QJsonObject{{"role","assistant"},{"stop_reason","end_turn"},{"content",QJsonArray{part}}}}});
    }
    /// 按文件顺序执行归约。
    static ClaudeTranscriptReducer reduce(const QList<QByteArray> &records) {
        ClaudeTranscriptReducer reducer;
        for (const auto &record : records) reducer.consume(record);
        return reducer;
    }
    /// 生成直接项目层内的路径，并保持各个场景使用独立临时根。
    static QString logPath(const QTemporaryDir &dir, const QString &id, const QString &project = "-work-app") {
        const auto path = dir.filePath("projects/" + project);
        if (!QDir().mkpath(path)) qFatal("无法建立合成项目目录");
        return QDir(path).filePath(id + ".jsonl");
    }
    /// 改动文件修改时刻，控制三十天发现范围与文件遍历顺序。
    static void modified(const QString &path, const QDateTime &at) {
        QFile file(path);
        QVERIFY(file.open(QIODevice::ReadWrite));
        QVERIFY(file.setFileTime(at,QFileDevice::FileModificationTime));
    }
    /// 在合成目录写入或追加整行，文件时刻与测试时钟同步。
    void write(const QString &path, const QList<QByteArray> &records, bool append = false) {
        QFile file(path);
        QVERIFY(file.open(QIODevice::WriteOnly | (append ? QIODevice::Append : QIODevice::Truncate)));
        for (const auto &record : records) {
            QCOMPARE(file.write(record),record.size());
            QCOMPARE(file.write("\n"),1);
        }
        file.close();
        modified(path,clock);
    }
    /// 创建进程登记及邻近的非 JSON 文件，检验只取 .json 后缀。
    static void registry(const QTemporaryDir &dir, const QList<QJsonObject> &entries) {
        const auto path = dir.filePath("sessions");
        QVERIFY(QDir().mkpath(path));
        for (int i=0; i<entries.size(); ++i) {
            QFile file(QDir(path).filePath(QString::number(i+100) + ".json"));
            QVERIFY(file.open(QIODevice::WriteOnly));
            const auto json = QJsonDocument(entries[i]).toJson(QJsonDocument::Compact);
            QCOMPARE(file.write(json),json.size());
        }
        QFile other(QDir(path).filePath("100.secret.key"));
        QVERIFY(other.open(QIODevice::WriteOnly));
        QCOMPARE(other.write("not json"),8);
    }
    /// 准备带入口与可选桌面编号的登记数据。
    static QJsonObject entry(const QString &id, int pid, const QString &entrypoint="claude-desktop-3p",
                             const QString &host={}, const QString &name={}) {
        QJsonObject row{{"sessionId",id},{"pid",pid},{"procStart","Sun Nov  8 04:09:48 2026"},{"entrypoint",entrypoint},{"status","busy"}};
        if (!host.isNull()) row["hostSessionId"]=host;
        if (!name.isNull()) row["name"]=name;
        return row;
    }
    /// 通过真实登记解析器测试，只有进程存活查询使用合成答案。
    static ClaudeCodeSource source(const QTemporaryDir &dir, const QSet<int> &live) {
        return ClaudeCodeSource(dir.path(),{},[live](const QString &root){
            return ClaudeSessionRegistry::read(root,[&](qint32 pid,const QString &){return live.contains(pid);});
        });
    }
private slots:
    /// 每条用例使用 Swift 相同的固定起始时间。
    void init() { clock=QDateTime::fromSecsSinceEpoch(1800000000,QTimeZone::UTC); }
    /// 启动、工具返回、自然结束依次显示对应状态。
    void testPromptToolsAndCompletion() {
        auto r=reduce({user("fix it",{{"cwd","/work/app"}}),toolUse("t1","Bash")});
        QCOMPARE(r.activity.phase,TaskPhase::Running);
        QVERIFY(r.activity.startedAt);
        QCOMPARE(r.workingDirectory,QString("/work/app"));
        r.consume(toolResult("t1"));
        QCOMPARE(r.activity.phase,TaskPhase::Running);
        r.consume(endTurn());
        QCOMPARE(r.activity.phase,TaskPhase::Completed);
    }
    /// 问题与退出计划分别标记回答和确认。
    void testQuestionAndPlanWaitUntilAnswered() {
        auto r=reduce({user("go"),toolUse("q1","AskUserQuestion")});
        QCOMPARE(r.activity.phase,TaskPhase::Waiting);
        QCOMPARE(r.activity.detail,QStringLiteral("等待你的回答"));
        QVERIFY(r.activity.waitingStartedAt);
        r.consume(toolResult("q1"));
        QCOMPARE(r.activity.phase,TaskPhase::Running);
        r.consume(toolUse("p1","ExitPlanMode"));
        QCOMPARE(r.activity.detail,QStringLiteral("等待你的确认"));
    }
    /// 收尾提问以下一次正式收尾为准，不把上一轮问题带到下一轮。
    void testDesktopClosingQuestionWaitsForConfirmation() {
        const auto wrap=[&](const QJsonObject &input){return toolUse("w"+QString::number(input.size()),"mcp__ccd_turn__wrap_up",input);};
        auto r=reduce({user("go"),wrap({{"recap","done"},{"ask",QStringLiteral("装吗？")},{"blocked",true}}),toolResult("w3"),endTurn()});
        QCOMPARE(r.activity.phase,TaskPhase::Waiting);
        QCOMPARE(r.activity.detail,QStringLiteral("等待你确认"));
        QVERIFY(r.activity.waitingStartedAt);
        r.consume(user(QStringLiteral("装")));
        QCOMPARE(r.activity.phase,TaskPhase::Running);
        r.consume(endTurn());
        QCOMPARE(r.activity.phase,TaskPhase::Completed);
        QCOMPARE(reduce({user("go"),wrap({{"recap","done"}}),toolResult("w1"),endTurn()}).activity.phase,TaskPhase::Completed);
        QCOMPARE(reduce({user("go"),wrap({{"recap","done"},{"ask","  "}}),toolResult("w2"),endTurn()}).activity.phase,TaskPhase::Completed);
        QCOMPARE(reduce({user("go"),wrap({{"recap","done"},{"ask",QStringLiteral("提交吗？")}}),toolResult("w2"),
                         wrap({{"recap","done"}}),toolResult("w1"),endTurn()}).activity.phase,TaskPhase::Completed);
    }
    /// 中断和接口错误分别结束为已停止和失败，子代理及非正式元信息不重开轮次。
    void testInterruptErrorAndIgnoredLines() {
        QCOMPARE(reduce({user("go"),user("[Request interrupted by user for tool use]")}).activity.phase,TaskPhase::Stopped);
        auto failed=reduce({user("go"),line("assistant",{{"isApiErrorMessage",true},{"message",QJsonObject{{"role","assistant"},{"content",QJsonArray{}}}}})});
        QCOMPARE(failed.activity.phase,TaskPhase::Failed);
        QVERIFY(failed.activity.detail.contains("Claude Code"));
        auto side=reduce({user("go"),endTurn(),user("sub",{{"isSidechain",true}}),user("meta",{{"isMeta",true}})});
        QCOMPARE(side.activity.phase,TaskPhase::Completed);
        QVERIFY(!side.title());
    }
    /// 合成模型的无需回答消息不表示本轮完成。
    void testSyntheticNoResponseDoesNotComplete() {
        const auto synthetic=line("assistant",{{"message",QJsonObject{{"role","assistant"},{"model","<synthetic>"},{"stop_reason","end_turn"},
                                              {"content",QJsonArray{QJsonObject{{"type","text"},{"text","No response requested."}}}}}}});
        QCOMPARE(reduce({user("go"),synthetic}).activity.phase,TaskPhase::Running);
    }
    /// 用户自定义标题优先于自动会话名。
    void testTitlesPreferCustomOverSessionName() {
        QCOMPARE(reduce({line("custom-title",{{"customTitle","My name"}}),line("agent-name",{{"agentName","Auto"}})}).title(),QString("My name"));
        QCOMPARE(reduce({line("agent-name",{{"agentName","Auto"}})}).title(),QString("Auto"));
    }
    /// 历史消息迟到不重开已结束轮次。
    void testOlderLinesAreIgnored() {
        auto r=reduce({user("go"),endTurn()});
        clock=clock.addSecs(-100);
        r.consume(user("late"));
        QCOMPARE(r.activity.phase,TaskPhase::Completed);
    }
    /// 未安装或目录缺失时快照为空，无全局警告。
    void testMissingDirectoryIsEmptyNotAnError() {
        QTemporaryDir dir;
        ClaudeCodeSource s(dir.filePath("absent"));
        QVERIFY(!s.installed());
        auto snap=s.snapshot();
        QVERIFY(snap.tasks.isEmpty() && !snap.warning);
    }
    /// 查到标题、目录和来源，下一轮不重读，追加后只处理新增事件。
    void testSnapshotListsSessionsAndReadsIncrementally() {
        QTemporaryDir dir;
        auto path=logPath(dir,"abc");
        write(path,{line("custom-title",{{"customTitle","Fix login"}}),user("go",{{"cwd","/work/app"}})});
        ClaudeCodeSource s(dir.path());
        QVERIFY(s.installed());
        auto snap=s.snapshot({},clock);
        QCOMPARE(snap.tasks.size(),1);
        auto task=snap.tasks.first();
        QCOMPARE(task.id,QString("cc:abc"));
        QCOMPARE(task.origin,TaskOrigin::ClaudeCode);
        QCOMPARE(task.title,QString("Fix login"));
        QCOMPARE(task.project,QString("app"));
        QCOMPARE(task.activity.phase,TaskPhase::Running);
        QVERIFY(!task.deepLink());
        QCOMPARE(s.snapshot({},clock).bytesRead,0);
        write(path,{endTurn()},true);
        snap=s.snapshot({},clock);
        QCOMPARE(snap.tasks.value(0).activity.phase,TaskPhase::Completed);
        QVERIFY(snap.bytesRead<400);
    }
    /// 同编号不同来源文件保有独立状态和增量游标，以明确的最新活动选任务。
    void testDuplicateSessionFilesKeepIndependentIncrementalState() {
        QTemporaryDir dir;
        auto shortPath=logPath(dir,"shared"), longPath=logPath(dir,"shared","-work-other");
        const QList<QByteArray> shortLines{user("short"),toolUse("short-question","AskUserQuestion")};
        const QList<QByteArray> longLines{line("file-history-snapshot",{{"padding",QString(2048,'x')}}),endTurn()};
        write(shortPath,shortLines);
        write(longPath,longLines);
        modified(shortPath,clock.addSecs(1));
        auto expected=reduce(longLines).activity;
        ClaudeCodeSource s(dir.path());
        auto first=s.snapshot({},clock);
        QCOMPARE(first.tasks.size(),1);
        QCOMPARE(first.tasks.first().id,QString("cc:shared"));
        QCOMPARE(first.tasks.first().activity,expected);
        QCOMPARE(QFileInfo(first.tasks.first().rolloutPath).dir().dirName(),QString("-work-other"));
        auto second=s.snapshot({},clock);
        QCOMPARE(second.bytesRead,0);
        QCOMPARE(second.tasks.size(),1);
        QCOMPARE(second.tasks.first().id,QString("cc:shared"));
        QCOMPARE(second.tasks.first().activity,expected);
    }
    /// 超过 900 秒的运行显示 Claude 自己的过期提示。
    void testRunningGoesUnknownWhenStaleWithClaudeWording() {
        QTemporaryDir dir;
        write(logPath(dir,"s1"),{user("go")});
        auto task=ClaudeCodeSource(dir.path()).snapshot({},clock.addSecs(901)).tasks.value(0);
        QCOMPARE(task.activity.phase,TaskPhase::Unknown);
        QCOMPARE(task.activity.detail,QStringLiteral("较久未收到新活动，请回到 Claude Code 查看"));
    }
    /// 空行、CRLF、分次写入但未换行的结束消息都保持游标语义。
    void testIncrementalLinesKeepUnfinishedTailUntilNewline() {
        QTemporaryDir dir;
        auto path=logPath(dir,"partial");
        write(path,{user("go")});
        ClaudeCodeSource s(dir.path());
        QCOMPARE(s.snapshot({},clock).tasks.value(0).activity.phase,TaskPhase::Running);
        const auto complete=endTurn();
        const auto half=complete.size()/2;
        QFile writer(path);
        QVERIFY(writer.open(QIODevice::WriteOnly|QIODevice::Append));
        auto push=[&](const QByteArray &data){QCOMPARE(writer.write(data),data.size()); QVERIFY(writer.flush());};
        push("\n\r\n"+complete.left(half));
        QCOMPARE(s.snapshot({"cc:partial"},clock).tasks.value(0).activity.phase,TaskPhase::Running);
        push(complete.mid(half));
        QCOMPARE(s.snapshot({"cc:partial"},clock).tasks.value(0).activity.phase,TaskPhase::Running);
        push("\r\n\n");
        QCOMPARE(s.snapshot({"cc:partial"},clock).tasks.value(0).activity.phase,TaskPhase::Completed);
        QCOMPARE(s.snapshot({"cc:partial"},clock).bytesRead,0);
    }
    /// 40 天前的文件默认跳过，直接关注后仍列出未命名会话。
    void testUnnamedSessionAndOldSessionsSkippedUnlessKept() {
        QTemporaryDir dir;
        auto path=logPath(dir,"old");
        write(path,{user("go")});
        modified(path,QDateTime::currentDateTimeUtc().addDays(-40));
        ClaudeCodeSource s(dir.path());
        QVERIFY(s.snapshot().tasks.isEmpty());
        QCOMPARE(s.snapshot({"cc:old"}).tasks.value(0).title,QStringLiteral("未命名会话"));
    }
    /// 登记存在时把已退出的活动会话改为停止，已结束和真正存活的会话保持原状态。
    void testExitedProcessStopsRunningAndWaitingSessions() {
        QTemporaryDir dir;
        write(logPath(dir,"run"),{user("go")});
        write(logPath(dir,"ask"),{user("go"),toolUse("q1","AskUserQuestion")});
        write(logPath(dir,"live"),{user("go")});
        write(logPath(dir,"done"),{user("go"),endTurn()});
        registry(dir,{entry("run",11),entry("live",12)});
        const auto tasks=source(dir,{12}).snapshot({},clock).tasks;
        QHash<QString,TaskActivity> states;
        for(const auto &t:tasks) states.insert(t.id,t.activity);
        QCOMPARE(states.value("cc:run").phase,TaskPhase::Stopped);
        QCOMPARE(states.value("cc:run").detail,QStringLiteral("会话已退出"));
        QCOMPARE(states.value("cc:ask").phase,TaskPhase::Stopped);
        QCOMPARE(states.value("cc:live").phase,TaskPhase::Running);
        QCOMPARE(states.value("cc:done").phase,TaskPhase::Completed);
    }
    /// 进程仍在的旧会话参与枚举，桌面入口可定位，终端入口不捏造链接。
    void testRegistryNameDeepLinkAndOldLiveSessions() {
        QTemporaryDir dir;
        const auto host="local_"+QUuid::createUuid().toString(QUuid::WithoutBraces);
        auto old=logPath(dir,"desk");
        write(old,{user("go")});
        modified(old,QDateTime::currentDateTimeUtc().addDays(-40));
        write(logPath(dir,"term"),{user("go")});
        registry(dir,{entry("desk",21,"claude-desktop-3p",host,QStringLiteral("登记名")),entry("term",22,"cli")});
        QHash<QString,CodexTask> tasks;
        for(const auto &t:source(dir,{21,22}).snapshot({},clock).tasks) tasks.insert(t.id,t);
        QVERIFY(tasks.contains("cc:desk") && tasks.contains("cc:term"));
        const auto desk=tasks.value("cc:desk"), term=tasks.value("cc:term");
        QCOMPARE(desk.title,QStringLiteral("登记名"));
        QVERIFY(desk.deepLink());
        QCOMPARE(desk.deepLink()->toString(),"claude://claude.ai/epitaxy/"+host);
        QCOMPARE(desk.claudeSessionID(),QString("desk"));
        QVERIFY(!term.deepLink());
        QVERIFY(term.claudeLaunch && !term.claudeLaunch->fromDesktopApp);
    }
    /// 登记解析拒绝坏格式，同编号优先存活进程；目录缺失时保持无法判断。
    void testRegistryReadSkipsBrokenFilesAndPrefersLiveDuplicate() {
        QTemporaryDir dir;
        registry(dir,{entry("same",31),entry("same",32),QJsonObject{{"sessionId","bad"}}});
        auto result=ClaudeSessionRegistry::read(dir.path(),[](int pid,const QString &){return pid==32;});
        QVERIFY(result.entries);
        QCOMPARE(result.entries->size(),1);
        QCOMPARE(result.entries->value("same").pid,32);
        QVERIFY(!ClaudeSessionRegistry::read(dir.filePath("absent")).entries);
        QVERIFY(!ClaudeSessionRegistry::processMatches(999999,"Sun Nov  8 04:09:48 2026"));
    }
    /// 只规范普通空格，分别比较 UTC 与本地写法，拒绝错秒与非法样式。
    void testProcessStartAcceptsUTCAndLocalWriting() {
        const auto at=QDateTime::fromSecsSinceEpoch(1794187866,QTimeZone::UTC);
        const QTimeZone eastern("America/New_York");
        QVERIFY(ClaudeSessionRegistry::startMatches(at,"Mon Nov  9 01:31:06 2026",eastern));
        QVERIFY(ClaudeSessionRegistry::startMatches(at,"Sun Nov  8 20:31:06 2026",eastern));
        QVERIFY(ClaudeSessionRegistry::startMatches(at,"  Sun   Nov   8  20:31:06   2026  ",eastern));
        QVERIFY(!ClaudeSessionRegistry::startMatches(at,"Mon Nov  9 01:31:07 2026",eastern));
        for(const QString &bad:QStringList{"","not a date","Xxx Nov 9 01:31:06 2026","Mon\tNov\t9\t01:31:06\t2026"})
            QVERIFY(!ClaudeSessionRegistry::startMatches(at,bad,eastern));
    }
    /// 固定样例覆盖午夜、闰日、夏令时前后、半小时和四十五分钟偏移。
    void testProcessStartFormattingKeepsLayoutAndCurrentTimeZone() {
        struct Case { const char *stamp,*zone,*expected; };
        const QList<Case> cases{
            {"1970-01-01T00:00:00Z","UTC","Thu Jan 1 00:00:00 1970"},
            {"2000-02-29T12:03:04Z","UTC","Tue Feb 29 12:03:04 2000"},
            {"2026-03-08T06:59:59Z","America/New_York","Sun Mar 8 01:59:59 2026"},
            {"2026-03-08T07:00:00Z","America/New_York","Sun Mar 8 03:00:00 2026"},
            {"2026-11-01T05:59:59Z","America/New_York","Sun Nov 1 01:59:59 2026"},
            {"2026-11-01T06:00:00Z","America/New_York","Sun Nov 1 01:00:00 2026"},
            {"2026-03-29T00:59:59Z","Europe/Berlin","Sun Mar 29 01:59:59 2026"},
            {"2026-03-29T01:00:00Z","Europe/Berlin","Sun Mar 29 03:00:00 2026"},
            {"2026-11-09T01:31:06Z","Asia/Shanghai","Mon Nov 9 09:31:06 2026"},
            {"2026-11-09T01:31:06Z","Asia/Kathmandu","Mon Nov 9 07:16:06 2026"},
            {"2026-11-09T01:31:06Z","Australia/Lord_Howe","Mon Nov 9 12:31:06 2026"},
            {"2026-11-09T01:31:06Z","America/New_York","Sun Nov 8 20:31:06 2026"},
            {"2026-11-09T01:31:06Z","UTC","Mon Nov 9 01:31:06 2026"},
            {"2038-01-19T03:14:08Z","UTC","Tue Jan 19 03:14:08 2038"},
        };
        for(const auto &sample:cases) {
            auto started=parseTimestamp(QString::fromLatin1(sample.stamp));
            const QTimeZone zone(sample.zone);
            QVERIFY(started && zone.isValid());
            QCOMPARE(ClaudeSessionRegistry::processStartText(*started,zone),QString::fromLatin1(sample.expected));
            QVERIFY(ClaudeSessionRegistry::startMatches(*started,QString::fromLatin1(sample.expected),zone));
        }
    }
    /// 冷读需要越过尾部 200 KiB 的合成附件才能找出对话。
    void testColdReadReachesPastLargeTrailingLines() {
        QTemporaryDir dir;
        write(logPath(dir,"big"),{user("go"),endTurn(),line("attachment",{{"attachment",QString(200000,'x')}})});
        auto tasks=ClaudeCodeSource(dir.path()).snapshot({},clock).tasks;
        QCOMPARE(tasks.size(),1);
        QCOMPARE(tasks.first().activity.phase,TaskPhase::Completed);
    }
};
QTEST_GUILESS_MAIN(ClaudeCodeSourceTests)
#include "test_claude_code_source.moc"
