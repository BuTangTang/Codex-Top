#pragma once

#include <QList>
#include <QRectF>
#include <QString>

// 悬浮球 LED 点阵排版，逐行照搬原生版 LEDOrbLayout：3×5 方点字，四周一圈灯（四个角不放灯）。
// 所有点的位置和大小都是整数点，所以 1 倍、2 倍屏上都对齐物理像素。
namespace led {

enum class Tone { Running, Idle, Waiting, Failed, Done };

struct Group {
    QString text;
    Tone tone;
    bool operator==(const Group &) const = default;
};

struct Dot {
    QRectF rect;
    Tone tone;
    bool lit;
};

struct Layout {
    qreal width = 45;
    QList<Dot> dots;
    QList<QRectF> dividers;
    // 外圈的灯，从左上角那段直边开始顺时针排。
    QList<QRectF> ring;
};

constexpr qreal height = 44;
constexpr qreal dotSize = 3;

QList<Group> groups(int running, int waiting, int failed, int fresh, bool allDone, bool sleeping, bool unknown);
Layout layout(const QList<Group> &groups);
QList<QRectF> ring(qreal width);

} // namespace led
