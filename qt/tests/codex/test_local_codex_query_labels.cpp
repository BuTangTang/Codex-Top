#include "local_source_fixture.h"

using namespace local_fixture;

namespace {
struct QueryFixture : Fixture {
    const QString log = path("rollout.jsonl");
    QueryFixture() { write(log, local_fixture::event("task_complete")); }
};

QString childOf(const QString &name)
{
    return QString::fromUtf8(QJsonDocument(QJsonObject{{"subagent",QJsonObject{
        {"thread_spawn",QJsonObject{{"parent_thread_id",name}}}}}}).toJson(QJsonDocument::Compact));
}
} // namespace

class LocalCodexQueryLabelTests : public QObject {
    Q_OBJECT
private slots:
    void testTitleCleanupPreservesUnicodeWhitespaceAndTruncation()
    {
        QueryFixture f;
        const QString unnamed = "未命名任务", family = "👨‍👩‍👧‍👦";
        // 直接按 Swift 样例写出每种输入的结果，不用被测的清洗函数计算期望。
        QList<QPair<QString,QString>> cases{{"",unnamed},{"普通标题","普通标题"},{"  中间  空格  ","中间  空格"},
            {"甲\r\n乙","甲  乙"},{family.repeated(301),family.repeated(300)}};
        for (const QString &separator : QStringList{"\n","\r","\r\n","\v","\f","\u0085","\u2028","\u2029"}) {
            const auto longPrefix = QStringLiteral("中").repeated(299);
            const QString gap(separator.size(), ' ');
            cases.append({separator,unnamed});
            cases.append({"甲" + separator + "乙","甲" + gap + "乙"});
            cases.append({separator + "甲" + separator,"甲"});
            cases.append({" " + separator + " 甲 " + separator + " ","甲"});
            cases.append({longPrefix + separator + "乙",longPrefix + " "});
        }
        for (const QString &space : QStringList{" ","\t","\u00A0","\u2009","\u3000","\uFEFF"}) {
            const bool retained = space == QStringLiteral("\uFEFF");
            cases.append({space,retained ? space : unnamed});
            cases.append({space + "正文" + space,retained ? space + "正文" + space : QStringLiteral("正文")});
            cases.append({"甲" + space + "乙","甲" + space + "乙"});
        }
        for (const QString &grapheme : QStringList{"e\u0301","é",family,"🇨🇳","👍🏽","中"}) {
            for (int count : {1,299,300,301,600}) {
                const auto raw = grapheme.repeated(count);
                const auto expected = grapheme.repeated(std::min(300,count));
                cases.append({raw,expected});
                cases.append({" " + raw + "\t",expected});
                cases.append({raw + "\r\n末尾",expected + QStringLiteral("  末尾").left(std::max(0,300-count))});
            }
        }
        for (int i = 0; i < cases.size(); ++i)
            f.add("title-" + QString::number(i),f.log,cases.at(i).first,"/synthetic/project");
        const auto snapshot = LocalCodexSource(f.root).snapshot(now);
        QCOMPARE(snapshot.tasks.size(),cases.size());
        for (int i = 0; i < cases.size(); ++i)
            QCOMPARE(task(snapshot,"title-" + QString::number(i)).title.toUtf8(),cases.at(i).second.toUtf8());
        QCOMPARE(task(snapshot,"title-0").title,unnamed);
        QCOMPARE(task(snapshot,"title-3").title,"甲  乙");
        QCOMPARE(task(snapshot,"title-4").title,family.repeated(300));
    }

    void testSourceObjectDetectionPreservesOriginalJSONSemantics()
    {
        QueryFixture f;
        f.sql("ALTER TABLE threads ADD COLUMN source TEXT");
        const auto object = childOf("parent");
        const QVariantList values{QVariant{},"","cli","vscode","null","false","123","\"source\"","[]","[1]","{}","{",
            "\"{\"","[" + object + "]",object," \t\r\n" + object,QStringLiteral("\uFEFF") + object,
            R"({"subagent":[]})",R"({"subagent":{"thread_spawn":null}})",R"({"subagent":{"thread_spawn":{"parent_thread_id":3}}})",
            childOf("")};
        for (int i = 0; i < values.size(); ++i)
            f.sql("INSERT INTO threads VALUES(?,?,?,?,1,2,0,?)",{"source-" + QString::number(i),"测试","/synthetic/project",f.log,values.at(i)});
        const auto snapshot = LocalCodexSource(f.root).snapshot(now);
        QCOMPARE(snapshot.tasks.size(),values.size());
        for (int i = 0; i < values.size(); ++i) {
            std::optional<QString> expected;
            if (i >= 14 && i <= 16) expected = "parent";
            if (i == 20) expected = "";
            QCOMPARE(task(snapshot,"source-" + QString::number(i)).parentID,expected);
        }
        QCOMPARE(task(snapshot,"source-14").parentID,std::optional<QString>("parent"));
        QCOMPARE(task(snapshot,"source-20").parentID,std::optional<QString>(""));
    }

