#include "usage/usage_day_boundary.h"

namespace codextop {
QDateTime UsageDayBoundary::start(const QDateTime &date) const {
    const auto local = date.toTimeZone(timeZone);
    QDateTime mark(local.date(), QTime(hour, 0), timeZone);
    if (!mark.isValid())
        return date;
    return mark <= local ? mark : mark.addDays(-1);
}
QList<QDateTime> UsageDayBoundary::starts(const QDateTime &endingAt, int count) const {
    QList<QDateTime> result;
    const auto today = start(endingAt);
    for (int back = count - 1; back >= 0; --back) {
        const auto day = today.addDays(-back);
        if (day.isValid())
            result.append(day);
    }
    return result;
}
} // namespace codextop
