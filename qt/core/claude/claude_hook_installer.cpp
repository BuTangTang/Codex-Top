#include "claude/claude_hook_installer.h"
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <algorithm>
#include <optional>
#include <vector>

namespace codextop::ClaudeHookInstaller {
namespace {
const QByteArray matcher = "permission_prompt|elicitation_dialog";
/// QJsonDocument 负责语法验证和 Unicode 转义。只解出字符串，改写时仍用原文。
QByteArray quoted(const QString &value) {
    const auto full = QJsonDocument(QJsonArray{value}).toJson(QJsonDocument::Compact);
    return full.mid(1, full.size() - 2);
}
/// 读取已有内容，缺失与空文件分开处理。
std::optional<QByteArray> contents(const QString &path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        if (QFileInfo::exists(path))
            throw Failure::WriteFailed;
        return {};
    }
    const auto result = file.readAll();
    if (file.error() != QFile::NoError)
        throw Failure::WriteFailed;
    return result;
}
/// 提交同目录原子替换。提交失败保留原文件。
void save(const QString &path, const QByteArray &data) {
    if (!QDir().mkpath(QFileInfo(path).absolutePath()))
        throw Failure::WriteFailed;
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(data) != data.size() || !file.commit())
        throw Failure::WriteFailed;
}
/// 每次先备份原始字节，仅保留最近三份。毫秒相同则选下一个可用编号。
void backup(const QString &dir, const QByteArray &data) {
    const QDir folder(dir);
    qint64 stamp = QDateTime::currentMSecsSinceEpoch();
    QString file;
    do {
        file = folder.filePath("settings-" + QString::number(stamp++) + ".json");
    } while (QFileInfo::exists(file));
    save(file, data);
    const auto names = folder.entryList({"settings-*"}, QDir::Files, QDir::Name);
    for (qsizetype i = 0; i < names.size() - 3; ++i)
        QFile::remove(folder.filePath(names.at(i)));
}
/// 写入前验证原文件仍与本轮基线一致，保存其原有权限。
void writeChecked(const QString &path, const QByteArray &data, const std::optional<QByteArray> &original,
                  const QString &backups) {
    if (contents(path) != original)
        throw Failure::ChangedWhileEditing;
    const auto permissions = QFileInfo(path).permissions();
    if (original)
        backup(backups, *original);
    save(path, data);
#ifndef Q_OS_WIN
    if (original)
        QFile::setPermissions(path, permissions);
#else
    Q_UNUSED(permissions);
#endif
}
struct Span {
    qsizetype begin, end;
};
struct Node {
    enum Kind { Scalar, Object, Array } kind;
    qsizetype start, end;
    // 各直接子项保存成员的键和起点，以及值的原始范围；数组元素没有键。
    QString name;
    qsizetype memberStart;
    std::vector<Node> children;
    /// 取第一个同名键，保留原生编辑范围规则。
    const Node *member(const QString &key) const {
        if (kind == Object)
            for (const auto &c : children)
                if (c.name == key)
                    return &c;
        return nullptr;
    }
};
/// JSON 允许的布局空白。其他字符仍属于原字段。
bool blank(char c) { return c == ' ' || c == '\n' || c == '\r' || c == '\t'; }
bool blankSettings(const QByteArray &bytes) { return std::all_of(bytes.cbegin(), bytes.cend(), blank); }
/// 已校验原文后只记录范围，以便插删时保留其余字节。
class Parser {
    const QByteArray &bytes;
    qsizetype pos = 0;
    void skip() {
        while (pos < bytes.size() && blank(bytes[pos]))
            ++pos;
    }
    void take(char value) {
        if (pos >= bytes.size() || bytes[pos++] != value)
            throw Failure::InvalidJSON;
    }
    void string() {
        take('"');
        while (pos < bytes.size()) {
            char c = bytes[pos++];
            if (c == '"')
                return;
            if (c == '\\')
                ++pos;
        }
        throw Failure::InvalidJSON;
    }
    Node value() {
        skip();
        if (pos >= bytes.size())
            throw Failure::InvalidJSON;
        const auto start = pos;
        char c = bytes[pos];
        Node node{c == '{' ? Node::Object : c == '[' ? Node::Array : Node::Scalar, start, 0, {}, start, {}};
        if (node.kind == Node::Scalar) {
            if (c == '"')
                string();
            else
                while (pos < bytes.size() && !blank(bytes[pos]) && bytes[pos] != ',' && bytes[pos] != '}' &&
                       bytes[pos] != ']')
                    ++pos;
            node.end = pos;
            return node;
        }
        ++pos;
        skip();
        char close = node.kind == Node::Object ? '}' : ']';
        while (pos < bytes.size() && bytes[pos] != close) {
            const auto childStart = pos;
            QString key;
            if (node.kind == Node::Object) {
                string();
                key = QJsonDocument::fromJson('[' + bytes.mid(childStart, pos - childStart) + ']')
                          .array()
                          .at(0)
                          .toString();
                skip();
                take(':');
            }
            auto child = value();
            child.name = key;
            child.memberStart = childStart;
            node.children.push_back(std::move(child));
            skip();
            if (pos < bytes.size() && bytes[pos] == close)
                break;
            take(',');
            skip();
        }
        take(close);
        node.end = pos;
        return node;
    }