    void testRepeatedProjectNamesPreservePathSemanticsAcrossSnapshots()
    {
        QueryFixture f;
        // 只写入 cwd 元数据。所有 rollout 的读取都指向临时目录。
        const QVariantList paths{QVariant{},"","/",".","..","relative/project","/synthetic/项目/","/synthetic/a/../b",
            "/synthetic/a%20b","/synthetic/空 格#问?","/synthetic/项目/","/synthetic//重复///","~/project",
            "/synthetic/e\u0301"};
        for (int i = 0; i < paths.size(); ++i)
            f.sql("INSERT INTO threads VALUES(?,?,?,?,1,2,0)",{"project-" + QString::number(i),"测试",paths.at(i),f.log});
        LocalCodexSource source(f.root);
        const auto first = source.snapshot(now);
        const QString here = QDir::current().dirName();
        const QString parent = QDir(QDir::currentPath() + "/..").absolutePath().section('/',-1);
        const QStringList expected{here,here,"/",here,parent,"project","项目","b","a%20b","空 格#问?","项目","重复","project","e\u0301"};
        for (int i = 0; i < paths.size(); ++i)
            QCOMPARE(task(first,"project-" + QString::number(i)).project.toUtf8(),expected.at(i).toUtf8());
        f.sql("UPDATE threads SET cwd=? WHERE id='project-10'",{"/synthetic/已移动"});
        const auto second = source.snapshot(now);
        QCOMPARE(task(second,"project-10").project,"已移动");
        QCOMPARE(task(second,"project-6").project,"项目");
        QCOMPARE(second.bytesRead,0);
    }

    void testAliasesNullColumnsAndMultipleRowsKeepTheirOwnValues()
    {
        QueryFixture f;
        f.sql("ALTER TABLE threads ADD COLUMN name TEXT");
        f.sql("ALTER TABLE threads ADD COLUMN source TEXT");
        const QString insert = "INSERT INTO threads VALUES(?,?,?,?,1,2,0,?,?)";
        f.sql(insert,{"root","原始标题","/synthetic/根项目",f.log,QVariant{},QVariant{}});
        f.sql(insert,{"child","被别名覆盖",QVariant{},f.log,"重命名标题",childOf("root")});
        f.sql(insert,{"empty-name","空名称回退","/synthetic/空名称",f.log,"",QVariant{}});
        f.sql(insert,{"null-title",QVariant{},"/synthetic/标题为空",f.log,QVariant{},QVariant{}});
        f.sql(insert,{QVariant{},"缺少编号","/synthetic/不可见",f.log,QVariant{},QVariant{}});
        f.sql(insert,{"null-path","缺少路径","/synthetic/不可见",QVariant{},QVariant{},QVariant{}});
        const auto db = f.path("state_5.sqlite");
        const auto original = readFile(db);
        const auto snapshot = LocalCodexSource(f.root).snapshot(now);
        QSet<QString> ids;
        for (const auto &t : snapshot.tasks) {
            ids.insert(t.id);
            QCOMPARE(t.activity.phase,TaskPhase::Completed);
        }
        QCOMPARE(ids,QSet<QString>({"root","child","empty-name","null-title"}));
        QCOMPARE(task(snapshot,"root").title,"原始标题");
        QCOMPARE(task(snapshot,"root").project,"根项目");
        QVERIFY(!task(snapshot,"root").parentID);
        QCOMPARE(task(snapshot,"child").title,"重命名标题");
        QCOMPARE(task(snapshot,"child").parentID,std::optional<QString>("root"));
        QCOMPARE(task(snapshot,"empty-name").title,"空名称回退");
        QCOMPARE(task(snapshot,"empty-name").project,"空名称");
        QCOMPARE(task(snapshot,"null-title").title,"未命名任务");
        QCOMPARE(task(snapshot,"null-title").project,"标题为空");
        QVERIFY(!snapshot.warning);
        QCOMPARE(readFile(db),original);
    }

