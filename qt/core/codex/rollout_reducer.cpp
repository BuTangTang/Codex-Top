#include "rollout_reducer.h"
#include "rollout_timing_recovery.h"
#include "question_reply_receipt.h"
#include "tool_activity_text.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QTimeZone>
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <limits>
#include <system_error>
#ifdef Q_OS_WIN
#include <qt_windows.h>
#include <QDir>
#include <io.h>
#include <filesystem>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace codextop {
namespace {

/// 区分未给字符串和给了空字符串，与 Swift 的 as? String 匹配。
std::optional<QString> stringValue(const QJsonValue &value) {
    return value.isString() ? std::optional{value.toString()} : std::nullopt;
}

/// JSONSerialization 的 NSNumber 在日志额度分支中也接受布尔值。
std::optional<double> numericValue(const QJsonValue &value) {
    if (value.isBool()) return value.toBool() ? 1.0 : 0.0;
    return value.isDouble() ? std::optional{value.toDouble()} : std::nullopt;
}

/// 按 Swift 的整型转换规则接受无小数部分的数值。
std::optional<qint64> integerValue(const QJsonValue &value) {
    if (value.isBool()) return value.toBool() ? 1 : 0;
    constexpr qint64 invalid = std::numeric_limits<qint64>::min();
    const auto number = value.toInteger(invalid);
    if (number == invalid) return std::nullopt;
    return number;
}

/// 结束类事件统一检查轮次编号，旧轮的结束不能覆盖新轮。
bool isTerminal(const QString &type) {
    static const QStringList types{"task_complete", "turn_complete", "turn_aborted", "task_cancelled",
                                   "turn_cancelled", "task_failed", "turn_failed"};
    return types.contains(type);
}
} // namespace

bool RolloutReducer::isAutomaticCopyHeader(const QJsonObject &record) {
    return record["type"].toString() == "session_meta"
        && record["payload"].toObject()["teamchat_copy"].toObject()["automatic"].toBool();
}

bool RolloutReducer::hasImportedOrdinal(const QJsonObject &record) {
    const auto number = record["ordinal"];
    return number.isDouble() && number.toInteger(-1) >= 0;
}

bool RolloutReducer::acceptsNativeLineSummary() const {
    return !isAutomaticTeamChatCopy || hasNativePagination || isActive(activity.phase)
        || isFinished(activity.phase) || activity.phase == TaskPhase::Failed;
}

void RolloutReducer::noteUninspectedRecord() {
    expectsFileHeader = onlyImportedRecords = false;
    if (activity.isTeamChatImport) activity = TaskActivity{};
}

void RolloutReducer::publishImportIfComplete(bool complete) {
    if (onlyImportedRecords) activity = complete ? TaskActivity::teamChatImport() : TaskActivity{};
}

