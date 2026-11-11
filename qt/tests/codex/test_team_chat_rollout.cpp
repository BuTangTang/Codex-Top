#include "rollout_test_support.h"
using namespace rolloutFixture;

class TeamChatRolloutTests : public QObject {
    Q_OBJECT
    const QByteArray header = R"({"ordinal":0,"payload":{"teamchat_copy":{"automatic":true}},"type":"session_meta"})";

    /// 使用生成器相同的紧凑首部和字段顺序，使首部探测也在测试范围内。
    static QByteArray lifecycle(const QByteArray &type, std::optional<int> ordinal = {}, const QByteArray &turn = "local") {
        const auto sequence = ordinal ? QByteArray("\"ordinal\":") + QByteArray::number(*ordinal) + ',' : QByteArray();
        return '{' + sequence + "\"type\":\"event_msg\",\"timestamp\":\"2027-01-15T08:00:00Z\",\"payload\":{\"type\":\"" +
               type + "\",\"turn_id\":\"" + turn + "\"}}";
    }
private slots:
    /// 导入和登记事件保持纯副本；未完整的本机行先撤销标记，补齐后立即进入真实生命周期。
    void testImportedRecordsAndBookkeepingDoNotDriveLocalLifecycle() {
        QTemporaryDir dir;
        const auto path = dir.filePath("synthetic.jsonl");
        overwrite(path,lines({header,lifecycle("task_started",1),lifecycle("agent_message",2),lifecycle("task_complete",3),
                             lifecycle("thread_settings_applied"),lifecycle("thread_name_updated")}));
        IncrementalRollout reader;
        reader.refresh(path);
        QCOMPARE(reader.reducer.activity,TaskActivity::teamChatImport());
        QCOMPARE(reader.refresh(path),0);
        append(path,lifecycle("task_started").chopped(1));
        reader.refresh(path);
        QVERIFY(!reader.reducer.activity.isTeamChatImport);
        append(path,"}\n");
        reader.refresh(path);
        QCOMPARE(reader.reducer.activity.phase,TaskPhase::Running);
        QVERIFY(!reader.reducer.activity.isTeamChatImport);
        append(path,lines({lifecycle("request_user_input"),lifecycle("task_complete",4)}));
        reader.refresh(path);
        QCOMPARE(reader.reducer.activity.phase,TaskPhase::Waiting);
        append(path,lines({lifecycle("task_complete"),lifecycle("task_started",5)}));
        reader.refresh(path);
        QCOMPARE(reader.reducer.activity.phase,TaskPhase::Completed);
    }
    /// 本机上下文或有明确起点的编号事件使后续编号行归入本机轮次。
    void testNumberedNativeContinuationCanStartAndComplete() {
        const QByteArray context = R"({"type":"turn_context","ordinal":12,"payload":{"turn_id":"local"}})";
        const auto local = lifecycle("task_started",13);
        auto evidence = local;
        evidence.replace(R"("turn_id":"local")", R"("turn_id":"local","started_at":1800000000)");
        for (const auto &boundary : QList<QList<QByteArray>>{{context,local},{evidence}}) {
            QTemporaryDir dir;
            const auto path = dir.filePath("synthetic.jsonl");
            overwrite(path,lines(QList<QByteArray>{header,lifecycle("task_started",1,"remote")} + boundary));
            IncrementalRollout reader;
            reader.refresh(path);
            QCOMPARE(reader.reducer.activity.phase,TaskPhase::Running);
            QCOMPARE(reader.reducer.activity.turnID,QString("local"));
            append(path,lines({lifecycle("task_complete",14)}));
            reader.refresh(path);
            QCOMPARE(reader.reducer.activity.phase,TaskPhase::Completed);
            QVERIFY(!reader.reducer.activity.isTeamChatImport);
        }
    }
    /// 只有首行真实布尔 true 能标记自动副本，其他字段写法和嵌入的头都不能。
    void testOnlyAutomaticBooleanInFileHeaderMarksImportedEvents() {
        for (const QByteArray &flag : QList<QByteArray>{"false","1","\"true\""}) {
            QTemporaryDir dir;
            const auto path = dir.filePath("synthetic.jsonl");
            auto alternate = header;
            overwrite(path,lines({alternate.replace(":true", ':' + flag),lifecycle("task_started",1)}));
            IncrementalRollout reader;
            reader.refresh(path);
            QCOMPARE(reader.reducer.activity.phase,TaskPhase::Running);
        }
        QTemporaryDir dir;
        const auto path = dir.filePath("synthetic.jsonl");
        overwrite(path,lines({lifecycle("task_started",1),header,lifecycle("task_complete",2)}));
        IncrementalRollout reader;
        reader.refresh(path);
        QCOMPARE(reader.reducer.activity.phase,TaskPhase::Completed);
        for (const auto ordinal : QList<std::optional<int>>{std::nullopt,2}) {
            const auto unknown = dir.filePath(ordinal ? "unknown2.jsonl" : "unknown.jsonl");
            overwrite(unknown,lines({header,lifecycle("future_native_event", ordinal)}));
            reader.refresh(unknown);
            QCOMPARE(reader.reducer.activity.phase,TaskPhase::Unknown);
            QVERIFY(!reader.reducer.activity.isTeamChatImport);
        }
    }
    /// 副本从头有界追读，追平之前不能移走，导入轮次开始也不能给本机活动补时间。
    void testLargeCopyResumesBoundedScanAndIsNeverRetiredBeforeEOF() {
        QList<QByteArray> imports{header};
        for (int i=1; i<=70; ++i) imports.append(lifecycle("task_started",i,"remote"));
        for (const bool hasLocal : {false,true}) {
            auto rows = imports;
            if (hasLocal) rows.insert(20,lifecycle("agent_message"));
            QTemporaryDir dir;
            const auto path = dir.filePath("synthetic.jsonl");
            overwrite(path,lines(rows));
            IncrementalRollout reader(1024,2048);
            QCOMPARE(reader.refresh(path),1024);
            QVERIFY(!reader.isCaughtUp && !reader.reducer.activity.isTeamChatImport);
            while (!reader.isCaughtUp) {
                const auto bytes = reader.refresh(path);
                QVERIFY(bytes > 0 && bytes <= 2048);
            }
            if (hasLocal) {
                QCOMPARE(reader.reducer.activity.phase,TaskPhase::Running);
                QCOMPARE(reader.recoverTiming(path),0);
                QVERIFY(!reader.reducer.activity.startedAt && !reader.reducer.activity.turnID);
            } else QCOMPARE(reader.reducer.activity,TaskActivity::teamChatImport());
        }
    }
};
QTEST_GUILESS_MAIN(TeamChatRolloutTests)
#include "test_team_chat_rollout.moc"