    void testEmptyResultsAndSchemaChangesAreReadAgainOnSameSource()
    {
        QueryFixture f;
        LocalCodexSource source(f.root);
        QVERIFY(source.snapshot(now).tasks.isEmpty());
        f.add("root",f.log,"原始标题","/synthetic/项目");
        const auto original = source.snapshot(now);
        QCOMPARE(task(original,"root").title,"原始标题");
        QVERIFY(!task(original,"root").parentID);
        f.sql("ALTER TABLE threads ADD COLUMN name TEXT");
        f.sql("ALTER TABLE threads ADD COLUMN source TEXT");
        f.sql("UPDATE threads SET name=?,source=?",{"新增名称",childOf("new-parent")});
        const auto extended = source.snapshot(now);
        QCOMPARE(task(extended,"root").title,"新增名称");
        QCOMPARE(task(extended,"root").parentID,std::optional<QString>("new-parent"));

        f.sql("BEGIN");
        f.sql("ALTER TABLE threads RENAME TO old_threads");
        f.sql(schema);
        f.sql("INSERT INTO threads SELECT id,title,cwd,rollout_path,created_at,updated_at,archived FROM old_threads");
        f.sql("DROP TABLE old_threads");
        f.sql("COMMIT");
        const auto restored = source.snapshot(now);
        QCOMPARE(task(restored,"root").title,"原始标题");
        QVERIFY(!task(restored,"root").parentID);
        QCOMPARE(task(restored,"root").activity.phase,TaskPhase::Completed);
        QCOMPARE(restored.bytesRead,0);
    }

    void testLabelChangesAndParentEdgesDoNotRequireTimestampChanges()
    {
        QueryFixture f;
        f.sql("ALTER TABLE threads ADD COLUMN source TEXT");
        f.sql("CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT)");
        f.sql("INSERT INTO threads VALUES(?,?,?,?,1,2,0,?)",{"child","  初始\n标题  ","/synthetic/原项目/",f.log,childOf("original-parent")});
        LocalCodexSource source(f.root);
        const auto first = source.snapshot(now);
        QCOMPARE(task(first,"child").title,"初始 标题");
        QCOMPARE(task(first,"child").parentID,std::optional<QString>("original-parent"));
        const auto warm = source.snapshot(now);
        QCOMPARE(warm.tasks,first.tasks);
        QCOMPARE(warm.bytesRead,0);

        f.sql("UPDATE threads SET title=?,cwd=?",{"  新\r\n标题  ","/synthetic/新项目"});
        const auto renamed = source.snapshot(now);
        QCOMPARE(task(renamed,"child").title,"新  标题");
        QCOMPARE(task(renamed,"child").project,"新项目");
        QCOMPARE(task(renamed,"child").parentID,std::optional<QString>("original-parent"));
        QCOMPARE(task(renamed,"child").updatedAt,task(first,"child").updatedAt);
        f.sql("UPDATE threads SET source=?",{childOf("new-parent")});
        QCOMPARE(task(source.snapshot(now),"child").parentID,std::optional<QString>("new-parent"));
        f.sql("INSERT INTO thread_spawn_edges VALUES('edge-parent','child')");
        QCOMPARE(task(source.snapshot(now),"child").parentID,std::optional<QString>("edge-parent"));
        f.sql("DELETE FROM thread_spawn_edges");
        QCOMPARE(task(source.snapshot(now),"child").parentID,std::optional<QString>("new-parent"));
        f.sql("UPDATE threads SET title=NULL,source=NULL");
        const auto cleared = source.snapshot(now);
        QCOMPARE(task(cleared,"child").title,"未命名任务");
        QVERIFY(!task(cleared,"child").parentID);
        QCOMPARE(cleared.bytesRead,0);
    }

    void testArchivedAndReplacedDatabaseUseCurrentLabels()
    {
        QueryFixture f;
        f.add("root",f.log,"旧标题","/synthetic/旧项目");
        LocalCodexSource source(f.root);
        source.snapshot(now);
        f.sql("UPDATE threads SET archived=1");
        QVERIFY(source.snapshot(now).tasks.isEmpty());
        f.sql("UPDATE threads SET archived=0,title=?",{QStringLiteral("新").repeated(400)});
        QCOMPARE(task(source.snapshot(now),"root").title,QStringLiteral("新").repeated(300));
        f.sql("UPDATE threads SET title='另一数据库'");
        QVERIFY(QFile::copy(f.path("state_5.sqlite"),f.path("state_6.sqlite")));
        f.sql("UPDATE threads SET title='不该读取的旧库'");
        const auto replaced = source.snapshot(now);
        QCOMPARE(task(replaced,"root").title,"另一数据库");
        QCOMPARE(task(replaced,"root").activity.phase,TaskPhase::Completed);
    }
};

QTEST_GUILESS_MAIN(LocalCodexQueryLabelTests)
#include "test_local_codex_query_labels.moc"
