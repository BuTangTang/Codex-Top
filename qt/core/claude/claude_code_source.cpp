#include "claude_code_source.h"
#include "claude/claude_hook_events.h"
#include "codex/rollout_reducer.h"
#include <QDir>
#include <QFileInfo>
#include <QTimeZone>
#include <algorithm>
#include <limits>
#include <system_error>

namespace codextop {
namespace {
constexpr qint64 tailBytes = 64*1024;
constexpr qint64 coldReadLimit = 8*1024*1024;
constexpr int maximumSessions = 500;
constexpr double recentWindowSeconds = 30*86400;
struct SessionFile {
    QString id, path;
    qint64 size;
    PreciseTimestamp modified;
};
/// 排序时使用明确的精确事件时间；无时间的副本按远古时刻比较。
double latestEvent(const TaskActivity &activity) {
    auto event = activity.lastEventTimestamp();
    return event ? event->referenceSeconds() : -63114076800.0;
}
}

QString ClaudeCodeSource::defaultRoot() {
    const auto configured = qEnvironmentVariable("CLAUDE_CONFIG_DIR");
    return configured.isEmpty() ? QDir::home().filePath(".claude") : configured;
}

ClaudeCodeSource::ClaudeCodeSource(QString rootPath, QString events, ReadRegistry registry)
    : root(QDir::cleanPath(QFileInfo(rootPath).absoluteFilePath())), hookEvents(std::move(events)), readRegistry(std::move(registry)) {
    if (!readRegistry) readRegistry = [](const QString &path) { return ClaudeSessionRegistry::read(path); };
}

bool ClaudeCodeSource::installed() const { return QFileInfo(root).isDir(); }

SourceSnapshot ClaudeCodeSource::snapshot(QSet<QString> keepIDs, QDateTime now) {
    SourceSnapshot result;
    result.observedAt = now;
    const auto registry = readRegistry(root);
    if (registry.entries) {
        for (const auto &entry : *registry.entries)
            if (entry.alive) keepIDs.insert("cc:" + entry.sessionID);
    }
    const QDir projects(QDir(root).filePath("projects"));
    const auto projectsList = projects.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::Hidden | QDir::NoSymLinks, QDir::NoSort);
    QList<SessionFile> files;
    const auto nowSeconds = PreciseTimestamp{now}.referenceSeconds();
    for (const auto &project : projectsList) {
        const auto entries = QDir(project.absoluteFilePath()).entryInfoList(QDir::Files | QDir::Hidden | QDir::NoSymLinks, QDir::NoSort);
        for (const auto &entry : entries) {
            const auto path = QDir::cleanPath(entry.absoluteFilePath());
            if (entry.suffix() != "jsonl" || !path.startsWith(root + '/')) continue;
            RolloutFileMetadata meta;
            try { meta = RolloutFileMetadata::read(path); }
            catch (const std::system_error &) { continue; }
            if (!meta.regular) continue;
            const auto id = "cc:" + entry.completeBaseName();
            const PreciseTimestamp modified{QDateTime::fromSecsSinceEpoch(meta.seconds,QTimeZone::UTC).addMSecs(meta.nanoseconds/1000000),
                                            int(meta.nanoseconds%1000000)};
            if (keepIDs.contains(id) || nowSeconds - modified.referenceSeconds() <= recentWindowSeconds)
                files.append({id,path,meta.size,modified});
        }
    }
    std::stable_sort(files.begin(),files.end(),[](const auto &a,const auto &b){
        return a.modified.referenceSeconds()>b.modified.referenceSeconds();
    });
    if (files.size() > maximumSessions) {
        // 已选和存活会话优先；它们本身超过上限时也要全部保留。
        const auto rest = std::stable_partition(files.begin(), files.end(), [&](const auto &f){return keepIDs.contains(f.id);});
        files.erase(std::max(rest, files.begin() + maximumSessions),files.end());
    }
    QHash<QString,qsizetype> indices;
    QSet<QString> seen;
    for (const auto &file : files) {
        seen.insert(file.path);
        const auto [reducer, bytes] = advance(file.path,file.size);
        result.bytesRead += bytes;
        CodexTask task;
        task.id = file.id;
        task.origin = TaskOrigin::ClaudeCode;
        task.createdAt = reducer.firstEventAt.value_or(reducer.activity.lastEventAt.value_or(file.modified.date));
        task.updatedAt = reducer.activity.lastEventAt.value_or(task.createdAt);
        if (reducer.workingDirectory) {
            const auto cwd = QDir::cleanPath(QDir::fromNativeSeparators(*reducer.workingDirectory));
            task.project = cwd == "/" ? cwd : QFileInfo(cwd).fileName();
        }
        task.rolloutPath = file.path;
        task.activity = reducer.activity;
        const auto session = file.id.mid(3);
        const ClaudeSessionRegistry::Entry *entry = nullptr;
        if (registry.entries) {
            auto it = registry.entries->constFind(session);
            if (it != registry.entries->cend()) entry = &*it;
        }
        if (entry) task.claudeLaunch = ClaudeLaunch{entry->fromDesktopApp(),entry->hostSessionID};
        const auto name = entry && entry->name ? entry->name->trimmed() : QString{};
        task.title = reducer.title().value_or(name.isEmpty() ? QStringLiteral("未命名会话") : name);
        if (!hookEvents.isEmpty() && task.activity.phase == TaskPhase::Running)
            task.activity = ClaudeHookEvents::apply(ClaudeHookEvents::latest(hookEvents,session),task.activity);
        if (registry.entries && isActive(task.activity.phase) && !(entry && entry->alive)) {
            task.activity.phase = TaskPhase::Stopped;
            task.activity.detail = QStringLiteral("会话已退出");
            task.activity.setWaitingStartedTimestamp(std::nullopt);
        }
        task.activity = task.activity.effective(now,900,originDisplayName(TaskOrigin::ClaudeCode));
        auto index = indices.constFind(task.id);
        if (index == indices.cend()) {
            indices.insert(task.id,result.tasks.size());
            result.tasks.append(task);
        } else {
            // 跨目录同编号各自维护游标；只按活动日期选出要显示的整份任务。
            const auto &previous = result.tasks.at(*index);
            const auto currentAt = latestEvent(task.activity), previousAt = latestEvent(previous.activity);
            if (currentAt > previousAt || (currentAt == previousAt && task.rolloutPath < previous.rolloutPath))
                result.tasks[*index] = task;
        }
    }
    tails.removeIf([&](auto it){return !seen.contains(it.key());});
    return result;
}

