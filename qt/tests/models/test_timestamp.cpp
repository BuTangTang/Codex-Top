#include "models/models.h"
#include <QtTest>

using namespace codextop;
class TimestampTests : public QObject {
    Q_OBJECT
  private slots:
    // Swift 解析器需要带时区的完整时刻，未给时区不能用当前电脑设置补造。
    void requiresAnExplicitZoneAndSeconds() {
        for (const auto input : {"2027-01-15", "2027-01-15T08:00", "2027-01-15T08:00:00", "2027-01-15T08:00Z",
                                 "2027-01-15 08:00:00Z", "2027-01-15T08:00:00.1234567890Z"})
            QVERIFY(!parseTimestamp(input));
        for (const auto input :
             {"2027-01-15T08:00:00Z", "2027-01-15T16:00:00+0800", "2027-01-15T03:00:00-05:00",
              "2027-01-15T08:00:00GMT", "2027-01-15T08:00:00Ztail"}) {
            auto date = parseTimestamp(input);
            QVERIFY(date);
            QCOMPARE(date->toSecsSinceEpoch(), 1800000000LL);
        }
    }
};
QTEST_APPLESS_MAIN(TimestampTests)
#include "test_timestamp.moc"
