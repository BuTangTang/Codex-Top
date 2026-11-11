#include "codex/compressed_rollout_reader.h"
#include "codex/rollout_reducer.h"
#include "codex/desktop_reply_receipt_source.h"
extern "C" {
#include <CZstd.h>
}
#include <QDir>
#include <QTimeZone>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QThreadPool>
#include <atomic>
#include <cstring>
#include <future>
#include <system_error>

namespace codextop {
namespace {
using Reader = CompressedRolloutReader;
using Category = Reader::Category;
using Result = Reader::Result;
using Metadata = RolloutFileMetadata;
struct Changed {};
struct Cancelled {};
struct Outcome {
    Result result;
    std::optional<RolloutReducer> reducer;
};
struct Job {
    QString id, path;
    Metadata fingerprint;
    std::atomic<bool> cancelled{false};
    std::atomic<qint64> bytes{0};
    qint64 reported = 0;
    std::promise<Outcome> promise;
    std::future<Outcome> done = promise.get_future();
};
// 无完整状态时只给用户看固定原因，不泄漏文件名或正文。
Result message(Category type, const QString &text) {
    Result value;
    value.category = type;
    value.activity.detail = text;
    return value;
}
// 将文件错误映射为与原生版相同的有限类别。
Result fileFailure(std::error_code code) {
    if (code == std::errc::permission_denied || code == std::errc::operation_not_permitted)
        return message(Category::Unavailable, QStringLiteral("无权读取任务记录"));
    if (code == std::errc::no_such_file_or_directory)
        return message(Category::Unavailable, QStringLiteral("任务记录缺失"));
    return message(Category::Unavailable, QStringLiteral("压缩记录损坏或不完整"));
}
// 读取截断 JSON 的简单字段。只认顶层顺序和完整的短字符串，不从正文匹配字段。
class Scanner {
    const QByteArray &bytes;
    qsizetype index = 0;
    static bool whitespace(char c) {
        return c == ' ' || c == '\r' || c == '\n' || c == '\t';
    }