  public:
    explicit Parser(const QByteArray &input) : bytes(input) {}
    /// 根必须是对象。语法不合法时拒绝修改。
    Node parse() {
        if (!QJsonDocument::fromJson(bytes).isObject())
            throw Failure::InvalidJSON;
        if (bytes.startsWith("\xef\xbb\xbf"))
            pos = 3;
        return value();
    }
};
/// 查找当前行的缩进，延续用户写下的空格或制表符。
QByteArray indent(const QByteArray &data, qsizetype at) {
    while (at > 0 && data[at - 1] != '\n')
        --at;
    auto end = at;
    while (end < data.size() && (data[end] == ' ' || data[end] == '\t'))
        ++end;
    return data.mid(at, end - at);
}
/// 在容器的最后一项后插入；空容器只替换括号内原有空白。
void insert(QByteArray &data, const Node &container, const QByteArray &text, const QByteArray &indentation) {
    if (!container.children.empty())
        data.insert(container.children.back().end, ",\n" + indentation + text);
    else
        data.replace(container.start + 1, container.end - container.start - 2,
                     "\n" + indentation + text + '\n' + indentation.chopped(2));
}
/// 删去一项和旁边一个逗号，周围其他成员的空白与顺序保持原样。
void eraseSpan(QByteArray &data, Span range) {
    auto [lower, upper] = range;
    auto back = lower - 1;
    while (back >= 0 && blank(data[back]))
        --back;
    if (back >= 0 && data[back] == ',')
        lower = back;
    else {
        auto forward = upper;
        while (forward < data.size() && blank(data[forward]))
            ++forward;
        if (forward < data.size() && data[forward] == ',') {
            ++forward;
            while (forward < data.size() && blank(data[forward]))
                ++forward;
            upper = forward;
        } else {
            lower = back + 1;
            upper = forward;
        }
    }
    data.remove(lower, upper - lower);
}
/// 原生版和 Qt 版均使用独立的通知匹配项。路径变化时也能识别以前安装的助手。
QList<Span> ownEntries(const Node &root, const QByteArray &bytes, const QString &helper, bool any = false) {
    QList<Span> spans;
    const auto hooks = root.member("hooks");
    const auto list = hooks ? hooks->member("Notification") : nullptr;
    if (!list || list->kind != Node::Array)
        return spans;
    const auto exact = command(helper);
    const auto name = QFileInfo(helper).fileName();
    for (const auto &e : list->children) {
        auto entry = QJsonDocument::fromJson(bytes.mid(e.start, e.end - e.start)).object();
        for (const auto &value : entry.value("hooks").toArray()) {
            const auto current = value.toObject().value("command").toString();
            if (current.isEmpty())
                continue;
            const auto forward = QDir::fromNativeSeparators(current);
            if (current == exact ||
                (any && (forward.contains("/Codex Top/bin/" + name) || forward.contains("/Codex Top Qt/bin/" + name) ||
                         forward.contains(QDir::fromNativeSeparators(helper))))) {
                spans.append({e.memberStart, e.end});
                break;
            }
        }
    }
    return spans;
}
/// 生成本程序独立的匹配项，仅插入这一段原文。
QByteArray entry(const QString &helper, const QByteArray &i) {
    QByteArray text = "{\n" + i + "  \"matcher\": " + quoted(QString::fromLatin1(matcher)) + ",\n" + i +
                      "  \"hooks\": [\n" + i + "    {\n" + i + "      \"type\": \"command\",\n";
#ifdef Q_OS_WIN
    // 明确指定 PowerShell，行为不随开发机是否安装 Git Bash 改变。
    text += i + "      \"shell\": \"powershell\",\n";
#endif
    return text + i + "      \"command\": " + quoted(command(helper)) + ",\n" + i + "      \"async\": true,\n" + i +
           "      \"timeout\": 5\n" + i + "    }\n" + i + "  ]\n" + i + "}";
}
QByteArray listText(const QString &helper, const QByteArray &i) {
    return "[\n" + i + "  " + entry(helper, i + "  ") + '\n' + i + "]";
}
QByteArray hooksText(const QString &helper, const QByteArray &i) {
    return "{\n" + i + "  \"Notification\": " + listText(helper, i + "  ") + '\n' + i + "}";
}
} // namespace