std::pair<ClaudeTranscriptReducer,qint64> ClaudeCodeSource::advance(const QString &path, qint64 size) {
    auto existing = tails.find(path);
    if (existing != tails.end() && size >= existing->offset) {
        if (size == existing->size) return {existing->reducer,0};
        const auto [consumed,bytes] = consume(path,existing->offset,existing->reducer,false);
        existing->offset += consumed;
        existing->size = size;
        return {existing->reducer,bytes};
    }
    qint64 total = 0;
    for (qint64 window = tailBytes;; window *= 4) {
        const auto start = std::max<qint64>(0,size-window);
        ClaudeTranscriptReducer reducer;
        const auto [consumed,bytes] = consume(path,start,reducer,start>0);
        total += bytes;
        // 原生在读完这一档后比较 8 MiB；保留 64 KiB 每次乘四的实际取档顺序。
        if (reducer.firstEventAt || start == 0 || window >= coldReadLimit) {
            tails.insert(path,{size,start+consumed,reducer});
            return {reducer,total};
        }
    }
}

std::pair<qint64,qint64> ClaudeCodeSource::consume(const QString &path, qint64 offset, ClaudeTranscriptReducer &reducer, bool dropFirstLine) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {0,0};
    file.seek(offset);
    const auto data = file.readAll();
    if (file.error() != QFileDevice::NoError) return {0,0};
    qsizetype begin = 0, newline;
    while ((newline = data.indexOf('\n',begin)) >= 0) {
        if (!dropFirstLine && newline>begin)
            reducer.consume(QByteArray::fromRawData(data.constData()+begin,newline-begin));
        dropFirstLine = false;
        begin = newline+1;
    }
    return {begin,data.size()};
}
}
