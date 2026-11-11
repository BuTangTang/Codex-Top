#include "led_layout.h"

#include <QHash>
#include <cmath>

using namespace Qt::StringLiterals;

namespace led {
namespace {

constexpr qreal pitch = 4;
constexpr qreal digitTop = 13;

const QHash<QChar, QString> &glyphs() {
    static const QHash<QChar, QString> table = {
        {u'0', u"111101101101111"_s}, {u'1', u"010110010010111"_s}, {u'2', u"111001111100111"_s},
        {u'3', u"111001111001111"_s}, {u'4', u"101101111001001"_s}, {u'5', u"111100111001111"_s},
        {u'6', u"111100111101111"_s}, {u'7', u"111001001001001"_s}, {u'8', u"111101111101111"_s},
        {u'9', u"111101111001111"_s}, {u'+', u"000010111010000"_s}, {u'?', u"111001011000010"_s},
        {u'O', u"111101101101111"_s}, {u'K', u"101101110101101"_s}, {u'Z', u"111001010100111"_s},
        {u'z', u"000000110010011"_s},
    };
    return table;
}

QString text(int count) { return count > 99 ? QStringLiteral("99+") : QString::number(std::max(0, count)); }

} // namespace

QList<Group> groups(int running, int waiting, int failed, int fresh, bool allDone, bool sleeping, bool unknown) {
    if (unknown) return {{QStringLiteral("?"), Tone::Idle}};
    if (allDone) return {{sleeping ? QStringLiteral("Zz") : QStringLiteral("OK"), Tone::Done}};
    QList<Group> result{{text(running), running > 0 ? Tone::Running : Tone::Idle}};
    if (waiting > 0) result.append({text(waiting), Tone::Waiting});
    if (failed > 0) result.append({text(failed), Tone::Failed});
    if (fresh > 0) result.append({text(fresh), Tone::Done});
    return result;
}

Layout layout(const QList<Group> &groups) {
    QList<qreal> widths;
    for (const auto &group : groups) widths.append(qreal(group.text.size()) * 16 - 4);
    qreal inner = std::max<qsizetype>(0, groups.size() - 1) * 8;
    for (qreal width : widths) inner += width;
    // 宽度 = 9 + 4k，让一圈灯在两条直边上正好落在 4 点一格的整数位置；最窄 45。
    const int steps = std::max(9, int(std::ceil((inner + 11) / 4)));
    Layout result;
    result.width = 9 + 4 * qreal(steps);
    qreal x = std::round((result.width - inner) / 2);
    for (qsizetype index = 0; index < groups.size(); ++index) {
        const auto &group = groups[index];
        if (index > 0) result.dividers.append(QRectF(x - 5, digitTop, 1, 19));
        for (qsizetype column = 0; column < group.text.size(); ++column) {
            const QString bits = glyphs().value(group.text[column], glyphs().value(u'0'));
            for (int cell = 0; cell < 15; ++cell) {
                const QRectF rect(x + qreal(column) * 16 + qreal(cell % 3) * pitch, digitTop + qreal(cell / 3) * pitch, dotSize, dotSize);
                result.dots.append({rect, group.tone, bits[cell] == u'1'});
            }
        }
        x += widths[index] + 8;
    }
    result.ring = ring(result.width);
    return result;
}

// 灯圈的圆心线：左右上下离边 4.5，直边每 4 点一颗，四个角不放灯（2026-11-09 用户选定）。
QList<QRectF> ring(qreal width) {
    const qreal left = 4.5, right = width - 4.5, top = 4.5, bottom = 40.5;
    QList<QPointF> centers;
    for (qreal x = left + 4; x <= right - 4; x += 4) centers.append({x, top});
    for (qreal y = top + 4; y <= bottom - 4; y += 4) centers.append({right, y});
    for (qreal x = right - 4; x >= left + 4; x -= 4) centers.append({x, bottom});
    for (qreal y = bottom - 4; y >= top + 4; y -= 4) centers.append({left, y});
    QList<QRectF> rects;
    for (const auto &center : centers) rects.append(QRectF(center.x() - dotSize / 2, center.y() - dotSize / 2, dotSize, dotSize));
    return rects;
}

} // namespace led
