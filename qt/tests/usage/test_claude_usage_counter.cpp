#include "usage/claude_usage_counter.h"
#include "usage_fixture.h"
using namespace codextop;
using namespace usage_fixture;
class ClaudeUsageCounterTests : public QObject {
    Q_OBJECT
    static QByteArray line(const QString &id, const QDateTime &at, int input, int output, int cacheRead = 0,
                           int cacheWrite = 0) {
        const QJsonObject usage{{"input_tokens", input},
                                {"output_tokens", output},
                                {"cache_read_input_tokens", cacheRead},
                                {"cache_creation_input_tokens", cacheWrite}};
        const QJsonArray content{QJsonObject{{"type", "text"}, {"text", "secret"}}};
        const QJsonObject message{{"id", id}, {"role", "assistant"}, {"content", content}, {"usage", usage}};
        return record({{"type", "assistant"}, {"timestamp", at.toString(Qt::ISODate)}, {"message", message}});
    }
    const UsageDayBoundary midnight{QTimeZone::UTC, 0};
  private slots:
    void testCountsDaysSubagentsAndSkipsDuplicates() {
        QTemporaryDir dir;
        QDir project(dir.filePath("projects/p"));
        QVERIFY(project.mkpath("s1/subagents"));
        const auto main = project.filePath("s1.jsonl");
        const auto m1 = line("m1", now, 100, 20, 1000, 50);
        write(main,
              m1 + m1 + m1 + line("m0", now.addSecs(-86400), 10, 5) +
                  "{\"type\":\"user\",\"timestamp\":\"2027-01-15T08:00:00Z\",\"message\":{\"content\":\"usage\"}}\n");
        write(project.filePath("s1/subagents/agent-1.jsonl"), line("a1", now, 30, 10));
        write(project.filePath("s2.jsonl"), line("o1", now, 5, 5));
        ClaudeUsageCounter counter(dir.path());
        auto summary = counter.summary(now, midnight);
        const ClaudeTokens expected{150 + 30 + 5, 20 + 10 + 5, 1000};
        QCOMPARE(summary.today(), expected);
        QCOMPARE(summary.yesterday().total(), 15);
        write(main, line("m1", now, 100, 20) + line("m2", now, 1, 1), now, true);
        summary = counter.summary(now, midnight);
        QCOMPARE(summary.today().total(), 185 + 35 + 1000 + 2);
        QCOMPARE(summary.week(), summary.today().total() + 15);
    }
    void testCopiedRecordsInResumedSessionCountOnce() {
        QTemporaryDir dir;
        QDir project(dir.filePath("projects/p"));
        QVERIFY(project.mkpath("."));
        const auto original = line("m1", now, 100, 10) + line("m2", now, 200, 20);
        write(project.filePath("s1.jsonl"), original);
        write(project.filePath("s2.jsonl"), original + line("m3", now, 5, 1));
        const auto summary = ClaudeUsageCounter(dir.path()).summary(now, midnight);
        const ClaudeTokens expected{305, 31};
        QCOMPARE(summary.today(), expected);
    }
    void testDayStartsAtNoon() {
        auto date = [](const QString &iso) { return QDateTime::fromString(iso, Qt::ISODate); };
        UsageDayBoundary boundary{QTimeZone::UTC, 12};
        const auto noon = date("2027-01-15T12:00:00Z"), nextMorning = date("2027-01-16T01:30:00Z");
        QCOMPARE(boundary.start(date("2027-01-15T12:01:00Z")), noon);
        QCOMPARE(boundary.start(nextMorning), noon);
        QCOMPARE(boundary.start(date("2027-01-15T11:59:00Z")), date("2027-01-14T12:00:00Z"));
        QList<QDateTime> starts;
        for (int back = 6; back >= 0; --back)
            starts.append(noon.addSecs(-86400 * back));
        QCOMPARE(boundary.starts(nextMorning), starts);
        QTemporaryDir dir;
        QDir project(dir.filePath("projects/p"));
        QVERIFY(project.mkpath("."));
        write(project.filePath("s.jsonl"),
              line("a", date("2027-01-15T11:00:00Z"), 1, 0) + line("b", date("2027-01-15T13:00:00Z"), 10, 0) +
                  line("c", date("2027-01-16T01:00:00Z"), 100, 0),
              nextMorning);
        const auto summary = ClaudeUsageCounter(dir.path()).summary(nextMorning, boundary);
        QCOMPARE(summary.today().total(), 110);
        QCOMPARE(summary.yesterday().total(), 1);
        QCOMPARE(summary.starts.last(), noon);
    }
    // Foundation 的用量时间解析按毫秒截断。极接近中午的时刻不能被舍入到下一桶。
    void testLastNanosecondBeforeNoonStaysInPreviousBucket() {
        QTemporaryDir dir;
        const QDir project(dir.filePath("projects/p"));
        QVERIFY(project.mkpath("."));
        const auto noon = QDateTime::fromString("2027-01-15T12:00:00Z", Qt::ISODate);
        QByteArray before = line("before", noon, 7, 0);
        QVERIFY(before.contains("12:00:00Z"));
        before.replace("12:00:00Z", "11:59:59.999999999Z");
        write(project.filePath("s.jsonl"), before + line("after", noon, 11, 0), noon);
        const auto summary = ClaudeUsageCounter(dir.path()).summary(noon, {QTimeZone::UTC, 12});
        QCOMPARE(summary.yesterday().total(), 7);
        QCOMPARE(summary.today().total(), 11);
    }
};
QTEST_APPLESS_MAIN(ClaudeUsageCounterTests)
#include "test_claude_usage_counter.moc"
