#include "usage/codex_usage_counter.h"
#include "usage/usage_log_reader.h"
#include <QFileInfo>
#include <QSet>

namespace codextop {
CodexUsageSummary CodexUsageCounter::summary(const QStringList &paths, const QDateTime &now,
                                             const UsageDayBoundary &boundary) {
    QMutexLocker lock(&mutex);
    CodexUsageSummary summary;
    summary.starts = boundary.starts(now);
    if (summary.starts.isEmpty())
        return summary;
    const auto first = summary.starts.first();
    QSet<QString> live;
    for (const auto &path : paths) {
        if (QFileInfo(path).suffix() != "jsonl")
            continue;
        const auto key = path.normalized(QString::NormalizationForm_C);
        if (live.contains(key))
            continue;
        live.insert(key);
        auto &state = files[key];
        usage_detail::read(path, state, "\"token_count\"", [&](const QJsonObject &row) {
            const auto payload = row.value("payload").toObject();
            if (row.value("type").toString() != "event_msg" || payload.value("type").toString() != "token_count")
                return;
            const auto usage = payload.value("info").toObject().value("total_token_usage");
            const auto at = usage_detail::eventTime(row.value("timestamp").toString());
            if (!usage.isObject() || !at)
                return;
            const auto fields = usage.toObject();
            auto number = [&](const QString &key) { return usage_detail::integer(fields.value(key)); };
            const CodexTokens total{number("input_tokens"), number("cached_input_tokens"), number("output_tokens"),
                                    number("reasoning_output_tokens")};
            // 压缩上下文等场景会重置累计值；回退后从零重新计数。
            if (total.total() < state.last.total())
                state.last = {};
            const auto &last = state.last;
            const CodexTokens delta{
                qMax<qint64>(0, total.input - last.input), qMax<qint64>(0, total.cached - last.cached),
                qMax<qint64>(0, total.output - last.output), qMax<qint64>(0, total.reasoning - last.reasoning)};
            state.last = total;
            if (delta.total() > 0)
                state.buckets[boundary.start(*at)] += delta;
        });
        for (auto i = state.buckets.begin(); i != state.buckets.end();) {
            if (i.key() < first)
                i = state.buckets.erase(i);
            else
                ++i;
        }
        for (qsizetype i = 0; i < summary.starts.size(); ++i)
            summary.days[i] += state.buckets.value(summary.starts[i]);
    }
    for (auto i = files.begin(); i != files.end();) {
        if (!live.contains(i.key()))
            i = files.erase(i);
        else
            ++i;
    }
    return summary;
}
} // namespace codextop
