#include "usage/claude_usage_counter.h"
#include "usage/usage_log_reader.h"
#include <QDir>
#include <QFileInfo>
#include <QSet>
#include <algorithm>

namespace codextop {
ClaudeUsageCounter::ClaudeUsageCounter(const QString &root)
    : root(QDir::cleanPath(QFileInfo(root).absoluteFilePath())) {}

QStringList ClaudeUsageCounter::transcripts(const QDateTime &modifiedSince) const {
    QStringList result;
    auto recent = [&](const QFileInfo &file) {
        return file.suffix() == "jsonl" && !file.isSymLink() && file.isFile() && file.lastModified() >= modifiedSince;
    };
    const QDir projects(QDir(root).filePath("projects"));
    const auto dirs = QDir::Dirs | QDir::Hidden | QDir::NoDotAndDotDot;
    for (const auto &project : projects.entryInfoList(dirs, QDir::Unsorted)) {
        QDir folder(project.filePath());
        for (const auto &entry : folder.entryInfoList(dirs | QDir::Files, QDir::Unsorted)) {
            if (recent(entry)) {
                result.append(entry.filePath());
            } else if (!entry.isSymLink() && entry.isDir()) {
                const QDir subagents(QDir(entry.filePath()).filePath("subagents"));
                for (const auto &file : subagents.entryInfoList(QDir::Files | QDir::Hidden, QDir::Unsorted))
                    if (recent(file))
                        result.append(file.filePath());
            }
        }
    }
    return result;
}
ClaudeUsageSummary ClaudeUsageCounter::summary(const QDateTime &now, const UsageDayBoundary &boundary) {
    QMutexLocker lock(&mutex);
    ClaudeUsageSummary summary;
    summary.starts = boundary.starts(now);
    if (summary.starts.isEmpty())
        return summary;
    const auto first = summary.starts.first();
    QSet<QString> live;
    for (const auto &path : transcripts(first)) {
        const auto pathKey = path.normalized(QString::NormalizationForm_C);
        live.insert(pathKey);
        auto &state = files[pathKey];
        usage_detail::read(path, state, "\"usage\"", [&](const QJsonObject &row) {
            const auto apiError = row.value("isApiErrorMessage");
            if (row.value("type").toString() != "assistant" || apiError.toBool() ||
                (apiError.isDouble() && apiError.toDouble() == 1))
                return;
            const auto message = row.value("message").toObject();
            const auto usage = message.value("usage");
            const auto at = usage_detail::eventTime(row.value("timestamp").toString());
            if (!usage.isObject() || !at)
                return;
            const auto fields = usage.toObject();
            auto number = [&](const QString &key) { return usage_detail::integer(fields.value(key)); };
            const ClaudeTokens tokens{number("input_tokens") + number("cache_creation_input_tokens"),
                                      number("output_tokens"), number("cache_read_input_tokens")};
            const auto day = boundary.start(*at);
            const auto messageID = message.value("id");
            if (messageID.isString()) {
                const auto key = messageID.toString().normalized(QString::NormalizationForm_C);
                if (!state.entries.contains(key))
                    state.entries.insert(key, {day, tokens});
            } else
                state.unnamed[day] += tokens;
        });
        for (auto i = state.entries.begin(); i != state.entries.end();) {
            if (i->day < first)
                i = state.entries.erase(i);
            else
                ++i;
        }
        for (auto i = state.unnamed.begin(); i != state.unnamed.end();) {
            if (i.key() < first)
                i = state.unnamed.erase(i);
            else
                ++i;
        }
    }
    for (auto i = files.begin(); i != files.end();) {
        if (!live.contains(i.key()))
            i = files.erase(i);
        else
            ++i;
    }
    // 续接副本跨文件去重，同编号选路径按原生字符串顺序排在前面的文件。
    auto paths = files.keys();
    std::sort(paths.begin(), paths.end(), [](const QString &a, const QString &b) { return a.toUtf8() < b.toUtf8(); });
    QHash<QDateTime, ClaudeTokens> buckets;
    QSet<QString> counted;
    for (const auto &path : paths) {
        const auto &state = *files.constFind(path);
        for (auto i = state.entries.cbegin(); i != state.entries.cend(); ++i) {
            if (counted.contains(i.key()))
                continue;
            counted.insert(i.key());
            buckets[i->day] += i->tokens;
        }
        for (auto i = state.unnamed.cbegin(); i != state.unnamed.cend(); ++i)
            buckets[i.key()] += *i;
    }
    summary.days.clear();
    for (const auto &day : summary.starts)
        summary.days.append(buckets.value(day));
    return summary;
}
} // namespace codextop
