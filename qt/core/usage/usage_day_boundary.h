#pragma once
#include <QDateTime>
#include <QList>
#include <QTimeZone>

namespace codextop {
/// 以本机日历的中午为界，凌晨的活动仍计入前一天。测试可注入时区和切点。
struct UsageDayBoundary {
    QTimeZone timeZone;
    int hour = 12;
    static UsageDayBoundary localNoon() { return {QTimeZone::systemTimeZone(), 12}; }
    QDateTime start(const QDateTime &date) const;
    QList<QDateTime> starts(const QDateTime &endingAt, int count = 7) const;
};

/// 日桶从旧到新排列，保留起点供底栏标注星期。
template <typename Tokens> struct TokenUsageSummary {
    QList<Tokens> days = QList<Tokens>(7);
    QList<QDateTime> starts;
    Tokens today() const { return days.isEmpty() ? Tokens{} : days.last(); }
    Tokens yesterday() const { return days.size() < 2 ? Tokens{} : days.at(days.size() - 2); }
    qint64 week() const {
        qint64 sum = 0;
        for (const auto &day : days)
            sum += day.total();
        return sum;
    }
    bool operator==(const TokenUsageSummary &) const = default;
};
} // namespace codextop