void RolloutReducer::consume(const QByteArray &line) {
    const bool first = expectsFileHeader;
    expectsFileHeader = false;
    const QJsonObject record = QJsonDocument::fromJson(line).object();
    if (!record["payload"].isObject() || !record["type"].isString()) {
        noteUninspectedRecord();
        return;
    }
    const auto payload = record["payload"].toObject();
    const auto kind = record["type"].toString(), type = payload["type"].toString();
    if (first && isAutomaticCopyHeader(record)) {
        isAutomaticTeamChatCopy = onlyImportedRecords = true;
        activity = TaskActivity::teamChatImport();
        return;
    }
    if (isAutomaticTeamChatCopy) {
        // 带序号的本机续聊从原生上下文或含专属字段的开始事件起参与归约。
        if (kind == "turn_context" || (kind == "event_msg" && (type == "turn_started" || (type == "task_started"
            && (payload.contains("started_at") || payload.contains("turn_attribution"))))))
            hasNativePagination = true;
        // 生成器只导入以下事件，其他带序号的未知记录不能证明整个文件都是远端历史。
        static const QStringList projectedEvents{"task_started","task_complete","user_message","agent_message",
                                                  "mcp_tool_call_begin","mcp_tool_call_end"};
        static const QStringList projectedResponses{"message","function_call","function_call_output"};
        if (!hasNativePagination && hasImportedOrdinal(record) &&
            ((kind == "event_msg" && projectedEvents.contains(type)) ||
             (kind == "response_item" && projectedResponses.contains(type)))) return;
        if (kind == "event_msg" && (type == "thread_settings_applied" || type == "thread_name_updated")) return;
        noteUninspectedRecord();
    }
    const auto at = parsePreciseTimestamp(record["timestamp"].toString());
    if (at && activity.lastEventAt && at->referenceSeconds() < activity.lastEventTimestamp()->referenceSeconds()) return;
    const auto turn = stringValue(payload["turn_id"]);
    const bool event = kind == "event_msg";
    if (event && isTerminal(type) && turn && activity.turnID && turn != activity.turnID) return;
    const auto itemType = payload["item"].toObject()["type"].toString().toLower();
    const bool userItem = type == "item_completed" && itemType == "usermessage";
    const bool responseUser = kind == "response_item" && type == "message" && payload["role"].toString() == "user";
    const bool starts = type == "task_started" || type == "turn_started";
    const bool userInput = type == "user_message" || type == "user_input" || type == "approval_resolved";
    const auto limits = payload["rate_limits"];
    if (activity.phase == TaskPhase::Failed && !responseUser && !(event && (starts || userInput || userItem))) {
        // 失败后只有明确续接可恢复；额度记录仍可单独更新。
        if (event && type == "token_count" && limits.isObject() && at) {
            updateQuota(limits.toObject(), at->date);
            activity.setLastEventTimestamp(at);
        }
        return;
    }
    if (event) {
        if (starts) {
            activity = TaskActivity{};
            activity.phase = TaskPhase::Running;
            activity.detail = QStringLiteral("正在执行");
            activity.setStartedTimestamp(at);
            activity.setLastEventTimestamp(at);
            activity.turnID = turn;
            waitingCallIDs.clear();
            asynchronousQuestion = false;
            clearReplyQuestions();
        } else if (type == "task_complete" || type == "turn_complete") {
            turnEnded = true;
            if (asynchronousQuestion) waiting(at, QStringLiteral("等待你的回答"));
            else {
                activity.phase = TaskPhase::Completed;
                activity.detail = QStringLiteral("本轮执行已结束");
                activity.setWaitingStartedTimestamp(std::nullopt);
            }
            waitingCallIDs.clear();
        } else if (isTerminal(type)) {
            const bool failed = type == "task_failed" || type == "turn_failed";
            activity.phase = failed ? TaskPhase::Failed : TaskPhase::Stopped;
            activity.detail = failed ? QStringLiteral("执行遇到问题，请回到 Codex 查看") : QStringLiteral("本轮执行已停止");
            activity.setWaitingStartedTimestamp(std::nullopt);
            waitingCallIDs.clear();
            asynchronousQuestion = false;
            clearReplyQuestions();
        } else if (type == "request_user_input" || type == "user_input_requested"
                   || type == "exec_approval_request" || type == "apply_patch_approval_request") {
            untrackedWait = true;
            waiting(at, QStringLiteral("等待你的输入或确认"));
        } else if (userInput || userItem) {
            active(at, QStringLiteral("收到输入，正在继续"));
            waitingCallIDs.clear();
            asynchronousQuestion = false;
            clearReplyQuestions();
        } else if (type == "agent_message" || type == "agent_reasoning") {
            if (activity.phase != TaskPhase::Waiting && !isFinished(activity.phase))
                active(at, type == "agent_reasoning" ? QStringLiteral("正在思考") : QStringLiteral("正在处理任务"));
        } else if (type == "token_count") {
            if (limits.isObject() && at) updateQuota(limits.toObject(), at->date);
        } else if (type == "item_completed") {
            if ((itemType == "commandexecution" || itemType == "filechange" || itemType == "reasoning" || itemType == "mcptoolcall")
                && activity.phase != TaskPhase::Waiting && !isFinished(activity.phase))
                active(at, itemType == "filechange" ? QStringLiteral("正在修改文件") : QStringLiteral("正在执行任务"));
        } else return;
    } else if (kind == "response_item") {
        if (responseUser) {
            active(at, QStringLiteral("收到输入，正在继续"));
            waitingCallIDs.clear();
            asynchronousQuestion = false;
            clearReplyQuestions();
        } else if (type == "function_call" || type == "custom_tool_call") {
            const auto name = payload["name"].toString();
            if (name == "request_user_input" || name == "request_user_input_async" || name.endsWith("__request_user_input")) {
                waiting(at, QStringLiteral("等待你的回答"));
                if (name == "request_user_input_async") {
                    asynchronousQuestion = true;
                    rememberReplyQuestion(payload, at);
                } else if (const auto id = stringValue(payload["call_id"])) {
                    waitingCallIDs.insert(*id);
                } else untrackedWait = true;
            } else if (activity.phase != TaskPhase::Waiting) active(at, ToolActivityText::detail(name));
        } else if (type == "function_call_output" || type == "custom_tool_call_output") {
            const auto id = stringValue(payload["call_id"]);
            if (id && waitingCallIDs.remove(*id) && waitingCallIDs.isEmpty() && !asynchronousQuestion)
                active(at, QStringLiteral("已收到回答，正在继续"));
        } else return;
    } else return;
    if (at) activity.setLastEventTimestamp(at);
}