QString command(const QString &helper) {
    QString path = QDir::toNativeSeparators(helper);
#ifdef Q_OS_WIN
    path.replace('\'', "''");
    return "$h='" + path + "'; if (Test-Path -LiteralPath $h -PathType Leaf) { & $h }; exit 0";
#else
    // 保留原生命令的形式，并将有 shell 含义的路径字符全部按字面值传递。
    path.replace('\\', "\\\\");
    path.replace('"', "\\\"");
    path.replace('$', "\\$");
    path.replace('`', "\\`");
    return "h=\"" + path + "\"; [ -x \"$h\" ] && \"$h\"; exit 0";
#endif
}
std::optional<bool> isInstalled(const QString &settings, const QString &helper) {
    try {
        const auto data = contents(settings);
        if (!data || blankSettings(*data))
            return false;
        return !ownEntries(Parser(*data).parse(), *data, helper).isEmpty();
    } catch (Failure) {
        return std::nullopt;
    }
}
void install(const QString &settings, const QString &helper, const QString &backups) {
    const auto original = contents(settings);
    if (!original || blankSettings(*original)) {
        const auto data = "{\n  \"hooks\": " + hooksText(helper, "  ") + "\n}\n";
        writeChecked(settings, data, original, backups);
        save(QDir(backups).filePath("created-settings"), {});
        return;
    }
    auto data = *original;
    auto root = Parser(data).parse();
    if (!ownEntries(root, data, helper).isEmpty())
        return;
    const auto old = ownEntries(root, data, helper, true);
    for (auto i = old.crbegin(); i != old.crend(); ++i)
        eraseSpan(data, *i);
    root = Parser(data).parse();
    const auto indentation = indent(data, root.start) + "  ";
    const auto hooks = root.member("hooks");
    if (hooks && hooks->kind == Node::Object) {
        const auto list = hooks->member("Notification");
        if (list && list->kind == Node::Array) {
            const auto inner = indent(data, hooks->start) + "    ";
            insert(data, *list, entry(helper, inner), inner);
        } else {
            const auto inner = indent(data, hooks->start) + "  ";
            insert(data, *hooks, "\"Notification\": " + listText(helper, inner), inner);
        }
    } else
        insert(data, root, "\"hooks\": " + hooksText(helper, indentation), indentation);
    Parser(data).parse();
    writeChecked(settings, data, original, backups);
}
void remove(const QString &settings, const QString &helper, const QString &backups) {
    const auto original = contents(settings);
    if (!original || blankSettings(*original))
        return;
    auto data = *original;
    auto spans = ownEntries(Parser(data).parse(), data, helper, true);
    if (spans.isEmpty())
        return;
    for (auto i = spans.crbegin(); i != spans.crend(); ++i)
        eraseSpan(data, *i);
    auto root = Parser(data).parse();
    if (auto hooks = root.member("hooks")) {
        if (auto list = hooks->member("Notification"); list && list->children.empty()) {
            eraseSpan(data, {list->memberStart, list->end});
            root = Parser(data).parse();
        }
    }
    if (auto hooks = root.member("hooks"); hooks && hooks->kind == Node::Object && hooks->children.empty()) {
        eraseSpan(data, {hooks->memberStart, hooks->end});
        root = Parser(data).parse();
    }
    const auto marker = QDir(backups).filePath("created-settings");
    if (root.children.empty() && QFileInfo::exists(marker)) {
        if (contents(settings) != original)
            throw Failure::ChangedWhileEditing;
        backup(backups, *original);
        if (!QFile::remove(settings))
            throw Failure::WriteFailed;
        QFile::remove(marker);
    } else
        writeChecked(settings, data, original, backups);
}
} // namespace codextop::ClaudeHookInstaller
