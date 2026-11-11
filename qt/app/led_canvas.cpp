#include "led_canvas.h"

#include <QSGGeometryNode>
#include <QSGVertexColorMaterial>
#include <cmath>

namespace {

// 和原生版同一张颜色表。
QColor toneColor(led::Tone tone, bool dark) {
    switch (tone) {
    case led::Tone::Running: return dark ? QColor(0xFFFFFF) : QColor(0x1B1E24);
    case led::Tone::Idle: return dark ? QColor(0x7E858F) : QColor(0xA0A6AE);
    case led::Tone::Waiting: return dark ? QColor(0xF5AE3D) : QColor(0xE09A22);
    case led::Tone::Failed: return dark ? QColor(0xF2675F) : QColor(0xE0554D);
    case led::Tone::Done: return dark ? QColor(0x3FCB86) : QColor(0x1FA866);
    }
    return {};
}

QColor blue(bool dark) { return dark ? QColor(0x4E9BFF) : QColor(0x1F7AE0); }

// 5 颗：最前面全亮，后面 4 颗依次变暗。
constexpr float tail[] = {1.0f, 0.7f, 0.45f, 0.25f, 0.12f};

void appendRect(QSGGeometry::ColoredPoint2D *&vertex, const QRectF &rect, const QColor &color, float alpha) {
    // 预乘透明度，顶点颜色材质要求。
    const auto r = uchar(color.red() * alpha), g = uchar(color.green() * alpha), b = uchar(color.blue() * alpha), a = uchar(255 * alpha);
    const float x0 = float(rect.left()), y0 = float(rect.top()), x1 = float(rect.right()), y1 = float(rect.bottom());
    const QPointF points[6] = {{x0, y0}, {x1, y0}, {x0, y1}, {x1, y0}, {x1, y1}, {x0, y1}};
    for (const auto &point : points) (vertex++)->set(float(point.x()), float(point.y()), r, g, b, a);
}

} // namespace

LedCanvas::LedCanvas(QQuickItem *parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
    relayout();
}

void LedCanvas::relayout() {
    m_layout = led::layout(led::groups(m_running, m_waiting, 0, 0, false, false, false));
    setImplicitWidth(m_layout.width);
    setImplicitHeight(led::height);
    emit changed();
    update();
}

void LedCanvas::setRunning(int value) { if (m_running != value) { m_running = value; relayout(); } }
void LedCanvas::setWaiting(int value) { if (m_waiting != value) { m_waiting = value; relayout(); } }
void LedCanvas::setDark(bool value) { if (m_dark != value) { m_dark = value; emit changed(); update(); } }
void LedCanvas::setPhase(qreal value) {
    if (qFuzzyCompare(m_phase, value)) return;
    m_phase = value;
    emit phaseChanged();
    update();
}

QSGNode *LedCanvas::updatePaintNode(QSGNode *old, UpdatePaintNodeData *) {
    auto *node = static_cast<QSGGeometryNode *>(old);
    const int count = int(m_layout.dots.size() + m_layout.dividers.size() + m_layout.ring.size() * 2);
    if (!node) {
        node = new QSGGeometryNode;
        auto *geometry = new QSGGeometry(QSGGeometry::defaultAttributes_ColoredPoint2D(), count * 6);
        geometry->setDrawingMode(QSGGeometry::DrawTriangles);
        node->setGeometry(geometry);
        node->setFlag(QSGNode::OwnsGeometry);
        node->setMaterial(new QSGVertexColorMaterial);
        node->setFlag(QSGNode::OwnsMaterial);
    } else if (node->geometry()->vertexCount() != count * 6) {
        node->geometry()->allocate(count * 6);
    }

    auto *vertex = node->geometry()->vertexDataAsColoredPoint2D();
    const QColor faint = m_dark ? QColor(Qt::white) : QColor(Qt::black);
    // 暗灯：字的空位和外圈。
    for (const auto &dot : m_layout.dots) appendRect(vertex, dot.rect, dot.lit ? toneColor(dot.tone, m_dark) : faint, dot.lit ? 1.0f : 0.07f);
    for (const auto &divider : m_layout.dividers) appendRect(vertex, divider, faint, 0.12f);
    for (const auto &rect : m_layout.ring) appendRect(vertex, rect, faint, 0.07f);
    // 彗星：头在 phase 位置，后面 4 颗依次变暗，格与格之间线性过渡，和原生版的关键帧插值一样。
    const int n = int(m_layout.ring.size());
    const double head = m_running > 0 ? m_phase * n : -1000;
    for (int index = 0; index < n; ++index) {
        float alpha = 0;
        if (m_running > 0) {
            const double behind = std::fmod(std::fmod(head - index, n) + n, n);
            const int k = int(behind);
            const double f = behind - k;
            auto value = [](int i) { return i < 5 ? tail[i] : 0.0f; };
            alpha = float(value(k) + (value(k + 1) - value(k)) * f);
        }
        appendRect(vertex, m_layout.ring[index], blue(m_dark), alpha);
    }
    node->markDirty(QSGNode::DirtyGeometry);
    return node;
}