qsizetype RolloutReducer::retainedMetadataBytes() const {
    qsizetype size = 1024 + activity.detail.toUtf8().size();
    if (activity.turnID) size += activity.turnID->toUtf8().size();
    for (const auto &call : waitingCallIDs) size += call.toUtf8().size() + 128;
    for (auto it = replyQuestions.cbegin(); it != replyQuestions.cend(); ++it)
        size += it.key().toUtf8().size() + it->items.size() * 64 + 256;
    return size;
}

std::optional<QDateTime> RolloutReducer::awaitingReplySince() const {
    if (activity.phase != TaskPhase::Waiting || !asynchronousQuestion || turnEnded || untrackedWait
        || !waitingCallIDs.isEmpty() || !activity.turnID || replyQuestions.isEmpty()) return std::nullopt;
    const auto earliest = std::min_element(replyQuestions.cbegin(), replyQuestions.cend(), [](const auto &a, const auto &b) {
        return a.askedAt.referenceSeconds() < b.askedAt.referenceSeconds();
    });
    return earliest->askedAt.date;
}

TaskActivity RolloutReducer::activityAcknowledging(const QList<QuestionReplyReceipt> &receipts,
                                                   const QString &threadID, const QDateTime &now) const {
    if (!awaitingReplySince()) return activity.effective(now);
    const double nowSeconds = PreciseTimestamp{now}.referenceSeconds();
    std::optional<double> latest;
    for (auto it = replyQuestions.cbegin(); it != replyQuestions.cend(); ++it) {
        QSet<int> answered;
        for (const auto &receipt : receipts) {
            const double received = receipt.receivedReferenceSeconds();
            if (receipt.threadID != threadID || receipt.turnID != *activity.turnID
                || received < it->askedAt.referenceSeconds() || received > nowSeconds) continue;
            const auto items = receipt.questionItems.constFind(it.key());
            if (items == receipt.questionItems.cend() || !it->items.contains(*items)) continue;
            answered.unite(*items);
            if (!latest || received > *latest) latest = received;
        }
        if (answered != it->items) return activity.effective(now);
    }
    if (!latest) return activity.effective(now);
    TaskActivity projected = activity;
    projected.setWaitingStartedTimestamp(std::nullopt);
    const auto evidence = activity.lastEventAt ? std::max(activity.lastEventTimestamp()->referenceSeconds(), *latest) : *latest;
    const bool stale = nowSeconds - evidence > 900;
    projected.phase = stale ? TaskPhase::Unknown : TaskPhase::Running;
    projected.detail = stale ? QStringLiteral("已回复，较久未收到后续活动") : QStringLiteral("已回复，等待继续");
    return projected;
}

void RolloutReducer::rememberReplyQuestion(const QJsonObject &payload, const std::optional<PreciseTimestamp> &at) {
    const auto id = payload["call_id"].toString();
    const auto questions = QJsonDocument::fromJson(payload["arguments"].toString().toUtf8()).object()["questions"].toArray();
    if (id.isEmpty() || !at || questions.isEmpty() || questions.size() > 64
        || !std::all_of(questions.begin(), questions.end(), [](const QJsonValue &q) { return q.isObject(); })) {
        untrackedWait = true;
        return;
    }
    if (replyQuestions.contains(id)) return;
    ReplyQuestion question{*at, {}};
    for (int i = 0; i < questions.size(); ++i) question.items.insert(i);
    replyQuestions.insert(id, question);
}

