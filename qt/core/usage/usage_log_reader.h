#pragma once
#include "models/models.h"
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <limits>

namespace codextop::usage_detail {
/// 用量记录用 ISO8601DateFormatter。其小数秒截到毫秒，再计算所属日；
/// 例如中午前最后一纳秒仍属于上一天。
inline std::optional<QDateTime> eventTime(QString text) {
    const auto dot = text.indexOf('.');
    if (dot >= 0) {
        auto end = dot + 1;
        while (end < text.size() && text[end] >= u'0' && text[end] <= u'9')
            ++end;
        if (end > dot + 4)
            text.remove(dot + 4, end - dot - 4);
    }
    return parseTimestamp(text);
}
/// NSNumber.intValue 接受布尔和数字，截去小数；字符串不当作数字。
inline qint64 integer(const QJsonValue &value) {
    if (value.isBool())
        return value.toBool() ? 1 : 0;
    if (!value.isDouble())
        return 0;
    constexpr qint64 sentinel = std::numeric_limits<qint64>::min();
    const auto integral = value.toInteger(sentinel);
    if (integral != sentinel)
        return integral;
    const double number = value.toDouble();
    if (number >= double(std::numeric_limits<qint64>::max()) || number <= double(sentinel))
        return sentinel;
    return static_cast<qint64>(number);
}
/// 缩短后的文件从头读，未完成的末行保留给下次扫描。回调只需处理带有标记的 JSON。
template <typename FileState, typename Consume>
void read(const QString &path, FileState &state, const QByteArray &marker, Consume consume) {
    QFile file(path);
    const auto size = file.size();
    if (size < state.offset)
        state = FileState{};
    if (size <= state.offset || !file.open(QIODevice::ReadOnly) || !file.seek(state.offset))
        return;
    while (file.pos() < size) {
        const auto line = file.readLine();
        if (!line.endsWith('\n'))
            break;
        if (line.contains(marker)) {
            const auto data = QJsonDocument::fromJson(line);
            if (data.isObject())
                consume(data.object());
        }
        state.offset = file.pos();
    }
}
} // namespace codextop::usage_detail
