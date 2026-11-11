#include "usage/codex_usage_counter.h"
#include "usage_fixture.h"
using namespace codextop;
using namespace usage_fixture;
class CodexUsageCounterTests : public QObject {
    Q_OBJECT
    static QByteArray tokenEvent(const QDateTime &at, int input, int cached, int output, int reasoning) {
        const QJsonObject total{{"input_tokens", input},
                                {"cached_input_tokens", cached},
                                {"output_tokens", output},
                                {"reasoning_output_tokens", reasoning},
                                {"total_tokens", input + output}};
        const QJsonObject info{{"total_token_usage", total}, {"last_token_usage", total}};
        const QJsonObject payload{{"type", "token_count"}, {"info", info}};
        return record({{"type", "event_msg"}, {"timestamp", at.toString(Qt::ISODate)}, {"payload", payload}});
    }
  private slots:
    void testCountsGrowthOfCumulativeTotalsPerDay() {
        QTemporaryDir dir;
        const UsageDayBoundary midnight{QTimeZone::UTC, 0};
        const auto file = dir.filePath("rollout-a.jsonl");
        write(file, tokenEvent(now.addSecs(-86400), 80, 30, 20, 5) + tokenEvent(now, 120, 50, 40, 10) +
                        tokenEvent(now, 120, 50, 40, 10));
        CodexUsageCounter counter;
        auto summary = counter.summary({file}, now, midnight);
        QCOMPARE(summary.yesterday().total(), 100);
        const CodexTokens expected{40, 20, 20, 5};
        QCOMPARE(summary.today(), expected);
        write(file, tokenEvent(now, 130, 50, 45, 10), now, true);
        summary = counter.summary({file}, now, midnight);
        QCOMPARE(summary.today().total(), 75);
        QCOMPARE(summary.week(), 175);
    }
};
QTEST_APPLESS_MAIN(CodexUsageCounterTests)
#include "test_codex_usage_counter.moc"
