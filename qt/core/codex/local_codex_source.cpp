#include "codex/local_codex_source.h"
#include "codex/compressed_rollout_reader.h"
#include "codex/desktop_reply_receipt_source.h"
#include "codex/rollout_reducer.h"
#include "models/task_roots.h"
#include <QDir>
#include <QTimeZone>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTextBoundaryFinder>
#include <QUuid>
#include <algorithm>
#include <locale.h>
#include <cstdlib>
#ifdef Q_OS_MACOS
#include <xlocale.h>
#endif
#include <cmath>
#include <cstring>
#include <array>
#include <system_error>
#ifdef Q_OS_WIN
#include <qt_windows.h>
#else
#include <sys/stat.h>
#endif

namespace codextop {
namespace {
// 数据源只在当前线程创建命名连接，释放所有查询后移除名称，避免跨快照复用已替换的库。
class Connection {
    QString name = QUuid::createUuid().toString();

  public:
    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", name);
    ~Connection() {
        db.close();
        db = QSqlDatabase{};
        QSqlDatabase::removeDatabase(name);
    }
};
// Qt SQLite 的 exec 会先取第一行；prepare 与首次及后续 step 失败须区分。
template <typename F> void rows(QSqlDatabase &db, const QString &sql, F &&fn) {
    QSqlQuery q(db);
    q.setForwardOnly(true);
    if (!q.prepare(sql))
        throw CodexSourceError::IncompatibleDatabase;
    if (!q.exec())
        throw CodexSourceError::DatabaseUnavailable;
    while (q.next())
        fn(q);
    if (q.lastError().isValid())
        throw CodexSourceError::DatabaseUnavailable;
}
// SQLite 的 C 字符串读取在首个 NUL 截断；列在 SELECT 中以 BLOB 投影以保留原始 UTF-8。
std::optional<QString> textColumn(QSqlQuery &q, int column) {
    if (q.isNull(column))
        return {};
    const auto bytes = q.value(column).toByteArray();
    return QString::fromUtf8(bytes.constData(), std::strlen(bytes.constData()));
}
// Swift Double 支持带符号小数、科学和十六进制浮点；拒绝部分解析的日期文本。
QDateTime epoch(const QString &text) {
    double value = 0;
    if (!text.isEmpty() && text == text.trimmed()) {
        // SQLite 数值按 C locale 产生；不要让系统小数点配置或缺少浮点 from_chars 的标准库改变结果。
        const QByteArray str = text.toLatin1();
        char *end = nullptr;
#ifdef Q_OS_WIN
        static const auto locale = std::unique_ptr<std::remove_pointer_t<_locale_t>, decltype(&_free_locale)>(
            _create_locale(LC_NUMERIC, "C"), &_free_locale);
        if (locale) value = _strtod_l(str.constData(), &end, locale.get());
#else
        static const auto locale = std::unique_ptr<std::remove_pointer_t<locale_t>, decltype(&freelocale)>(
            newlocale(LC_NUMERIC_MASK, "C", nullptr), &freelocale);
        if (locale) value = strtod_l(str.constData(), &end, locale.get());
#endif
        if (end != str.constData() + str.size() || !std::isfinite(value) ||
            std::abs(value) >= double(std::numeric_limits<qint64>::max()) / 1000) value = 0;
    }
    return QDateTime::fromMSecsSinceEpoch(qRound64(value * 1000), QTimeZone::UTC);
}
// 每个 Unicode 换行符单独换成空格，使用字素而非 UTF-16 码元截断。
QString cleanTitle(QString title) {
    static const QRegularExpression lines(QStringLiteral("[\\x{a}-\\x{d}\\x{85}\\x{2028}\\x{2029}]"));
    title.replace(lines, " ");
    title = title.trimmed();
    if (title.isEmpty())
        return QStringLiteral("未命名任务");
    if (title.size() <= 300)
        return title;
    QTextBoundaryFinder finder(QTextBoundaryFinder::Grapheme, title);
    qsizetype at = 0;
    for (int i = 0; i < 300; ++i) {
        at = finder.toNextBoundary();
        if (at < 0)
            return title;
    }
    return title.left(at);
}
std::optional<QString> parentID(const QString &source) {
    if (!source.contains('{'))
        return {};
    auto field = QJsonDocument::fromJson(source.toUtf8())
                     .object().value("subagent")
                     .toObject().value("thread_spawn")
                     .toObject().value("parent_thread_id");
    return field.isString() ? std::optional(field.toString()) : std::nullopt;
}
// Foundation 的相对 URL 会解析 . 与 ..，绝对 cwd 则只取原路径的末级名称。
QString projectName(QString path) {
    path = QDir::fromNativeSeparators(path);
    if (QDir::isRelativePath(path))
        path = QDir::cleanPath(QDir::current().absoluteFilePath(path));
    while (path.size() > 1 && path.endsWith('/'))
        path.chop(1);
    if (QDir(path).isRoot())
        return path;
    return path.section('/', -1);
}
// 非现存路径取规范化词法名称，现存链接按实际目标校验。
QString normalized(const QString &path) {
    const auto absolute = QDir::cleanPath(QDir::current().absoluteFilePath(QDir::fromNativeSeparators(path)));
    const auto canonical = QFileInfo(absolute).canonicalFilePath();
#ifdef Q_OS_WIN
    // Windows Qt 也会返回悬空链接声明的目的地。只有真实存在的目标才能替换原记录路径。
    if (!canonical.isEmpty() && canonical != absolute && !QFileInfo::exists(canonical))
        return absolute;
#endif
    return canonical.isEmpty() ? absolute : canonical;
}
bool inside(const QString &root, const QString &path) {
    const QString prefix = root.endsWith('/') ? root : root + '/';
    // 规范路径均从文件系统取得。同一 NTFS 目录也可能启用大小写敏感，大小写不确定时禁止越界。
    return path.startsWith(prefix);
}
struct Location {
    QString path;
    std::errc error{};
};

// Windows 可以绕过父目录遍历检查而收到 FILE_NOT_FOUND。只有能列出最近的现存父目录，
// 才把此结果视为已证实的缺失；不读取目录列表或文件内容。
std::errc missingError(const QString &path) {
#ifdef Q_OS_WIN
    QString parent = QFileInfo(path).absolutePath();
    while (!parent.isEmpty()) {
        const auto native = QDir::toNativeSeparators(parent).toStdWString();
        HANDLE directory = CreateFileW(native.c_str(), FILE_LIST_DIRECTORY,
                                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                                       OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
        if (directory != INVALID_HANDLE_VALUE) {
            CloseHandle(directory);
            break;
        }
        const DWORD error = GetLastError();
        if (error == ERROR_ACCESS_DENIED || error == ERROR_PRIVILEGE_NOT_HELD)
            return std::errc::permission_denied;
        if (error != ERROR_PATH_NOT_FOUND && error != ERROR_FILE_NOT_FOUND)
            break;
        const QString next = QFileInfo(parent).absolutePath();
        if (next == parent)
            break;
        parent = next;
    }
#else
    Q_UNUSED(path);
#endif
    return std::errc::no_such_file_or_directory;
}
Location inspect(QString path) {
    try {
        if (!RolloutFileMetadata::read(path).regular)
            return {path, std::errc::invalid_argument};
        return {path, {}};
    } catch (const std::system_error &e) {
        // Windows 系统错误码经 default_error_condition 映射到可移植的类别。
        if (e.code() == std::errc::no_such_file_or_directory)
            return {path, missingError(path)};
        return {path, static_cast<std::errc>(e.code().default_error_condition().value())};
    }
}
struct Parent {
    QString path;
#ifdef Q_OS_WIN
    // 同一快照内同目录所有缺失的任务和压缩兄弟文件只需探测一次 ACL。
    std::optional<std::errc> missingLeafError;
#else
    quint64 dev = 0, ino = 0, mode = 0;
    qint64 mtime = 0, mtimeNs = 0, ctime = 0, ctimeNs = 0;
#endif
    bool operator==(const Parent &) const = default;
};
// POSIX 的目录变化时间用于撤销缺失证据；Windows 每轮检查文件，不信任可恢复的目录 mtime。
std::optional<Parent> resolveParent(const QString &parent) {
    auto path = QFileInfo(parent).canonicalFilePath();
    if (path.isEmpty())
        return {};
    Parent p;
    p.path = path;
#ifndef Q_OS_WIN
    struct stat s{};
    if (::stat(QFile::encodeName(path).constData(), &s) || !S_ISDIR(s.st_mode))
        return {};
    p.dev = s.st_dev;
    p.ino = s.st_ino;
    p.mode = s.st_mode;
#ifdef Q_OS_MACOS
    p.mtime = s.st_mtimespec.tv_sec;
    p.mtimeNs = s.st_mtimespec.tv_nsec;
    p.ctime = s.st_ctimespec.tv_sec;
    p.ctimeNs = s.st_ctimespec.tv_nsec;
#else
    p.mtime = s.st_mtim.tv_sec;
    p.mtimeNs = s.st_mtim.tv_nsec;
    p.ctime = s.st_ctim.tv_sec;
    p.ctimeNs = s.st_ctim.tv_nsec;
#endif
#else
    if (!QFileInfo(path).isDir())
        return {};
#endif
    return p;
}
TaskActivity unknown(const QString &detail) {
    TaskActivity result;
    result.detail = detail;
    return result;
}
} // namespace

struct LocalCodexSource::Impl {
    QString root;
    QHash<QString, IncrementalRollout> tails;
    qsizetype cursor = 0;
    CompressedRolloutReader compressed;
    std::shared_ptr<DesktopReplyReceiptSource> replies;
    QHash<QString, QuestionReplyReceipt> received;
    struct Labels {
        QString rawTitle;
        std::optional<QString> source;
        QString title;
        std::optional<QString> parent;
        qsizetype bytes;
    };
    QHash<QString, Labels> labels;
    qsizetype labelBytes = 0;
    struct PathText {
        QString parent, leaf, sibling;
    };
    QHash<QString, PathText> texts;
    qsizetype textBytes = 0;
    QHash<QString, Parent> missing;
    qsizetype missingBytes = 0;