  public:
    explicit Scanner(const QByteArray &data) : bytes(data) {}
    bool peek(char c) {
        while (index < bytes.size() && whitespace(bytes[index]))
            ++index;
        return index < bytes.size() && bytes[index] == c;
    }
    bool take(char c) {
        if (!peek(c))
            return false;
        ++index;
        return true;
    }
    std::optional<QString> string() {
        if (!take('"'))
            return {};
        QByteArray result;
        while (index < bytes.size()) {
            char c = bytes[index++];
            if (c == '"')
                return result.isValidUtf8() ? std::optional(QString::fromUtf8(result)) : std::nullopt;
            if (c == '\\') {
                if (index == bytes.size())
                    return {};
                c = bytes[index++];
                if (c == 'n')
                    c = '\n';
                else if (c == 't')
                    c = '\t';
                else if (c != '\\' && c != '"' && c != '/')
                    return {};
            }
            result.append(c);
            if (result.size() > 512)
                return {};
        }
        return {};
    }
    std::optional<QString> key() {
        const auto saved = index;
        auto name = string();
        if (name && take(':'))
            return name;
        index = saved;
        return {};
    }
    std::optional<QString> simple() {
        if (peek('"'))
            return string();
        const auto start = index;
        while (index < bytes.size()) {
            const char c = bytes[index];
            if (c == ',' || c == '}' || c == ']' || whitespace(c))
                break;
            if (!(c >= '-' && c <= '9') && !(c >= 'a' && c <= 'z') && c != '+' && c != 'E')
                return {};
            ++index;
        }
        if (index >= bytes.size() || start == index)
            return {};
        return QString::fromLatin1(bytes.constData() + start, index - start);
    }
};
} // namespace
// 生成最小摘要，决定状态所需的嵌套值不完整时整份结果保持未知。
Reader::LongLine Reader::summarizeLongLine(const QByteArray &prefix) {
    Scanner scan(prefix);
    if (!scan.take('{'))
        return {};
    QString kind;
    std::optional<QString> timestamp, itemType;
    QHash<QString, QString> fields;
    bool sawPayload = false;
    while (auto key = scan.key()) {
        if (*key == "payload") {
            if (!scan.take('{'))
                return {};
            sawPayload = true;
            while (auto inner = scan.key()) {
                if (*inner == "item" && scan.take('{')) {
                    while (auto k = scan.key()) {
                        auto v = scan.simple();
                        if (!v)
                            break;
                        if (*k == "type")
                            itemType = *v;
                        if (!scan.take(','))
                            break;
                    }
                    break;
                }
                auto v = scan.simple();
                if (!v)
                    break;
                fields[*inner] = *v;
                if (!scan.take(','))
                    break;
            }
            break;
        }
        auto value = scan.simple();
        if (!value)
            return {};
        if (*key == "type")
            kind = *value;
        if (*key == "timestamp")
            timestamp = *value;
        if (!scan.take(','))
            return {};
    }
    if (!sawPayload || kind.isEmpty())
        return {};
    if (kind != "event_msg" && kind != "response_item")
        return {LongLine::Ignore, {}};
    if (!fields.contains("type"))
        return {};
    const QString type = fields["type"];
    QJsonObject payload{{"type", type}};
    if (kind == "event_msg") {
        static const QSet<QString> lifecycle{"task_started",
                                             "turn_started",
                                             "task_complete",
                                             "turn_complete",
                                             "turn_aborted",
                                             "task_cancelled",
                                             "turn_cancelled",
                                             "task_failed",
                                             "turn_failed",
                                             "request_user_input",
                                             "user_input_requested",
                                             "exec_approval_request",
                                             "apply_patch_approval_request",
                                             "user_message",
                                             "user_input",
                                             "approval_resolved",
                                             "agent_message",
                                             "agent_reasoning"};
        if (lifecycle.contains(type)) {
            if (fields.contains("turn_id"))
                payload["turn_id"] = fields["turn_id"];
        } else if (type == "item_completed") {
            if (!itemType)
                return {};
            payload["item"] = QJsonObject{{"type", *itemType}};
        } else if (type == "token_count")
            return {};
        else
            return {LongLine::Ignore, {}};
    } else {
        QString key;
        if (type == "message")
            key = "role";
        else if (type == "function_call" || type == "custom_tool_call") {
            key = "name";
            if (fields.value(key).contains("request_user_input"))
                return {};
        } else if (type == "function_call_output" || type == "custom_tool_call_output")
            key = "call_id";
        else
            return {LongLine::Ignore, {}};
        if (!fields.contains(key))
            return {};
        payload[key] = fields[key];
    }
    QJsonObject summary{{"type", kind}, {"payload", payload}};
    if (timestamp)
        summary["timestamp"] = *timestamp;
    return {LongLine::Line, QJsonDocument(summary).toJson(QJsonDocument::Compact)};
}

namespace {
// 后台解码器只保存当前行和 4 KiB 的超长行行首，完整帧和文件代次同时通过才发布。
Outcome decode(const std::shared_ptr<Job> &job, qint64 maximum, QFile &file, CTZDecoder *decoder) {
    constexpr int block = 65536, prefixLength = 4096;
    QByteArray input, output(block, Qt::Uninitialized), line;
    qsizetype pos = 0;
    qint64 produced = 0;
    bool skipped = false, gap = false, complete = false;
    RolloutReducer reducer;
    while (!job->cancelled.load()) {
        if (pos == input.size()) {
            input = file.read(block);
            if (file.error() != QFile::NoError)
                return {fileFailure(std::make_error_code(std::errc::io_error)), {}};
            job->bytes.fetch_add(input.size());
            pos = 0;
            if (input.isEmpty() && complete) {
                if (Metadata::read(job->path) != job->fingerprint || Metadata::read(file) != job->fingerprint)
                    throw Changed{};
                if (gap || !line.isEmpty() || skipped ||
                    (reducer.activity.turnID && reducer.activity.turnID->toUtf8().size() > 4096) ||
                    reducer.retainedMetadataBytes() > 12288)
                    return {message(Category::Limited, QStringLiteral("压缩记录含超长或不完整行，状态未确认")), {}};
                return {{reducer.activity, reducer.quota, Category::Ready, 0}, std::move(reducer)};
            }
        }
        size_t consumed = 0, written = 0;
        const auto available = input.size() - pos;
        const size_t limit = static_cast<size_t>(std::min<qint64>(block, maximum - produced + 1));
        const int code =
            ctz_step(decoder, input.constData() + pos, available, &consumed, output.data(), limit, &written);
        pos += consumed;
        produced += written;
        if (code < 0) {
            if (code == -2)
                return {message(Category::Limited, QStringLiteral("压缩记录暂不支持或超过资源上限，状态未确认")), {}};
            return {fileFailure(std::make_error_code(std::errc::invalid_argument)), {}};
        }
        if (produced > maximum)
            return {message(Category::Limited, QStringLiteral("压缩记录超过读取上限，状态未确认")), {}};
        qsizetype at = 0;
        while (at < static_cast<qsizetype>(written)) {
            const char *start = output.constData() + at;
            const char *newline = static_cast<const char *>(std::memchr(start, '\n', written - at));
            const qsizetype count = newline ? newline - start : written - at;
            if (!skipped) {
                if (line.size() + count <= block)
                    line.append(start, count);
                else {
                    if (line.size() < prefixLength)
                        line.append(start, qMin(count, prefixLength - line.size()));
                    line.truncate(prefixLength);
                    skipped = true;
                }
            }
            if (newline) {
                if (!skipped && !line.isEmpty())
                    reducer.consume(line);
                else if (skipped) {
                    reducer.noteUninspectedRecord();
                    const auto summary = Reader::summarizeLongLine(line);
                    if (summary.kind == Reader::LongLine::Line) {
                        // 摘要不带导入序号，已确认本机开始后才能按原有规则归约。
                        if (reducer.acceptsNativeLineSummary()) reducer.consume(summary.data);
                        else gap = true;
                    } else if (summary.kind == Reader::LongLine::Gap) {
                        gap = true;
                    }
                }
                if (reducer.retainedMetadataBytes() > 1024 * 1024)
                    return {message(Category::Limited, QStringLiteral("压缩记录暂不支持或超过资源上限，状态未确认")),
                            {}};
                line.resize(0);
                skipped = false;
            }
            at += count + 1;
        }
        complete = code == 1;
        if (!consumed && !written && !available)
            return {fileFailure(std::make_error_code(std::errc::invalid_argument)), {}};
    }
    throw Cancelled{};
}
} // namespace
struct Reader::Impl {
    struct Cached {
        Metadata fingerprint;
        Result result;
        std::optional<RolloutReducer> reducer;
    };
    QHash<QString, Cached> cache;
    std::shared_ptr<Job> job;
    bool used = false;
    qint64 maximum;
    QString cachePath;
    QThreadPool queue;

