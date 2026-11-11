#include "claude/claude_code_source.h"
#include "claude/claude_hook_events.h"
#include "claude/claude_hook_installer.h"
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#ifdef Q_OS_WIN
#include <QLibraryInfo>
#include <QProcessEnvironment>
#endif
#include <QProcess>
#include <QTemporaryDir>
#include <QTest>

using namespace codextop;
namespace {
QByteArray fileContents(const QString &path) {
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray{};
}
void write(const QString &path, const QByteArray &data) {
    QFile file(path);
    QVERIFY2(file.open(QIODevice::WriteOnly), qPrintable(file.errorString()));
    QCOMPARE(file.write(data), data.size());
}
QJsonObject notification(const QString &session, const QString &kind) {
    return {{"hook_event_name", "Notification"}, {"notification_type", kind}, {"session_id", session}};
}
QJsonArray configuredNotifications(const QByteArray &data) {
    return QJsonDocument::fromJson(data).object().value("hooks").toObject().value("Notification").toArray();
}
#ifdef Q_OS_WIN
const auto helperFilename = QStringLiteral("codex-top-claude-hook.exe");
#else
const auto helperFilename = QStringLiteral("codex-top-claude-hook");
#endif
struct TemporarySettings {
    QTemporaryDir dir;
    QString settings = dir.filePath("settings.json"), backups = dir.filePath("backups");
    QString helper = "/Users/x/Library/Application Support/Codex Top/bin/" + helperFilename;
};
} // namespace
class ClaudeHookTests : public QObject {
    Q_OBJECT
  private slots:
    void testRecordKeepsOnlyKindAndTime() {
        QTemporaryDir dir;
        const auto events = dir.filePath("events");
        const auto at = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);
        auto input = notification("abc-1", "permission_prompt");
        input.insert("message", "secret");
        input.insert("cwd", "/secret");
        input.insert("transcript_path", "/secret");
        ClaudeHookEvents::record(QJsonDocument(input).toJson(), events, at);
        ClaudeHookEvents::record(QJsonDocument(notification("abc-1", "idle_prompt")).toJson(), events);
        ClaudeHookEvents::record(QJsonDocument(notification("../x", "permission_prompt")).toJson(), events);
        const auto text = fileContents(QDir(events).filePath("abc-1.jsonl"));
        QVERIFY(!text.contains("secret"));
        QCOMPARE(text.trimmed().split('\n').size(), 1);
        QCOMPARE(QDir(events).entryList(QDir::Files), QStringList{"abc-1.jsonl"});
        const auto observed = ClaudeHookEvents::latest(events, "abc-1");
        QVERIFY(observed);
        const ClaudeHookEvent expected{"permission_prompt", at};
        QVERIFY(*observed == expected);
    }
    void testEventNewerThanTranscriptMeansWaiting() {
        const auto last = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);
        const TaskActivity running{TaskPhase::Running, QStringLiteral("正在调用工具"), last};
        const auto waiting = ClaudeHookEvents::apply(ClaudeHookEvent{"permission_prompt", last.addSecs(1)}, running);
        QCOMPARE(waiting.phase, TaskPhase::Waiting);
        QCOMPARE(waiting.detail, QStringLiteral("等待你批准"));
        QVERIFY(ClaudeHookEvents::apply(ClaudeHookEvent{"permission_prompt", last.addSecs(-1)}, running) == running);
        const TaskActivity completed{TaskPhase::Completed, QStringLiteral("本轮执行已结束"), last};
        QVERIFY(ClaudeHookEvents::apply(ClaudeHookEvent{"permission_prompt", last.addSecs(1)}, completed) == completed);
    }
    void testInstallIntoHandwrittenFileKeepsEverythingElse() {
        TemporarySettings sample;
        const QByteArray original = R"json({
  "permissions": {
    "allow": ["Bash(ls)"]
  },

  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "say done" }] }
    ]
  }
}
)json";
        write(sample.settings, original);
        ClaudeHookInstaller::install(sample.settings, sample.helper, sample.backups);
        const auto installed = fileContents(sample.settings);
        QVERIFY(installed.startsWith(original.chopped(16)));
        const auto hooks = QJsonDocument::fromJson(installed).object().value("hooks").toObject();
        QVERIFY(hooks.contains("Stop"));
        QCOMPARE(hooks.value("Notification").toArray().first().toObject().value("matcher").toString(),
                 "permission_prompt|elicitation_dialog");
        QCOMPARE(ClaudeHookInstaller::isInstalled(sample.settings, sample.helper), std::optional{true});
        ClaudeHookInstaller::install(sample.settings, sample.helper, sample.backups);
        QCOMPARE(fileContents(sample.settings), installed);
        ClaudeHookInstaller::remove(sample.settings, sample.helper, sample.backups);
        QCOMPARE(fileContents(sample.settings), original);
        QVERIFY(!QDir(sample.backups).entryList(QDir::Files).isEmpty());
    }
    void testOtherNotificationHooksStayAndOldHelperPathIsReplaced() {
        TemporarySettings sample;
        const auto old = "/Users/old/Library/Application Support/Codex Top/bin/" + helperFilename;
        const QByteArray original = R"json({
  "hooks": {
    "Notification": [
      {
        "hooks": [{ "type": "command", "command": "say hi" }]
      }
    ]
  }
}
)json";
        write(sample.settings, original);
        ClaudeHookInstaller::install(sample.settings, old, sample.backups);
        ClaudeHookInstaller::install(sample.settings, sample.helper, sample.backups);
        QCOMPARE(configuredNotifications(fileContents(sample.settings)).size(), 2);
        QCOMPARE(ClaudeHookInstaller::isInstalled(sample.settings, old), std::optional{false});
        ClaudeHookInstaller::remove(sample.settings, sample.helper, sample.backups);
        QCOMPARE(fileContents(sample.settings), original);
    }
    void testMissingFileIsCreatedAndRemovedAgain() {
        TemporarySettings sample;
        ClaudeHookInstaller::install(sample.settings, sample.helper, sample.backups);
        QCOMPARE(ClaudeHookInstaller::isInstalled(sample.settings, sample.helper), std::optional{true});
        ClaudeHookInstaller::remove(sample.settings, sample.helper, sample.backups);
        QVERIFY(!QFileInfo::exists(sample.settings));
    }
    void testInvalidJSONIsLeftAlone() {
        TemporarySettings sample;
        const QByteArray original = "{ // comment\n  \"a\": 1\n}\n";
        write(sample.settings, original);
        QVERIFY(!ClaudeHookInstaller::isInstalled(sample.settings, sample.helper).has_value());
        QVERIFY_THROWS_EXCEPTION(ClaudeHookInstaller::Failure,
                                 ClaudeHookInstaller::install(sample.settings, sample.helper, sample.backups));
        QCOMPARE(fileContents(sample.settings), original);
    }
    void testSourceShowsWaitingFromHookEvent() {
        QTemporaryDir dir;
        const auto root = dir.filePath("claude"), events = dir.filePath("events"),
                   project = QDir(root).filePath("projects/p");
        QVERIFY(QDir().mkpath(project));
        const auto now = QDateTime::currentDateTimeUtc();
        auto line = [&](QJsonObject value, int offset) {
            value.insert("timestamp", now.addSecs(offset).toString(Qt::ISODate));
            return QJsonDocument(value).toJson(QJsonDocument::Compact) + '\n';
        };
        const QJsonObject tool{{"type", "tool_use"}, {"id", "t1"}, {"name", "Bash"}, {"input", QJsonObject{}}};
        const auto transcript =
            line({{"type", "user"}, {"message", QJsonObject{{"role", "user"}, {"content", "go"}}}}, -5) +
            line({{"type", "assistant"},
                  {"message",
                   QJsonObject{{"role", "assistant"}, {"stop_reason", "tool_use"}, {"content", QJsonArray{tool}}}}},
                 -4);
        write(QDir(project).filePath("s1.jsonl"), transcript);
        ClaudeHookEvents::record(QJsonDocument(notification("s1", "permission_prompt")).toJson(), events,
                                 now.addSecs(-3));
        ClaudeCodeSource source(root, events, [](const QString &) { return ClaudeSessionRegistry{}; });
        const auto snapshot = source.snapshot({}, now);
        QVERIFY(!snapshot.tasks.isEmpty());
        QCOMPARE(snapshot.tasks.first().activity.phase, TaskPhase::Waiting);
        QCOMPARE(snapshot.tasks.first().activity.detail, QStringLiteral("等待你批准"));
    }
    // 实际通过安装器写出的命令启动独立小程序，验证配置、shell、输入、磁盘整条路径。
    void testNotificationHelperRunsFromIsolatedStateDirectory() {
        TemporarySettings sample;
        const auto state = sample.dir.filePath(QStringLiteral("临时 Codex $state's 测试"));
        const auto bin = QDir(state).filePath("bin"), events = QDir(state).filePath("claude-events");
        QVERIFY(QDir().mkpath(bin));
        const auto helper = QDir(bin).filePath(helperFilename);
        const auto executable = QDir(QCoreApplication::applicationDirPath()).filePath(helperFilename);
        QVERIFY2(QFile::copy(executable, helper), qPrintable(executable));
        ClaudeHookInstaller::install(sample.settings, helper, sample.backups);
        const auto hook = configuredNotifications(fileContents(sample.settings))
                              .at(0)
                              .toObject()
                              .value("hooks")
                              .toArray()
                              .at(0)
                              .toObject();
        const auto command = hook.value("command").toString();
        QVERIFY(!command.isEmpty());
        auto run = [&](const QByteArray &input) {
            QProcess process;
#ifdef Q_OS_WIN
            QCOMPARE(hook.value("shell").toString(), "powershell");
            // 单独编译的测试助手从本次测试的 Qt 运行库加载，开发机不用配置全局 PATH。
            auto env = QProcessEnvironment::systemEnvironment();
            env.insert("PATH", QLibraryInfo::path(QLibraryInfo::BinariesPath) + ';' +
                                   QCoreApplication::applicationDirPath() + ';' + env.value("PATH"));
            process.setProcessEnvironment(env);
            process.start("powershell.exe", {"-NoProfile", "-NonInteractive", "-Command", command});
#else
            process.start("/bin/sh", {"-c", command});
#endif
            QVERIFY2(process.waitForStarted(), qPrintable(process.errorString()));
            process.write(input);
            process.closeWriteChannel();
            QVERIFY2(process.waitForFinished(5000), qPrintable(process.errorString()));
            QCOMPARE(process.exitStatus(), QProcess::NormalExit);
            QCOMPARE(process.exitCode(), 0);
        };
        auto input = notification("smoke", "elicitation_dialog");
        input.insert("message", "synthetic private text");
        run(QJsonDocument(input).toJson());
        const auto event = ClaudeHookEvents::latest(events, "smoke");
        QVERIFY2(event, "小程序未写出可读的通知");
        QCOMPARE(event->kind, "elicitation_dialog");
        const auto recorded = QJsonDocument::fromJson(fileContents(QDir(events).filePath("smoke.jsonl"))).object();
        QCOMPARE(recorded.keys(), QStringList({"at", "t"}));
        QVERIFY(QFile::remove(helper));
        run(QJsonDocument(notification("missing", "permission_prompt")).toJson());
        QVERIFY(!ClaudeHookEvents::latest(events, "missing"));
    }
};
QTEST_GUILESS_MAIN(ClaudeHookTests)
#include "test_claude_hook.moc"