void RolloutReducer::clearReplyQuestions() {
    replyQuestions.clear();
    untrackedWait = turnEnded = false;
}

void RolloutReducer::active(const std::optional<PreciseTimestamp> &at, const QString &detail) {
    if (isFinished(activity.phase) || activity.phase == TaskPhase::Failed) {
        activity.setStartedTimestamp(at);
        activity.turnID.reset();
    }
    activity.phase = TaskPhase::Running;
    activity.detail = detail;
    activity.setWaitingStartedTimestamp(std::nullopt);
}

void RolloutReducer::waiting(const std::optional<PreciseTimestamp> &at, const QString &detail) {
    if (activity.phase != TaskPhase::Waiting) {
        if (isFinished(activity.phase)) {
            activity.setStartedTimestamp(std::nullopt);
            activity.turnID.reset();
        }
        activity.setWaitingStartedTimestamp(at);
    }
    activity.phase = TaskPhase::Waiting;
    activity.detail = detail;
}

void RolloutReducer::recoverTiming(const TaskActivity &recovered) {
    const auto last = activity.lastEventTimestamp(), start = recovered.startedTimestamp();
    if (activity.startedAt || !isActive(activity.phase) || recovered.phase != activity.phase || !last
        || recovered.lastEventTimestamp() != last || !start || !start->date.isValid()
        || start->referenceSeconds() > last->referenceSeconds() || (activity.turnID && recovered.turnID != activity.turnID)
        || (activity.waitingStartedAt && start->referenceSeconds() > activity.waitingStartedTimestamp()->referenceSeconds())) return;
    activity.setStartedTimestamp(start);
    if (!activity.turnID) activity.turnID = recovered.turnID;
}

void RolloutReducer::updateQuota(const QJsonObject &limits, const QDateTime &at) {
    if (auto id = stringValue(limits["limit_id"]); id && *id != "codex") return;
    QList<QuotaWindow> windows;
    for (const auto *key : {"primary", "secondary"}) {
        const auto window = limits[key].toObject();
        const auto used = numericValue(window["used_percent"]);
        if (!used || !std::isfinite(*used)) continue;
        auto minutes = integerValue(window["window_minutes"]);
        if (!minutes) {
            if (const auto seconds = integerValue(window["limit_window_seconds"])) minutes = *seconds / 60;
        }
        if (!minutes || *minutes <= 0 || *minutes > std::numeric_limits<int>::max()) continue;
        std::optional<QDateTime> resets;
        if (const auto seconds = numericValue(window["resets_at"])) {
            const double milliseconds = *seconds * 1000;
            if (milliseconds >= static_cast<double>(std::numeric_limits<qint64>::min())
                && milliseconds < static_cast<double>(std::numeric_limits<qint64>::max()))
                resets = QDateTime::fromMSecsSinceEpoch(qRound64(milliseconds), QTimeZone::UTC);
        }
        windows.append(QuotaWindow{static_cast<int>(*minutes), *used, resets});
    }
    if (!windows.isEmpty()) quota = QuotaSnapshot{at, windows};
}

namespace {
#ifdef Q_OS_WIN
/// 读取已打开的 Windows 句柄；保留卷号、文件序号及 NTFS 的 100 ns 精度。
RolloutFileMetadata handleMetadata(HANDLE handle) {
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(handle, &info))
        throw std::system_error(int(GetLastError()), std::system_category());
    constexpr quint64 ticksPerSecond = 10000000;
    const quint64 ticks = (quint64(info.ftLastWriteTime.dwHighDateTime) << 32) | info.ftLastWriteTime.dwLowDateTime;
    return {info.dwVolumeSerialNumber, (quint64(info.nFileIndexHigh) << 32) | info.nFileIndexLow,
            qint64((quint64(info.nFileSizeHigh) << 32) | info.nFileSizeLow),
            qint64(ticks / ticksPerSecond) - 11644473600LL, qint64(ticks % ticksPerSecond) * 100,
            !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) && GetFileType(handle) == FILE_TYPE_DISK};
}
#else
/// 把 lstat 和 fstat 返回的原始精度保留下来，用于发现等长重写。
RolloutFileMetadata posixMetadata(const struct stat &info) {
#ifdef Q_OS_MACOS
    const auto time = info.st_mtimespec;
#else
    const auto time = info.st_mtim;
#endif
    return {quint64(info.st_dev), quint64(info.st_ino), qint64(info.st_size),
            qint64(time.tv_sec), qint64(time.tv_nsec), S_ISREG(info.st_mode)};
}
#endif
/// 比较路径与已打开句柄是否属于同一卷中的同一个文件。
bool sameFile(const RolloutFileMetadata &a, const RolloutFileMetadata &b) {
    return a.device == b.device && a.inode == b.inode;
}
/// 两次高精度修改时间是否完全相同。
bool sameModification(const RolloutFileMetadata &a, const RolloutFileMetadata &b) {
    return a.seconds == b.seconds && a.nanoseconds == b.nanoseconds;
}
/// QFile 失败时保留系统错误；返回空内容只代表正常 EOF。
void checkFile(bool success) {
    if (!success) throw std::system_error(errno ? errno : EIO, std::generic_category());
}
} // namespace