    // 文件代次和状态够用，账号、正文和原始文件路径不进入缓存。
    void persist() const {
        if (cachePath.isEmpty())
            return;
        QJsonObject entries;
        for (auto i = cache.cbegin(); i != cache.cend(); ++i) {
            const auto &value = i.value();
            const auto &f = value.fingerprint;
            const auto &activity = value.result.activity;
            if ((value.result.category != Category::Ready && value.result.category != Category::Limited) ||
                activity.phase == TaskPhase::Waiting)
                continue;
            const QJsonObject fingerprint{{"device", qint64(f.device)},
                                          {"inode", qint64(f.inode)},
                                          {"size", f.size},
                                          {"seconds", f.seconds},
                                          {"nanos", f.nanoseconds}};
            QJsonObject entry{{"fingerprint", fingerprint},
                              {"phase", phaseRawValue(activity.phase)},
                              {"detail", activity.detail},
                              {"limited", value.result.category == Category::Limited},
                              {"isTeamChatImport", activity.isTeamChatImport}};
            // Swift Codable 日期以 2001-01-01 为起点，保留同格式的分数秒。
            if (auto time = activity.lastEventTimestamp())
                entry["lastEventAt"] = time->referenceSeconds();
            if (auto time = activity.startedTimestamp())
                entry["startedAt"] = time->referenceSeconds();
            entries[i.key()] = entry;
        }
        const QByteArray bytes =
            QJsonDocument(QJsonObject{{"version", 2}, {"entries", entries}}).toJson(QJsonDocument::Compact);
        if (!QDir().mkpath(QFileInfo(cachePath).absolutePath()))
            return;
        QSaveFile file(cachePath);
        if (file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size())
            file.commit();
    }
    // 只恢复完整的版本 2 缓存，损坏条目不构造伪造的活动状态。
    void load() {
        QFile f(cachePath);
        if (cachePath.isEmpty() || !f.open(QIODevice::ReadOnly))
            return;
        const auto doc = QJsonDocument::fromJson(f.readAll()).object();
        if (doc["version"] != 2 || !doc["entries"].isObject())
            return;
        const auto entries = doc["entries"].toObject();
        if (entries.size() > 256)
            return;
        QHash<QString, Cached> restored;
        for (auto i = entries.begin(); i != entries.end(); ++i) {
            const auto entry = i.value().toObject(), fp = entry["fingerprint"].toObject();
            auto phase = phaseFromRawValue(entry["phase"].toString());
            if (!phase || !entry["detail"].isString() || !entry["limited"].isBool() || !entry["isTeamChatImport"].isBool())
                return;
            for (const char *key : {"device", "inode", "size", "seconds", "nanos"})
                if (!fp[key].isDouble())
                    return;
            Cached value{};
            auto &m = value.fingerprint;
            m.device = fp["device"].toInteger();
            m.inode = fp["inode"].toInteger();
            m.size = fp["size"].toInteger();
            m.seconds = fp["seconds"].toInteger();
            m.nanoseconds = fp["nanos"].toInteger();
            m.regular = true;
            value.result.category = entry["limited"].toBool() ? Category::Limited : Category::Ready;
            value.result.activity.phase = *phase;
            value.result.activity.detail = entry["detail"].toString();
            for (const char *key : {"lastEventAt", "startedAt"}) {
                if (!entry.contains(key) || entry[key].isNull())
                    continue;
                if (!entry[key].isDouble())
                    return;
                auto time = PreciseTimestamp::fromReferenceSeconds(entry[key].toDouble());
                if (!time) return;
                if (qstrcmp(key, "startedAt") == 0) value.result.activity.setStartedTimestamp(time);
                else value.result.activity.setLastEventTimestamp(time);
            }
            if (entry["isTeamChatImport"].toBool()) value.result.activity = TaskActivity::teamChatImport();
            restored[i.key()] = std::move(value);
        }
        cache = std::move(restored);
    }
    // 取消立即对调用者生效，旧工作在下一块输入时停止且无法再发布。
    void stop() {
        if (job)
            job->cancelled = true;
        job.reset();
    }
};
Reader::CompressedRolloutReader(qint64 maximumOutput, QString cachePath) : d(std::make_unique<Impl>()) {
    d->queue.setMaxThreadCount(1);
    d->maximum = std::clamp<qint64>(maximumOutput, 0, std::numeric_limits<qint64>::max() - 1);
    d->cachePath = std::move(cachePath);
    d->load();
}
Reader::~CompressedRolloutReader() {
    d->stop();
    d->queue.waitForDone();
}
void Reader::beginCycle(const QSet<QString> &ids) {
    d->used = false;
    for (auto it = d->cache.begin(); it != d->cache.end();) {
        if (ids.contains(it.key()))
            ++it;
        else
            it = d->cache.erase(it);
    }
    if (d->job && !ids.contains(d->job->id))
        d->stop();
}
void Reader::waitForBackgroundRead() {
    if (d->job)
        d->job->done.wait();
}
void Reader::forget(const QString &id) {
    d->cache.remove(id);
    if (d->job && d->job->id == id)
        d->stop();
}
std::optional<QDateTime> Reader::awaitingReplySince(const QString &id) const {
    auto i = d->cache.constFind(id);
    return i != d->cache.cend() && i->reducer ? i->reducer->awaitingReplySince() : std::nullopt;
}
std::optional<TaskActivity> Reader::projectedActivity(const QString &id, const QList<QuestionReplyReceipt> &receipts,
                                                      const QDateTime &now) const {
    auto i = d->cache.constFind(id);
    if (i == d->cache.cend() || !i->reducer)
        return {};
    return i->reducer->activityAcknowledging(receipts, id, now);
}
// 路径与打开对象都符合代次，才允许缓存解码结果；每轮最多启动一个新的文件。
Reader::Result Reader::read(const QString &id, const QString &path, const QDateTime &now) {
    Metadata f;
    try {
        f = Metadata::read(path);
        if (!f.regular)
            throw std::system_error(std::make_error_code(std::errc::invalid_argument));
    } catch (const std::system_error &e) {
        forget(id);
        return fileFailure(e.code());
    }
    if (auto it = d->cache.constFind(id); it != d->cache.cend() && it->fingerprint == f) {
        Result result = it->result;
        result.activity = result.activity.effective(now);
        return result;
    }
    d->cache.remove(id);
    if (d->job && d->job->id == id && (path != d->job->path || d->job->fingerprint != f))
        d->stop();
    if (d->cache.size() >= 256)
        return message(Category::Limited, QStringLiteral("尚未读取（资源限制）"));
    const auto reading = [] { return message(Category::Reading, QStringLiteral("正在读取压缩记录")); };
    const auto queued = [] { return message(Category::Reading, QStringLiteral("等待读取压缩记录")); };
    const auto changed = [] { return message(Category::Reading, QStringLiteral("记录已变化，等待重新读取")); };
    if (auto job = d->job) {
        if (job->id != id)
            return queued();
        qint64 bytes = job->bytes.load() - job->reported;
        job->reported += bytes;
        if (job->done.wait_for(std::chrono::seconds(0)) != std::future_status::ready) {
            auto value = reading();
            value.bytes = bytes;
            return value;
        }
        d->job.reset();
        // 完成信号可能在上面的进度采样后到达，最后一个输入块仍计入本轮。
        bytes += job->bytes.load() - job->reported;
        Result result;
        try {
            auto outcome = job->done.get();
            result = outcome.result;
            d->cache.insert(id, {f, result, std::move(outcome.reducer)});
            if (result.category == Category::Ready || result.category == Category::Limited)
                d->persist();
            result.activity = result.activity.effective(now);
        } catch (const Changed &) {
            result = changed();
        } catch (const std::system_error &e) {
            result = fileFailure(e.code());
            d->cache.insert(id, {f, result, {}});
        } catch (const Cancelled &) {
            result = changed();
        }
        result.bytes = bytes;
        return result;
    }
    if (d->used)
        return queued();
    d->used = true;
    auto file = std::make_shared<QFile>(path);
    if (!file->open(QIODevice::ReadOnly)) {
        auto code = file->error() == QFileDevice::PermissionsError ? std::errc::permission_denied : std::errc::io_error;
        auto result = fileFailure(std::make_error_code(code));
        d->cache.insert(id, {f, result, {}});
        return result;
    }
    try {
        if (Metadata::read(*file) != f)
            return changed();
    } catch (const std::system_error &e) {
        return fileFailure(e.code());
    }
    auto decoder = std::shared_ptr<CTZDecoder>(ctz_create(), ctz_destroy);
    if (!decoder)
        return message(Category::Limited, QStringLiteral("压缩记录暂不支持或超过资源上限，状态未确认"));
    auto job = std::make_shared<Job>();
    job->id = id;
    job->path = path;
    job->fingerprint = f;
    d->job = job;
    d->queue.start([job, file, decoder, limit = d->maximum] {
        try {
            job->promise.set_value(decode(job, limit, *file, decoder.get()));
        } catch (...) {
            job->promise.set_exception(std::current_exception());
        }
    });
    return reading();
}
} // namespace codextop