    Impl(QString p, QString cache, std::shared_ptr<DesktopReplyReceiptSource> receipt)
        : root(normalized(p)), compressed(qint64(1) << 46, std::move(cache)),
          replies(receipt ? std::move(receipt) : std::make_shared<DesktopReplyReceiptSource>(root)) {}
    // 只缓存文本拆分。不得将某次权限、文件存在性或链接解析结果当成长期有效。
    std::optional<PathText> pathText(const QString &path) {
        if (auto i = texts.constFind(path); i != texts.cend())
            return *i;
        if (!QDir::isAbsolutePath(path) || path.endsWith('/') || path.endsWith("/.") || path.endsWith("/..") ||
            path.contains("/../") || path.contains("/./"))
            return {};
        const auto pos = path.lastIndexOf('/');
        if (pos < 0)
            return {};
        auto dir = path.left(pos);
        if (dir.isEmpty())
            dir = "/";
#ifdef Q_OS_WIN
        if (dir.size() == 2 && dir[1] == ':')
            dir += '/';
#endif
        PathText v{dir, path.mid(pos + 1), path + ".zst"};
        auto raw = path.toUtf8().size();
        auto total = raw + v.parent.toUtf8().size() + v.leaf.toUtf8().size() + v.sibling.toUtf8().size();
        if (raw <= 1024 && texts.size() < 4096 && total <= (1 << 20) - textBytes) {
            texts.insert(path, v);
            textBytes += total;
        }
        return v;
    }
    // 对同轮同目录只做一次规范解析。末级链接仍逐项检查，包括悬空链接和目录外指向。
    Location location(QString path, QHash<QString, Parent> &parents) {
        path = QDir::fromNativeSeparators(path);
        auto text = pathText(path);
        if (!text)
            return inspect(normalized(path));
        if (!parents.contains(text->parent)) {
            auto p = resolveParent(text->parent);
            if (!p)
                return inspect(normalized(path));
            parents.insert(text->parent, *p);
        }
        Parent &p = parents.find(text->parent).value();
        QString candidate = QDir::cleanPath(QDir(p.path).filePath(text->leaf));
#ifndef Q_OS_WIN
        if (auto i = missing.find(candidate); i != missing.end()) {
            if (*i == p)
                return {candidate, std::errc::no_such_file_or_directory};
            missingBytes -= candidate.toUtf8().size();
            missing.erase(i);
        }
#endif
        try {
            auto info = RolloutFileMetadata::read(candidate);
            if (info.regular)
                return {candidate, {}};
        } catch (const std::system_error &e) {
            if (e.code() == std::errc::no_such_file_or_directory) {
#ifdef Q_OS_WIN
                if (!p.missingLeafError)
                    p.missingLeafError = missingError(candidate);
                return {candidate, *p.missingLeafError};
#else
                const auto bytes = candidate.toUtf8().size();
                if (missing.size() < 4096 && bytes <= 1024 && bytes <= (1 << 20) - missingBytes) {
                    missing.insert(candidate, p);
                    missingBytes += bytes;
                }
                return {candidate, std::errc::no_such_file_or_directory};
#endif
            }
        }
        return inspect(normalized(path));
    }
    QString databasePath() const {
        static const QRegularExpression re(R"(^state_([+-]?[0-9]+)\.sqlite$)");
        std::optional<qint64> max;
        QString found;
        for (const auto &file : QDir(root).entryList(QDir::AllEntries | QDir::NoDotAndDotDot)) {
            const auto match = re.match(file);
            if (!match.hasMatch())
                continue;
            bool ok = false;
            const auto number = match.captured(1).toLongLong(&ok);
            if (ok && (!max || number > *max)) {
                max = number;
                found = QDir(root).filePath(file);
            }
        }
        if (!max)
            throw CodexSourceError::MissingDatabase;
        return found;
    }
    Labels label(const QString &id, const QString &title, const std::optional<QString> &source) {
        if (auto i = labels.find(id); i != labels.end()) {
            if (i->rawTitle == title && i->source == source)
                return *i;
            labelBytes -= i->bytes;
            labels.erase(i);
        }
        const auto raw = title.toUtf8().size() + source.value_or(QString{}).toUtf8().size();
        Labels v{title, source, cleanTitle(title), parentID(source.value_or(QString{})), 0};
        v.bytes = id.toUtf8().size() + raw + v.title.toUtf8().size() + v.parent.value_or(QString{}).toUtf8().size();
        if (raw <= 4096 && labels.size() < 2048 && v.bytes <= (1 << 20) - labelBytes) {
            labels.insert(id, v);
            labelBytes += v.bytes;
        }
        return v;
    }
};
LocalCodexSource::LocalCodexSource(QString root, QString compressedCachePath,
                                   std::shared_ptr<DesktopReplyReceiptSource> receiptSource)
    : d(std::make_unique<Impl>(std::move(root), std::move(compressedCachePath), std::move(receiptSource))) {}
LocalCodexSource::~LocalCodexSource() = default;
const QString &LocalCodexSource::root() const {
    return d->root;
}
QString LocalCodexSource::defaultRoot() {
    const auto override = qEnvironmentVariable("CODEX_HOME");
    return override.isEmpty() ? QDir::home().filePath(".codex") : override;
}
// 每轮重开当前最高版本的数据库。正式 SQL 决定顺序，只对已关注根及其后代解压和回查。
SourceSnapshot LocalCodexSource::snapshot(QDateTime now, const QSet<QString> &roots,
                                          const std::optional<QSet<QString>> &monitoredRootIDs) {
    const QString databasePath = d->databasePath();
    Connection connection;
    auto &db = connection.db;
    db.setDatabaseName(databasePath);
    db.setConnectOptions("QSQLITE_OPEN_READONLY;QSQLITE_BUSY_TIMEOUT=300");
    if (!db.open())
        throw CodexSourceError::DatabaseUnavailable;
    QSet<QString> columns;
    rows(db, "PRAGMA table_info(threads)", [&](QSqlQuery &q) { columns.insert(q.value(1).toString()); });
    if (!columns.contains(QSet<QString>{"id", "title", "cwd", "rollout_path", "created_at", "updated_at", "archived"}))
        throw CodexSourceError::IncompatibleDatabase;
    const QString title = columns.contains("name") ? "COALESCE(NULLIF(name,''),title)" : "title";
    const QString source = columns.contains("source") ? "source" : "''";
    const QStringList fields{"id", title, "cwd", "rollout_path", "created_at", "updated_at", source};
    QStringList projection;
    for (const auto &field : fields)
        projection.append("CAST(" + field + " AS BLOB)");
    using Row = std::array<std::optional<QString>, 7>;
    QList<Row> records;
    rows(db, "SELECT " + projection.join(',') + " FROM threads WHERE archived=0 ORDER BY updated_at DESC",
         [&](QSqlQuery &q) {
             Row row;
             for (int i = 0; i < 7; ++i)
                 row[i] = textColumn(q, i);
             records.append(std::move(row));
         });
    bool edges = false;
    rows(db, "SELECT name FROM sqlite_master WHERE type='table'",
         [&](QSqlQuery &q) { edges |= q.value(0).toString() == "thread_spawn_edges"; });
    QHash<QString, QString> explicitParents;
    if (edges) {
        try {
            rows(db, "SELECT CAST(parent_thread_id AS BLOB),CAST(child_thread_id AS BLOB) FROM thread_spawn_edges",
                 [&](QSqlQuery &q) {
                     const auto parent = textColumn(q, 0), child = textColumn(q, 1);
                     if (parent && child)
                         explicitParents[*child] = *parent;
                 });
        } catch (CodexSourceError) {
            explicitParents.clear();
        }
    }
    SourceSnapshot snapshot;
    snapshot.observedAt = now;
    auto &tasks = snapshot.tasks;
    QHash<QString, QString> projects, compressedCandidates;
    QHash<QString, Parent> resolvedParents;
    QSet<QString> failures;
    auto addQuota = [&](const std::optional<QuotaSnapshot> &q) {
        if (q && (!snapshot.quota || q->observedAt > snapshot.quota->observedAt))
            snapshot.quota = q;
    };
    for (const Row &row : records) {
        if (!row[0] || !row[3])
            continue;
        const auto &id = *row[0];
        const auto &path = *row[3];
        const auto location = d->location(path, resolvedParents);
        const auto parent = explicitParents.constFind(id);
        const auto label = d->label(id, row[1].value_or(""), parent == explicitParents.cend() ? row[6] : std::nullopt);
        const auto cwd = row[2].value_or("");
        if (!projects.contains(cwd))
            projects.insert(cwd, projectName(cwd));
        CodexTask task;
        task.id = id;
        task.title = label.title;
        task.parentID = parent == explicitParents.cend() ? label.parent : std::optional(*parent);
        task.project = projects.value(cwd);
        task.rolloutPath = location.path;
        task.createdAt = epoch(row[4].value_or(""));
        task.updatedAt = epoch(row[5].value_or(""));
        auto fail = [&](const QString &why) {
            task.activity = unknown(why);
            failures.insert(id);
            d->tails.remove(id);
            d->compressed.forget(id);
        };
        if (!inside(d->root, location.path)) {
            task.activity = unknown(QStringLiteral("记录位于数据目录之外，未读取"));
            failures.insert(id);
        } else if (location.error == std::errc::invalid_argument) {
            // 尚未解析为普通文件的悬空链接/目录不可打开，以免链接在检查后转向。
            fail(QStringLiteral("暂时无法读取任务记录"));
        } else {
            const bool missing = location.error == std::errc::no_such_file_or_directory;
            if (missing) {
                const auto sibling = d->location(path + ".zst", resolvedParents);
                if (!inside(d->root, sibling.path)) {
                    fail(QStringLiteral("记录位于数据目录之外，未读取"));
                    tasks.append(std::move(task));
                    continue;
                }
                if (sibling.error == std::errc::permission_denied ||
                    sibling.error == std::errc::operation_not_permitted) {
                    fail(QStringLiteral("无权读取任务记录"));
                    tasks.append(std::move(task));
                    continue;
                }
                if (sibling.error == std::errc{}) {
                    compressedCandidates[id] = sibling.path;
                    d->tails.remove(id);
                    task.activity = unknown(QStringLiteral("历史记录已压缩，尚未读取"));
                    tasks.append(std::move(task));
                    continue;
                }
            }
            d->compressed.forget(id);
            try {
                auto &tail = d->tails[id];
                snapshot.bytesRead += tail.refresh(location.path);
                task.activity = tail.reducer.activity.effective(now);
                if (!tail.isCaughtUp) {
                    task.activity.phase = TaskPhase::Unknown;
                    task.activity.detail = QStringLiteral("正在同步任务活动…");
                    // 未读部分可能包含本机续聊，追平前不能按导入状态移除关注。
                    task.activity.isTeamChatImport = false;
                }
                addQuota(tail.reducer.quota);
            } catch (const std::system_error &e) {
                bool permission = e.code() == std::errc::permission_denied ||
                                  e.code() == std::errc::operation_not_permitted ||
                                  location.error == std::errc::permission_denied ||
                                  location.error == std::errc::operation_not_permitted;
                fail(permission ? QStringLiteral("无权读取任务记录")
                     : missing  ? QStringLiteral("任务记录缺失")
                                : QStringLiteral("暂时无法读取任务记录"));
            }
        }
        tasks.append(std::move(task));
    }
    const auto taskRoots = resolveRootIDs(tasks);
    auto normalizedIDs = [](const QSet<QString> &rawIDs) {
        QSet<QString> result;
        for (const auto &id : rawIDs)
            result.insert(taskIDKey(id));
        return result;
    };
    const auto timingRoots = normalizedIDs(roots);
    const auto monitored = monitoredRootIDs ? normalizedIDs(*monitoredRootIDs) : timingRoots;
    QSet<QString> selected, compressedIDs, ids;
    QList<qsizetype> ordered, recover;
    QHash<QString, QDateTime> pending;
    for (qsizetype i = 0; i < tasks.size(); ++i) {
        const auto &t = tasks.at(i);
        ids.insert(t.id);
        const auto id = taskIDKey(t.id), rootID = taskRoots.value(id, id);
        if (monitored.contains(rootID)) {
            selected.insert(t.id);
            if (compressedCandidates.contains(t.id)) {
                compressedIDs.insert(t.id);
                ordered.append(i);
            }
        }
        if (timingRoots.contains(rootID)) {
            const auto tail = d->tails.constFind(t.id);
            if (tail != d->tails.cend() && !tail->reducer.activity.startedAt && isActive(tail->reducer.activity.phase))
                recover.append(i);
        }
    }
    d->compressed.beginCycle(compressedIDs);
    std::stable_sort(ordered.begin(), ordered.end(), [&](qsizetype a, qsizetype b) {
        bool ar = monitored.contains(taskIDKey(tasks.at(a).id)), br = monitored.contains(taskIDKey(tasks.at(b).id));
        return ar != br ? ar : tasks.at(a).updatedAt > tasks.at(b).updatedAt;
    });
    int reading = 0, limited = 0;
    for (auto i : ordered) {
        auto &t = tasks[i];
        auto result = d->compressed.read(t.id, compressedCandidates.value(t.id), now);
        t.activity = result.activity;
        snapshot.bytesRead += result.bytes;
        addQuota(result.quota);
        switch (result.category) {
        case CompressedRolloutReader::Category::Reading:
            ++reading;
            break;
        case CompressedRolloutReader::Category::Limited:
            ++limited;
            break;
        case CompressedRolloutReader::Category::Unavailable:
            failures.insert(t.id);
            break;
        case CompressedRolloutReader::Category::Ready:
            break;
        }
    }
    // 可选回查的失败不得覆盖正式状态，每轮合计 8 MiB、单任务 4 MiB，轮转首候选防止饥饿。
    int remaining = 8 * 1024 * 1024;
    const auto first = recover.isEmpty() ? 0 : d->cursor % recover.size();
    for (qsizetype n = 0; n < recover.size() && remaining >= 1024; ++n) {
        auto &t = tasks[recover.at((first + n) % recover.size())];
        auto &tail = d->tails[t.id];
        try {
            const int bytes = tail.recoverTiming(t.rolloutPath, std::min(4 * 1024 * 1024, remaining));
            snapshot.bytesRead += bytes;
            remaining -= bytes;
        } catch (const std::system_error &) {
        }
        d->cursor = (first + n + 1) % recover.size();
        if (tail.isCaughtUp)
            t.activity = tail.reducer.activity.effective(now);
    }
    for (const auto &t : std::as_const(tasks)) {
        const auto id = taskIDKey(t.id);
        if (!timingRoots.contains(taskRoots.value(id, id)) || t.activity.phase != TaskPhase::Waiting)
            continue;
        auto i = d->tails.constFind(t.id);
        auto since = i != d->tails.cend() && i->isCaughtUp ? i->reducer.awaitingReplySince() : std::nullopt;
        if (!since)
            since = d->compressed.awaitingReplySince(t.id);
        if (since)
            pending.insert(t.id, *since);
    }
    for (auto it = d->received.begin(); it != d->received.end();) {
        auto since = pending.constFind(it->threadID);
        if (since == pending.cend() || it->receivedAt < *since)
            it = d->received.erase(it);
        else
            ++it;
    }
    if (!pending.isEmpty()) {
        const auto known = d->received.values();
        QHash<QString, QDateTime> need;
        for (auto i = pending.cbegin(); i != pending.cend(); ++i) {
            auto tail = d->tails.constFind(i.key());
            auto projected = tail == d->tails.cend()
                                 ? d->compressed.projectedActivity(i.key(), known, now)
                                 : std::optional(tail->reducer.activityAcknowledging(known, i.key(), now));
            if (projected && projected->phase == TaskPhase::Waiting)
                need.insert(i.key(), *i);
        }
        QHash<QString, QString> rolloutPaths;
#ifdef Q_OS_WIN
        // Windows 的桌面端点跨数据目录共享，只接受这轮已从本地库确认的记录。
        for (const auto &task : std::as_const(tasks))
            if (need.contains(task.id)) rolloutPaths.insert(task.id, task.rolloutPath);
#endif
        for (const auto &reply : d->replies->receipts(need, now, {}, rolloutPaths))
            if (pending.contains(reply.threadID) && reply.receivedAt >= pending.value(reply.threadID))
                d->received.insert(reply.threadID + ':' + reply.clientID, reply);
        if (d->received.size() > 1024) {
            auto keys = d->received.keys();
            std::sort(keys.begin(), keys.end(), [&](const auto &a, const auto &b) {
                const double x = d->received.constFind(a)->receivedReferenceSeconds();
                const double y = d->received.constFind(b)->receivedReferenceSeconds();
                return x == y ? a < b : x > y;
            });
            for (qsizetype i = 1024; i < keys.size(); ++i)
                d->received.remove(keys.at(i));
        }
        const auto receipts = d->received.values();
        for (auto &t : tasks)
            if (pending.contains(t.id)) {
                auto tail = d->tails.find(t.id);
                if (tail == d->tails.end()) {
                    if (compressedCandidates.contains(t.id)) {
                        auto result = d->compressed.read(t.id, compressedCandidates.value(t.id), now);
                        t.activity =
                            result.category == CompressedRolloutReader::Category::Ready
                                ? d->compressed.projectedActivity(t.id, receipts, now).value_or(result.activity)
                                : result.activity;
                        snapshot.bytesRead += result.bytes;
                    }
                    continue;
                }
                // IPC 等待期间可能已出现更可靠的正式记录，重读后再关联已收回执。
                try {
                    snapshot.bytesRead += tail->refresh(t.rolloutPath);
                    t.activity = tail->isCaughtUp ? tail->reducer.activityAcknowledging(receipts, t.id, now)
                                                  : unknown(QStringLiteral("正在同步任务活动…"));
                } catch (const std::system_error &) {
                    t.activity = unknown(QStringLiteral("暂时无法读取任务记录"));
                    d->tails.erase(tail);
                    failures.insert(t.id);
                }
            }
    }
    for (auto it = d->tails.begin(); it != d->tails.end();) {
        if (ids.contains(it.key()))
            ++it;
        else
            it = d->tails.erase(it);
    }
    for (auto it = d->labels.begin(); it != d->labels.end();) {
        if (ids.contains(it.key()))
            ++it;
        else {
            d->labelBytes -= it->bytes;
            it = d->labels.erase(it);
        }
    }
    const bool all = !monitoredRootIDs && roots.isEmpty();
    const auto failed = all ? failures.size() : failures.intersect(selected).size();
    QStringList reasons;
    if (failed)
        reasons << QStringLiteral("%1 条记录不可用").arg(failed);
    if (reading)
        reasons << QStringLiteral("%1 条读取中").arg(reading);
    if (limited)
        reasons << QStringLiteral("%1 条受限").arg(limited);
    if (!reasons.isEmpty())
        snapshot.warning =
            (all ? QStringLiteral("记录检查：") : QStringLiteral("关注范围：")) + reasons.join(QStringLiteral("，"));
    return snapshot;
}
} // namespace codextop