RolloutFileMetadata RolloutFileMetadata::read(const QString &path) {
#ifdef Q_OS_WIN
    // 读取链接本身，如目标正在写入或计划轮转也不占用独占句柄。
    const auto nativePath = QDir::toNativeSeparators(path).toStdWString();
    HANDLE handle = CreateFileW(nativePath.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (handle == INVALID_HANDLE_VALUE) throw std::system_error(int(GetLastError()), std::system_category());
    struct CloseHandleOnExit {
        HANDLE handle;
        /// 离开元数据读取范围立即释放只读句柄。
        ~CloseHandleOnExit() { CloseHandle(handle); }
    } close{handle};
    auto metadata = handleMetadata(handle);
    // Windows 的 reparse 文件大小通常是 0。符号链接在 POSIX lstat 的大小是目的路径自身的字节数。
    if (!metadata.regular) {
        std::error_code error;
        auto target = std::filesystem::read_symlink(std::filesystem::path(nativePath), error);
        if (!error) metadata.size = qint64(target.u8string().size());
    }
    return metadata;
#else
    struct stat info{};
    if (::lstat(QFile::encodeName(path).constData(), &info) != 0)
        throw std::system_error(errno, std::generic_category());
    return posixMetadata(info);
#endif
}

RolloutFileMetadata RolloutFileMetadata::read(QFile &openFile) {
#ifdef Q_OS_WIN
    const auto handle = reinterpret_cast<HANDLE>(_get_osfhandle(openFile.handle()));
    if (handle == INVALID_HANDLE_VALUE) throw std::system_error(EBADF, std::generic_category());
    return handleMetadata(handle);
#else
    struct stat info{};
    if (::fstat(openFile.handle(), &info) != 0) throw std::system_error(errno, std::generic_category());
    return posixMetadata(info);
#endif
}

IncrementalRollout::IncrementalRollout(int read, int catchUp)
    : maximumRead(std::max(1024, read)), maximumCatchUpRead(std::max(maximumRead, catchUp)) {}

int IncrementalRollout::refresh(const QString &path) {
    const auto current = RolloutFileMetadata::read(path);
    if (observed && sameFile(current, *observed) && current.size == offset && sameModification(current, *observed)) return 0;
    const bool rewritten = observed && (current.size < observed->size ||
                                        (current.size == observed->size && !sameModification(current, *observed)));
    const bool reset = !observed || !sameFile(current, *observed) || current.size < offset || rewritten;
    if (reset) {
        reducer = RolloutReducer{};
        offset = 0;
        pending.clear();
        skippingLongLine = isCaughtUp = false;
        timingRecovery.reset();
    }
    QFile file(path);
    checkFile(file.open(QIODevice::ReadOnly));
    QByteArray prefetched;
    int bytes = 0;
    if (reset && current.size > maximumRead) {
        // 与生成器的紧凑首部匹配时才继续探测；首部和尾部共享同一冷读预算。
        const QByteArray prefix = R"({"ordinal":0,)";
        prefetched = file.read(prefix.size());
        checkFile(file.error() == QFileDevice::NoError);
        if (prefetched == prefix) {
            while (!prefetched.contains('\n') && prefetched.size() < maximumRead) {
                const auto chunk = file.read(std::min<qsizetype>(1024, maximumRead - prefetched.size()));
                checkFile(file.error() == QFileDevice::NoError);
                if (chunk.isEmpty()) break;
                prefetched.append(chunk);
            }
        }
        bytes = int(prefetched.size());
        const auto newline = prefetched.indexOf('\n');
        if (newline < 0 || !RolloutReducer::isAutomaticCopyHeader(QJsonDocument::fromJson(prefetched.left(newline)).object())) {
            const auto tailBudget = maximumRead - bytes;
            offset = current.size - (tailBudget > 0 ? tailBudget : maximumRead);
            skippingLongLine = true;
            reducer.noteUninspectedRecord();
            prefetched.clear();
        }
    }
    checkFile(file.seek(offset + prefetched.size()));
    observed = current;
    const int budget = reset ? maximumRead : maximumCatchUpRead;
    while (offset < current.size && (!prefetched.isEmpty() || bytes < budget)) {
        QByteArray data;
        if (!prefetched.isEmpty()) data.swap(prefetched);
        else {
            const int count = int(std::min<qint64>({maximumRead, budget - bytes, current.size - offset}));
            data = file.read(count);
            checkFile(file.error() == QFileDevice::NoError);
            bytes += int(data.size());
        }
        if (data.isEmpty()) break;
        offset += data.size();
        pending.append(data);
        qsizetype begin = 0, newline;
        while ((newline = pending.indexOf('\n', begin)) >= 0) {
            const auto length = newline - begin;
            if (!skippingLongLine && length > 0) {
                if (length <= maximumRead) reducer.consume(QByteArray::fromRawData(pending.constData() + begin, length));
                else reducer.noteUninspectedRecord();
            }
            skippingLongLine = false;
            begin = newline + 1;
        }
        pending.remove(0, begin);
        if (pending.size() > maximumRead) {
            reducer.noteUninspectedRecord();
            pending.clear();
            skippingLongLine = true;
        }
    }
    isCaughtUp = offset >= current.size;
    reducer.publishImportIfComplete(isCaughtUp && pending.isEmpty() && !skippingLongLine);
    if (reducer.activity.startedAt) timingRecovery.reset();
    return bytes;
}

int IncrementalRollout::recoverTiming(const QString &path, int maximumBytes) {
    if (reducer.activity.startedAt) {
        timingRecovery.reset();
        return 0;
    }
    // 自动副本从头读过所有本机起点，反向回查有机会错误地借用导入时间。
    if (reducer.isAutomaticTeamChatCopy || !isCaughtUp || !isActive(reducer.activity.phase) ||
        (timingRecovery && timingRecovery->isFinished())) return 0;
    const auto initialPath = RolloutFileMetadata::read(path);
    if (!observed || !sameFile(initialPath, *observed) || initialPath.size < offset
        || (initialPath.size == observed->size && !sameModification(initialPath, *observed))) return 0;
    QFile file(path);
    checkFile(file.open(QIODevice::ReadOnly));
    RolloutFileMetadata before;
    try { before = RolloutFileMetadata::read(file); }
    catch (const std::system_error &) { return 0; }
    if (!sameFile(before, *observed) || before.size < offset) return 0;
    if (!timingRecovery) timingRecovery = std::make_shared<RolloutTimingRecovery>(offset);
    else if (timingRecovery.use_count() > 1) timingRecovery = std::make_shared<RolloutTimingRecovery>(*timingRecovery);
    const int bytes = timingRecovery->advance(file, offset, maximumRead, std::max(1024, maximumBytes));
    try {
        const auto finalPath = RolloutFileMetadata::read(path), after = RolloutFileMetadata::read(file);
        if (!sameFile(before, after) || after.size < before.size
            || (after.size == before.size && !sameModification(after, before))
            || !sameFile(finalPath, *observed) || finalPath.size < offset
            || (finalPath.size == initialPath.size && !sameModification(finalPath, initialPath))) {
            timingRecovery.reset();
            return bytes;
        }
    } catch (const std::system_error &) {
        timingRecovery.reset();
        return bytes;
    }
    if (timingRecovery->recovered) reducer.recoverTiming(*timingRecovery->recovered);
    return bytes;
}
} // namespace codextop
