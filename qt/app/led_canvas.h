#pragma once

#include "led/led_layout.h"

#include <QQuickItem>

// 点阵画布：把悬浮球的数字、分隔线和外圈灯作为一批小方块直接交给显卡画。
// 方块位置都是整数点、画布本身也放在整数点上，所以 1 倍屏每个点正好 3×3 物理像素，2 倍屏 6×6。
// phase 是彗星跑到一圈的几分之几（0～1），只在有任务在跑时由 QML 动画推动；不动时不会重画。
class LedCanvas : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int running READ running WRITE setRunning NOTIFY changed)
    Q_PROPERTY(int waiting READ waiting WRITE setWaiting NOTIFY changed)
    Q_PROPERTY(bool dark READ dark WRITE setDark NOTIFY changed)
    Q_PROPERTY(qreal phase READ phase WRITE setPhase NOTIFY phaseChanged)
    Q_PROPERTY(qreal layoutWidth READ layoutWidth NOTIFY changed)
    Q_PROPERTY(qreal lapDuration READ lapDuration NOTIFY changed)

public:
    explicit LedCanvas(QQuickItem *parent = nullptr);

    int running() const { return m_running; }
    int waiting() const { return m_waiting; }
    bool dark() const { return m_dark; }
    qreal phase() const { return m_phase; }
    qreal layoutWidth() const { return m_layout.width; }
    // 和原生版一样每颗灯 0.05 秒，一圈的时长随灯数变化。
    qreal lapDuration() const { return qreal(m_layout.ring.size()) * 50; }

    void setRunning(int value);
    void setWaiting(int value);
    void setDark(bool value);
    void setPhase(qreal value);

signals:
    void changed();
    void phaseChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *old, UpdatePaintNodeData *) override;

private:
    void relayout();
    int m_running = 3;
    int m_waiting = 0;
    bool m_dark = true;
    qreal m_phase = 0;
    led::Layout m_layout;
};
